import Foundation
import AVFoundation
import ClipHelmCore

public enum MediaEngineError: Error, LocalizedError, Equatable, Sendable {
    case invalidFile
    case unsupportedMedia
    case noAudio
    case invalidTime
    case exportUnavailable
    case processingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "The media file is missing or unreadable."
        case .unsupportedMedia: "macOS cannot decode this media file."
        case .noAudio: "This video has no audio track."
        case .invalidTime: "The requested time is outside the media."
        case .exportUnavailable: "This media cannot be converted on this Mac."
        case .processingFailed: "Media preparation failed. Try again."
        }
    }
}

public struct MediaMetadata: Sendable {
    public let asset: MediaAsset
    public let frameRate: Double?
    public let hasAudio: Bool
    public let fileSize: Int64

    public var isPortrait: Bool { asset.height > asset.width }
}

public struct MediaProbe: Sendable {
    public init() { }

    public func probe(fileURL: URL, displayName: String,
                      id: AssetID = AssetID()) async throws -> MediaMetadata {
        try Task.checkCancellation()
        guard fileURL.isFileURL else { throw MediaEngineError.invalidFile }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw MediaEngineError.invalidFile
        }
        let source = AVURLAsset(url: fileURL, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        do {
            let playable = try await source.load(.isPlayable)
            let duration = try await source.load(.duration)
            let video = try await source.loadTracks(withMediaType: .video)
            let audio = try await source.loadTracks(withMediaType: .audio)
            guard playable, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
                  duration.seconds < Double(Int64.max) / 1_000_000,
                  let track = video.first else { throw MediaEngineError.unsupportedMedia }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let frame = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
            let width = Int(frame.width.rounded()), height = Int(frame.height.rounded())
            guard width > 0, height > 0 else { throw MediaEngineError.unsupportedMedia }
            let nominalRate = try await track.load(.nominalFrameRate)
            let asset = try MediaAsset(id: id, displayName: displayName,
                duration: MediaTime(microseconds: Int64((duration.seconds * 1_000_000).rounded())),
                width: width, height: height)
            try Task.checkCancellation()
            return MediaMetadata(asset: asset,
                                 frameRate: nominalRate.isFinite && nominalRate > 0 ? Double(nominalRate) : nil,
                                 hasAudio: !audio.isEmpty, fileSize: Int64(size))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MediaEngineError.unsupportedMedia
        }
    }
}
