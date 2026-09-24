import Foundation
import ClipHelmCore
import ClipHelmOpenRouter

public struct OpenRouterTranscriptionBackend: TranscriptionBackend {
    public let maximumChunkSeconds = 30
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
        let response = try await gateway.transcribeAudio(audio, modelID: modelID)
        try Task.checkCancellation()
        guard let decoded = try? JSONDecoder().decode(Response.self, from: response),
              decoded.text.count <= 1_000_000 else {
            throw TranscriptEngineError.invalidWordTimings
        }
        guard let timed = decoded.words else {
            if decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
            throw TranscriptEngineError.invalidWordTimings
        }
        guard !timed.isEmpty || decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptEngineError.invalidWordTimings
        }
        guard timed.count <= 20_000 else { throw TranscriptEngineError.invalidWordTimings }
        do {
            return try timed.map { item in
                guard item.start.isFinite, item.end.isFinite,
                      item.start >= 0, item.end > item.start, item.end <= 3_600 else {
                    throw TranscriptEngineError.invalidWordTimings
                }
                return try TranscriptWord(text: item.word,
                    range: MediaTimeRange(
                        start: MediaTime(microseconds: Int64((item.start * 1_000_000).rounded())),
                        end: MediaTime(microseconds: Int64((item.end * 1_000_000).rounded()))),
                    confidence: item.confidence, speakerID: item.speakerID)
            }
        } catch {
            throw TranscriptEngineError.invalidWordTimings
        }
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
    }
}
