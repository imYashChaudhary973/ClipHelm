import AVFoundation
import CoreImage
import Foundation
import ClipHelmCore
import ClipHelmEditing
import ClipHelmCaptions
import ClipHelmMedia

public enum RenderError: Error, LocalizedError, Sendable {
    case unsupportedFormat
    case sourceChanged
    case outputUnavailable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Choose a 9:16 or 16:9 canvas at 1080p or 4K."
        case .sourceChanged: "The original video changed. Locate the source and process again."
        case .outputUnavailable: "The selected export size is unavailable for this video or Mac. Try 1080p."
        case .encodingFailed: "The clip could not be encoded. Check disk space and try again."
        }
    }
}

public enum RenderQuality: Sendable { case preview, final }

public struct RenderProgress: Sendable {
    public let clipID: ClipID
    public let fraction: Double
}

/// Resolves one validated edit spec into an H.264 MP4. No model data reaches AVFoundation directly.
public struct ClipRenderer: Sendable {
    public init() { }

    public static func supports(_ format: OutputFormat) -> Bool {
        let isVertical = format.width * 16 == format.height * 9
        let isHorizontal = format.width * 9 == format.height * 16
        return (isVertical || isHorizontal) && [1080, 2160].contains(min(format.width, format.height))
    }

    public func render(_ spec: ClipHelmEditSpec, sourceURL: URL, asset: MediaAsset,
                       outputURL: URL, quality: RenderQuality = .final,
                       progress: @escaping @Sendable (RenderProgress) -> Void = { _ in }) async throws -> URL {
        guard sourceURL.isFileURL, outputURL.isFileURL,
              sourceURL.resolvingSymlinksInPath() != outputURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RenderError.outputUnavailable
        }
        let timeline = try EditSpecValidator().validate(spec, for: asset)
        let format = spec.outputFormat
        guard Self.supports(format) else {
            throw RenderError.unsupportedFormat
        }
        try Task.checkCancellation()
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let metadata = try await MediaProbe().probe(fileURL: sourceURL, displayName: asset.displayName, id: asset.id)
        guard metadata.asset.duration == asset.duration,
              metadata.asset.width == asset.width, metadata.asset.height == asset.height else {
            throw RenderError.sourceChanged
        }
        let source = AVURLAsset(url: sourceURL, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            throw RenderError.sourceChanged
        }
        let sourceAudio = try await source.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.encodingFailed }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let audio = spec.audioOperation == .mute || sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for segment in spec.segments {
            try Task.checkCancellation()
            let range = CMTimeRange(start: Self.cmTime(segment.sourceRange.start),
                                    end: Self.cmTime(segment.sourceRange.end))
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let audio, let sourceAudio { try audio.insertTimeRange(range, of: sourceAudio, at: cursor) }
            cursor = cursor + range.duration
        }

        let divisor = quality == .preview ? 2 : 1
        let size = CGSize(width: format.width / divisor, height: format.height / divisor)
        let program = try CaptionProgram(spec: spec)
        let processor = FrameProcessor(spec: spec, timeline: timeline, program: program, size: size)
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            processor.process(request)
        }
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let preset: String = quality == .preview ? AVAssetExportPreset1280x720 :
            min(format.width, format.height) == 2160 ? AVAssetExportPreset3840x2160 : AVAssetExportPreset1920x1080
        guard AVAssetExportSession.allExportPresets().contains(preset),
              let exporter = AVAssetExportSession(asset: composition, presetName: preset),
              exporter.supportedFileTypes.contains(.mp4) else { throw RenderError.outputUnavailable }
        exporter.videoComposition = videoComposition
        if spec.audioOperation == .normalize, let audio {
            let gain = try Self.normalizationGain(composition: composition, track: audio)
            let params = AVMutableAudioMixInputParameters(track: audio)
            params.setVolume(gain, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            exporter.audioMix = mix
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temporary = outputURL.deletingLastPathComponent().appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")
        let box = ExportSessionBox(exporter)
        let observer = Task {
            while !Task.isCancelled {
                progress(.init(clipID: spec.clipID, fraction: box.fraction))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { observer.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await box.export(to: temporary)
            } onCancel: { box.cancel() }
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: outputURL)
            progress(.init(clipID: spec.clipID, fraction: 1))
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if Task.isCancelled { throw CancellationError() }
            throw RenderError.encodingFailed
        }
    }

    private static func cmTime(_ time: MediaTime) -> CMTime {
        CMTime(value: time.microseconds, timescale: 1_000_000)
    }

    private static func normalizationGain(composition: AVComposition,
                                          track: AVCompositionTrack) throws -> Float {
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw RenderError.encodingFailed }
        reader.add(output)
        guard reader.startReading() else { throw RenderError.encodingFailed }
        defer { reader.cancelReading() }
        var squared = 0.0
        var samples: Int64 = 0
        var peak = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block)
            guard count > 0, count <= 8_000_000 else { throw RenderError.encodingFailed }
            var bytes = [UInt8](repeating: 0, count: count)
            let status = bytes.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count,
                                           destination: ptr.baseAddress!)
            }
            guard status == noErr else { throw RenderError.encodingFailed }
            for index in stride(from: 0, to: count - 1, by: 2) {
                let raw = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                let value = abs(Double(Int16(bitPattern: raw)) / 32_768)
                squared += value * value
                peak = max(peak, value)
                samples += 1
            }
        }
        guard reader.status == .completed else { throw RenderError.encodingFailed }
        guard samples > 0, squared > 0, peak > 0 else { return 1 }
        let rms = sqrt(squared / Double(samples))
        return Float(min(4, 0.95 / peak, 0.12 / rms))
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    var fraction: Double { Double(session.progress) }
    func export(to url: URL) async throws { try await session.export(to: url, as: .mp4) }
    func cancel() { session.cancelExport() }
}

