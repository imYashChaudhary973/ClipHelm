import Foundation
import AVFoundation
import ClipHelmCore

public struct AudioExtractor: Sendable {
    public init() { }

    public func extract(sourceURL: URL, range: MediaTimeRange? = nil,
                        outputDirectory: URL,
                        progress: @escaping MediaProgressHandler = { _ in }) async throws -> URL {
        let metadata = try await MediaProbe().probe(fileURL: sourceURL,
            displayName: sourceURL.lastPathComponent)
        guard metadata.hasAudio else { throw MediaEngineError.noAudio }
        let fullRange = try MediaTimeRange(start: MediaTime(microseconds: 0),
                                           end: metadata.asset.duration)
        let selected = range ?? fullRange
        guard selected.end <= fullRange.end else { throw MediaEngineError.invalidTime }
        do {
            return try await MediaExport.run(sourceURL: sourceURL,
                preset: AVAssetExportPresetAppleM4A, fileType: .m4a, extension: "m4a",
                outputDirectory: outputDirectory, range: selected,
                stage: .audio, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = outputDirectory.appending(path: UUID().uuidString).appendingPathExtension("m4a")
            try await FFmpegMediaAdapter.audio(source: sourceURL, output: fallback,
                range: selected, progress: progress)
            return fallback
        }
    }
}
