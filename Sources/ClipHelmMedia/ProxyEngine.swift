import Foundation
import AVFoundation
import ClipHelmCore

public struct ProxyAsset: Sendable {
    public let fileURL: URL
    public let metadata: MediaMetadata
    public let timeMap: MediaTimeMap
}

public struct ProxyEngine: Sendable {
    public init() { }

    public func shouldCreateProxy(for metadata: MediaMetadata) -> Bool {
        metadata.asset.width > 1920 || metadata.asset.height > 1080
            || metadata.fileSize > 1_000_000_000
    }

    public func createIfUseful(sourceURL: URL, metadata: MediaMetadata,
                               outputDirectory: URL,
                               progress: @escaping MediaProgressHandler = { _ in }) async throws -> ProxyAsset? {
        guard shouldCreateProxy(for: metadata) else { return nil }
        let url: URL
        do {
            url = try await MediaExport.run(sourceURL: sourceURL,
                preset: AVAssetExportPreset1280x720, fileType: .mp4, extension: "mp4",
                outputDirectory: outputDirectory, stage: .proxy, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = outputDirectory.appending(path: UUID().uuidString).appendingPathExtension("mp4")
            try await FFmpegMediaAdapter.proxy(source: sourceURL, output: fallback,
                width: metadata.asset.width, height: metadata.asset.height,
                duration: metadata.asset.duration, progress: progress)
            url = fallback
        }
        do {
            let result = try await MediaProbe().probe(fileURL: url,
                displayName: metadata.asset.displayName + " proxy", id: metadata.asset.id)
            let durationDelta = abs(result.asset.duration.microseconds - metadata.asset.duration.microseconds)
            guard durationDelta <= 100_000,
                  result.isPortrait == metadata.isPortrait,
                  result.asset.width <= metadata.asset.width,
                  result.asset.height <= metadata.asset.height,
                  max(result.asset.width, result.asset.height) <= 1280 else {
                throw MediaEngineError.processingFailed
            }
            let zero = try MediaTime(microseconds: 0)
            let sourceRange = try MediaTimeRange(start: zero, end: metadata.asset.duration)
            let proxyRange = try MediaTimeRange(start: zero, end: result.asset.duration)
            return ProxyAsset(fileURL: url, metadata: result,
                timeMap: MediaTimeMap(source: sourceRange, proxy: proxyRange))
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { throw CancellationError() }
            throw MediaEngineError.processingFailed
        }
    }
}
