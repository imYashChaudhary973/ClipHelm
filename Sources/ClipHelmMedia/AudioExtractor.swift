import Foundation
import AVFoundation
import ClipHelmCore

public struct AudioExtractor: Sendable {
    public init() { }

    public func hasSound(fileURL: URL) async throws -> Bool {
        do {
            let file = try AVAudioFile(forReading: fileURL,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                  format.channelCount > 0 else { throw MediaEngineError.processingFailed }
            var activeFrames = 0
            let required = Int(format.sampleRate * 0.08)
            while true {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
                if buffer.frameLength == 0 { return false }
                guard let data = buffer.floatChannelData else { throw MediaEngineError.processingFailed }
                for frame in 0..<Int(buffer.frameLength) {
                    if (0..<Int(format.channelCount)).contains(where: { abs(data[$0][frame]) > 0.004 }) {
                        activeFrames += 1
                    }
                }
                if activeFrames >= required { return true }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await FFmpegMediaAdapter.hasSound(fileURL: fileURL)
        }
    }

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
