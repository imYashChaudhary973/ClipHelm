import Foundation
import AVFoundation
import ClipHelmCore

private final class ScopedMediaAccess {
    private let url: URL
    private let accessed: Bool

    init(_ url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }

    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

@MainActor
public final class PlaybackEngine {
    public let player = AVPlayer()
    public private(set) var timeMap: MediaTimeMap?
    private var access: ScopedMediaAccess?

    public init() { }

    public func load(sourceURL: URL, proxyURL: URL? = nil,
                     timeMap: MediaTimeMap? = nil) throws {
        let selected = proxyURL ?? sourceURL
        guard sourceURL.isFileURL, selected.isFileURL,
              FileManager.default.fileExists(atPath: selected.path),
              (proxyURL == nil) == (timeMap == nil) else {
            throw MediaEngineError.invalidFile
        }
        pause()
        access = ScopedMediaAccess(selected)
        let asset = AVURLAsset(url: selected, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        self.timeMap = timeMap
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func seek(sourceTime: MediaTime) async throws {
        let target = try timeMap?.proxyTime(for: sourceTime) ?? sourceTime
        let requested = CMTime(value: target.microseconds, timescale: 1_000_000)
        await withCheckedContinuation { continuation in
            player.seek(to: requested, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    public func currentSourceTime() throws -> MediaTime {
        let current = player.currentTime()
        guard current.isNumeric, current.seconds.isFinite, current.seconds >= 0,
              current.seconds < Double(Int64.max) / 1_000_000 else {
            throw MediaEngineError.invalidTime
        }
        let playback = try MediaTime(microseconds: Int64((current.seconds * 1_000_000).rounded()))
        return try timeMap?.sourceTime(for: playback) ?? playback
    }

    public func unload() {
        pause()
        player.replaceCurrentItem(with: nil)
        access = nil
        timeMap = nil
    }
}
