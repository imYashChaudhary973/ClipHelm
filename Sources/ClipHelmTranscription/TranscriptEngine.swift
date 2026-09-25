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
    /// How many chunks may be transcribed at once. On-device recognizers use one.
    var maximumConcurrentChunks: Int { get }
    func transcribe(audioURL: URL) async throws -> [TranscriptWord]
}

public extension TranscriptionBackend {
    var maximumConcurrentChunks: Int { 1 }
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
        guard (1...300).contains(backend.maximumChunkSeconds) else {
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
        let chunks = try stride(from: Int64(0), to: total, by: Int(chunkSize)).map { start in
            try MediaTimeRange(start: MediaTime(microseconds: start),
                               end: MediaTime(microseconds: min(total, start + chunkSize)))
        }
        progress(.init(stage: .extracting, fraction: 0))
        let width = max(1, min(8, backend.maximumConcurrentChunks))
        var words: [TranscriptWord] = []
        try await withThrowingTaskGroup(of: [TranscriptWord].self) { group in
            var next = 0
            var finished = 0
            func submit() {
                guard next < chunks.count else { return }
                let range = chunks[next]
                next += 1
                group.addTask {
                    try await Self.transcribe(range, sourceURL: sourceURL, folder: folder, backend: backend)
                }
            }
            for _ in 0..<width { submit() }
            while let chunkWords = try await group.next() {
                words.append(contentsOf: chunkWords)
                finished += 1
                progress(.init(stage: .transcribing, fraction: Double(finished) / Double(chunks.count)))
                submit()
            }
        }
        try Task.checkCancellation()
        let ordered = words.sorted { $0.range.start < $1.range.start }
        return try Transcript(assetID: asset.id, segments: Self.makeSegments(ordered))
    }

    /// Transcribes one chunk and places its words on the source timeline, clipped to the chunk.
    private static func transcribe(_ range: MediaTimeRange, sourceURL: URL, folder: URL,
                                   backend: any TranscriptionBackend) async throws -> [TranscriptWord] {
        try Task.checkCancellation()
        let audio = try await AudioExtractor().extract(sourceURL: sourceURL, range: range,
            outputDirectory: folder)
        defer { try? FileManager.default.removeItem(at: audio) }
        guard try await AudioExtractor().hasSound(fileURL: audio) else { return [] }
        let relative = try await backend.transcribe(audioURL: audio)
        try Task.checkCancellation()
        let length = range.durationMicroseconds
        return try relative.compactMap { word in
            guard word.range.start.microseconds < length else { return nil }
            return try TranscriptWord(text: word.text,
                range: MediaTimeRange(
                    start: MediaTime(microseconds: range.start.microseconds + word.range.start.microseconds),
                    end: MediaTime(microseconds: range.start.microseconds +
                        min(length, word.range.end.microseconds))),
                confidence: word.confidence, speakerID: word.speakerID)
        }
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
