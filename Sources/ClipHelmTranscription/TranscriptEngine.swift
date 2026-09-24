import Foundation
import ClipHelmCore
import ClipHelmMedia

public enum TranscriptEngineError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case permissionDenied
    case invalidWordTimings
    case audioUnreadable

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This transcription method is unavailable on this Mac."
        case .permissionDenied: "Allow Speech Recognition in macOS Settings to transcribe on this Mac."
        case .invalidWordTimings: "The transcription service did not return valid word timings. Choose another model."
        case .audioUnreadable: "The audio could not be analyzed. Try another source."
        }
    }
}

public protocol TranscriptionBackend: Sendable {
    var maximumChunkSeconds: Int { get }
    func transcribe(audioURL: URL) async throws -> [TranscriptWord]
}

public struct TranscriptProgress: Sendable {
    public enum Stage: Sendable { case extracting, checkingAudio, transcribing }
    public let stage: Stage
    public let fraction: Double
    public init(stage: Stage, fraction: Double) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
    }
}

public struct TranscriptEngine: Sendable {
    public init() { }

    public func transcribe(sourceURL: URL, asset: MediaAsset,
                           backend: any TranscriptionBackend,
                           progress: @escaping @Sendable (TranscriptProgress) -> Void = { _ in }) async throws -> Transcript {
        guard (1...50).contains(backend.maximumChunkSeconds) else {
            throw TranscriptEngineError.unavailable
        }
        let metadata = try await MediaProbe().probe(fileURL: sourceURL,
            displayName: asset.displayName, id: asset.id)
        guard metadata.asset.duration == asset.duration else {
            throw TranscriptEngineError.audioUnreadable
        }
        guard metadata.hasAudio else { return try Transcript(assetID: asset.id, segments: []) }

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }

        let total = asset.duration.microseconds
        let chunkSize = Int64(backend.maximumChunkSeconds) * 1_000_000
        var start: Int64 = 0
        var words: [TranscriptWord] = []
        while start < total {
            try Task.checkCancellation()
            let end = start + min(chunkSize, total - start)
            let range = try MediaTimeRange(start: MediaTime(microseconds: start),
                                            end: MediaTime(microseconds: end))
            progress(.init(stage: .extracting, fraction: Double(start) / Double(total)))
            let audio = try await AudioExtractor().extract(sourceURL: sourceURL, range: range,
                outputDirectory: folder)
            do {
                progress(.init(stage: .checkingAudio, fraction: Double(start) / Double(total)))
                if try await AudioExtractor().hasSound(fileURL: audio) {
                    progress(.init(stage: .transcribing, fraction: Double(start) / Double(total)))
                    let relative = try await backend.transcribe(audioURL: audio)
                    for word in relative {
                        guard word.range.end.microseconds <= range.durationMicroseconds else {
                            throw TranscriptEngineError.invalidWordTimings
                        }
                        let absolute = try MediaTimeRange(
                            start: MediaTime(microseconds: start + word.range.start.microseconds),
                            end: MediaTime(microseconds: start + word.range.end.microseconds))
                        words.append(try TranscriptWord(text: word.text, range: absolute,
                            confidence: word.confidence, speakerID: word.speakerID))
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: audio)
                throw error
            }
            try? FileManager.default.removeItem(at: audio)
            start = end
            progress(.init(stage: .transcribing, fraction: Double(start) / Double(total)))
        }
        let ordered = words.sorted { $0.range.start < $1.range.start }
        return try Transcript(assetID: asset.id, segments: Self.makeSegments(ordered))
    }

    private static func makeSegments(_ words: [TranscriptWord]) throws -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in words {
            if let last = current.last,
               (word.speakerID != last.speakerID ||
                word.range.start.microseconds - last.range.end.microseconds > 750_000 ||
                current.count >= 25) {
                groups.append(current)
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return try groups.map(TranscriptSegment.init(words:))
    }
}