private final class FrameProcessor: @unchecked Sendable {
    private let spec: ClipHelmEditSpec
    private let timeline: EditTimeline
    private let program: CaptionProgram
    private let size: CGSize
    private let captions = CaptionRenderer()

    init(spec: ClipHelmEditSpec, timeline: EditTimeline, program: CaptionProgram, size: CGSize) {
        self.spec = spec
        self.timeline = timeline
        self.program = program
        self.size = size
    }

    func process(_ request: AVAsynchronousCIImageFilteringRequest) {
        do {
            let seconds = CMTimeGetSeconds(request.compositionTime)
            guard seconds.isFinite else { throw RenderError.encodingFailed }
            let edited = try MediaTime(microseconds: max(0, Int64((seconds * 1_000_000).rounded())))
            let sourceTime = try timeline.sourceTime(forEdited: edited)
            let canvas = CGRect(origin: .zero, size: size)
            let source = request.sourceImage.transformed(by: CGAffineTransform(
                translationX: -request.sourceImage.extent.minX, y: -request.sourceImage.extent.minY))
            let image = try compose(source, at: sourceTime, canvas: canvas)
            let output: CIImage
            if let frame = program.frame(at: sourceTime, canvasSize: size),
               let overlay = captions.render(frame, canvasSize: size) {
                output = CIImage(cgImage: overlay).composited(over: image)
            } else { output = image }
            request.finish(with: output.cropped(to: canvas), context: nil)
        } catch {
            request.finish(with: error)
        }
    }

    private func compose(_ source: CIImage, at time: MediaTime, canvas: CGRect) throws -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { throw RenderError.encodingFailed }
        let active = spec.layoutCues.first { $0.sourceRange.start <= time && time < $0.sourceRange.end }?.layout
            ?? .original
        let path = spec.cropPaths.first { $0.sourceRange.start <= time && time < $0.sourceRange.end }
        let crop: CGRect? = try path.map { item in
            let rect = try item.rect(atSourceTime: time)
            return CGRect(x: rect.x * extent.width,
                          y: (1 - rect.y - rect.height) * extent.height,
                          width: rect.width * extent.width, height: rect.height * extent.height)
        }
        let full = CIImage(color: .black).cropped(to: canvas)
        switch spec.layout {
        case .fit:
            return place(source, sourceRect: extent, target: canvas, fill: false).composited(over: full)
        case .blurredBackground:
            let back = place(source, sourceRect: extent, target: canvas, fill: true)
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
                .cropped(to: canvas)
            return place(source, sourceRect: extent, target: canvas, fill: false).composited(over: back)
        case .fill:
            let focused = crop ?? extent
            switch active {
            case .stackedSpeakers:
                let top = CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2)
                let bottom = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height / 2)
                let left = CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height)
                let right = CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height)
                return place(source, sourceRect: left, target: top, fill: true)
                    .composited(over: place(source, sourceRect: right, target: bottom, fill: true))
            case .sideBySide:
                let left = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
                let right = CGRect(x: canvas.midX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
                let first = CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height)
                let second = CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height)
                return place(source, sourceRect: first, target: left, fill: true)
                    .composited(over: place(source, sourceRect: second, target: right, fill: true))
            case .screenAndSpeaker, .pictureInPicture:
                let background = place(source, sourceRect: extent, target: canvas, fill: false)
                    .composited(over: full)
                let inset = CGRect(x: canvas.width * 0.64, y: canvas.height * 0.56,
                                   width: canvas.width * 0.32, height: canvas.height * 0.36)
                return place(source, sourceRect: focused, target: inset, fill: true)
                    .composited(over: background)
            case .screenFocus:
                return place(source, sourceRect: extent, target: canvas, fill: false).composited(over: full)
            case .original, .speakerFocus:
                return place(source, sourceRect: focused, target: canvas, fill: true)
            }
        }
    }

    private func place(_ image: CIImage, sourceRect: CGRect, target: CGRect, fill: Bool) -> CIImage {
        let scale = fill ? max(target.width / sourceRect.width, target.height / sourceRect.height) :
            min(target.width / sourceRect.width, target.height / sourceRect.height)
        let width = sourceRect.width * scale
        let height = sourceRect.height * scale
        let x = target.midX - width / 2
        let y = target.midY - height / 2
        return image.cropped(to: sourceRect).transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: x - sourceRect.minX * scale, ty: y - sourceRect.minY * scale))
            .cropped(to: target)
    }
}
