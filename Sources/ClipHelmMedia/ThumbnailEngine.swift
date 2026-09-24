import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import ClipHelmCore

public struct Thumbnail: Sendable {
    public let requestedTime: MediaTime
    /// Nil when the fallback decoder cannot report the exact presentation timestamp.
    public let actualTime: MediaTime?
    public let fileURL: URL
}

public struct ThumbnailEngine: Sendable {
    public init() { }

    public func generate(fileURL: URL, at times: [MediaTime], outputDirectory: URL,
                         maximumDimension: Int = 480,
                         progress: @escaping MediaProgressHandler = { _ in }) async throws -> [Thumbnail] {
        guard fileURL.isFileURL, outputDirectory.isFileURL,
              (1...300).contains(times.count), (64...2048).contains(maximumDimension) else {
            throw MediaEngineError.invalidTime
        }
        let metadata = try await MediaProbe().probe(fileURL: fileURL,
                                                     displayName: fileURL.lastPathComponent)
        guard times.allSatisfy({ $0.microseconds < metadata.asset.duration.microseconds }) else {
            throw MediaEngineError.invalidTime
        }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: fileURL, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var made: [URL] = []
        var thumbnails: [Thumbnail] = []
        var useFallback = false
        do {
            for (index, time) in times.enumerated() {
                try Task.checkCancellation()
                let destination = outputDirectory.appending(path: UUID().uuidString).appendingPathExtension("jpg")
                var actualTime: MediaTime?
                if !useFallback {
                    do {
                        let requested = CMTime(value: time.microseconds, timescale: 1_000_000)
                        let (image, actual) = try await generator.image(at: requested)
                        try Task.checkCancellation()
                        guard actual.isNumeric, actual.seconds.isFinite, actual.seconds >= 0 else {
                            throw MediaEngineError.processingFailed
                        }
                        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL,
                            UTType.jpeg.identifier as CFString, 1, nil) else {
                            throw MediaEngineError.processingFailed
                        }
                        CGImageDestinationAddImage(writer, image,
                            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
                        guard CGImageDestinationFinalize(writer) else {
                            throw MediaEngineError.processingFailed
                        }
                        actualTime = try MediaTime(microseconds: Int64((actual.seconds * 1_000_000).rounded()))
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        try? FileManager.default.removeItem(at: destination)
                        useFallback = true
                    }
                }
                if useFallback {
                    try await FFmpegMediaAdapter.frame(source: fileURL, output: destination,
                        time: time, maximumDimension: maximumDimension)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: destination.path)
                made.append(destination)
                thumbnails.append(Thumbnail(requestedTime: time, actualTime: actualTime,
                                            fileURL: destination))
                progress(MediaProgress(stage: .thumbnail, fraction: Double(index + 1) / Double(times.count)))
            }
            return thumbnails
        } catch {
            for file in made { try? FileManager.default.removeItem(at: file) }
            if Task.isCancelled { throw CancellationError() }
            if let known = error as? MediaEngineError { throw known }
            throw MediaEngineError.processingFailed
        }
    }
}
