import Foundation
import ClipHelmCore
import ClipHelmOpenRouter

public struct OpenRouterTranscriptionBackend: TranscriptionBackend {
    /// Longer chunks mean fewer words split at a boundary; two minutes of AAC stays well under the upload limit.
    public let maximumChunkSeconds = 120
    public let maximumConcurrentChunks = 4
    private let gateway: any OpenRouterGateway
    private let modelID: String

    public init(gateway: any OpenRouterGateway, model: OpenRouterModel) throws {
        guard model.supports([.transcription]) else {
            throw OpenRouterModelRegistryError.unsupportedTask
        }
        self.gateway = gateway
        modelID = model.id
    }

    public func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        guard audioURL.isFileURL,
              let size = try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...8_000_000).contains(size) else {
            throw TranscriptEngineError.audioUnreadable
        }
        try Task.checkCancellation()
        let audio = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        let response = try await Self.request(audio, modelID: modelID, gateway: gateway)
        try Task.checkCancellation()
        return try Self.words(from: response)
    }

    /// Retries transient OpenRouter failures with a short backoff.
    private static func request(_ audio: Data, modelID: String,
                                gateway: any OpenRouterGateway) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await gateway.transcribeAudio(audio, modelID: modelID)
            } catch let error as OpenRouterGatewayError
                        where [.rateLimited, .serviceUnavailable, .networkUnavailable].contains(error) && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt * 3))
            }
        }
    }

    /// Normalizes provider word lists: trims padding, orders words, and gives zero-length
    /// words a short span that ends before the next word so captions never overlap.
    static func words(from response: Data) throws -> [TranscriptWord] {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: response),
              decoded.text.count <= 1_000_000 else {
            throw TranscriptEngineError.invalidWordTimings
        }
        let spoken = !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let timed = decoded.words else {
            if !spoken { return [] }
            throw OpenRouterGatewayError.unsupportedTranscription
        }
        guard timed.count <= 40_000, !(timed.isEmpty && spoken) else {
            throw TranscriptEngineError.invalidWordTimings
        }
        let items = timed.compactMap { item -> (text: String, start: Double, end: Double,
                                                confidence: Double?, speaker: String?)? in
            let text = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 200, item.start.isFinite, item.end.isFinite,
                  item.start >= 0, item.start <= 3_600 else { return nil }
            let confidence = item.confidence.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            return (text, item.start, max(item.start, min(item.end, 3_600)), confidence, item.speakerID)
        }.sorted { $0.start < $1.start }
        var words: [TranscriptWord] = []
        var cursor: Int64 = 0
        for (index, item) in items.enumerated() {
            let start = max(cursor, Int64((item.start * 1_000_000).rounded()))
            let next = index + 1 < items.count
                ? Int64((items[index + 1].start * 1_000_000).rounded()) : Int64.max
            var end = Int64((item.end * 1_000_000).rounded())
            if end <= start { end = start + 250_000 }
            // A word that shares its start with the next one keeps a 10 ms sliver.
            end = next > start ? min(end, next) : start + 10_000
            end = max(end, start + 10_000)
            cursor = end
            do {
                words.append(try TranscriptWord(text: item.text,
                    range: MediaTimeRange(start: MediaTime(microseconds: start),
                                          end: MediaTime(microseconds: end)),
                    confidence: item.confidence, speakerID: item.speaker))
            } catch {
                continue
            }
        }
        return words
    }
}

private struct Response: Decodable {
    let text: String
    let words: [Word]?
}

private struct Word: Decodable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double?
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence
        case speakerID = "speaker_id"
        case speaker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        confidence = try? c.decode(Double.self, forKey: .confidence)
        speakerID = (try? c.decode(String.self, forKey: .speakerID))
            ?? (try? c.decode(Int.self, forKey: .speaker)).map { "Speaker \($0 + 1)" }
    }
}
