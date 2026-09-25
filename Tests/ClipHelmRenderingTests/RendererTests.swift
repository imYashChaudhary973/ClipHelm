import XCTest
import AVFoundation
import Darwin
import ClipHelmCore
import ClipHelmMedia
@testable import ClipHelmRendering

final class RendererTests: XCTestCase {
    private func renderProfiled(_ label: String, spec: ClipHelmEditSpec,
                                source: URL, asset: MediaAsset, output: URL) async throws {
        var before = rusage()
        var after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let started = Date()
        _ = try await ClipRenderer().render(spec, sourceURL: source, asset: asset, outputURL: output)
        getrusage(RUSAGE_SELF, &after)
        if ProcessInfo.processInfo.environment["CLIPHELM_RUN_RENDER_BENCHMARKS"] == "1" {
            let cpu = Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec) +
                Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec) / 1_000_000 +
                Double(after.ru_stime.tv_sec - before.ru_stime.tv_sec) +
                Double(after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
            print(String(format: "CLIPHELM_RENDER_BENCHMARK size=%@ source_seconds=%.1f wall=%.3f cpu=%.3f peak_rss_bytes=%lld",
                label, Double(asset.duration.microseconds) / 1_000_000,
                Date().timeIntervalSince(started), cpu, after.ru_maxrss))
        }
    }

    func testRenderErrorHasRecoveryMessage() {
        XCTAssertNotNil(RenderError.outputUnavailable.errorDescription)
    }

    func testRendersRetainedSegmentsAsH264MP4WithAudio() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "portrait1080-audio", withExtension: "mp4"))
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Fixture").asset
        let first = try MediaTimeRange(start: MediaTime(microseconds: 0), end: MediaTime(microseconds: 400_000))
        let second = try MediaTimeRange(start: MediaTime(microseconds: 600_000), end: MediaTime(microseconds: 1_000_000))
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: first), EditSegment(sourceRange: second)],
            outputFormat: .vertical, framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .normalize, captionStyle: nil)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "clip.mp4")
        try await renderProfiled("1080x1920", spec: spec, source: source, asset: asset, output: output)
        let rendered = AVURLAsset(url: output)
        let tracks = try await rendered.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let descriptions = try await tracks[0].load(.formatDescriptions)
        XCTAssertEqual(descriptions.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let audio = try await rendered.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let duration = try await rendered.load(.duration).seconds
        XCTAssertEqual(duration, 0.8, accuracy: 0.1)
        let videoTime = try await tracks[0].load(.timeRange)
        let audioTime = try await audio[0].load(.timeRange)
        XCTAssertEqual(videoTime.start.seconds, audioTime.start.seconds, accuracy: 0.05)
        XCTAssertEqual(videoTime.duration.seconds, audioTime.duration.seconds, accuracy: 0.15)
        let size = try await MediaProbe().probe(fileURL: output, displayName: "Output").asset
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1920)
        let (frame, _) = try await AVAssetImageGenerator(asset: rendered).image(
            at: CMTime(seconds: 0.2, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(pixel[2]), Int(pixel[0]) + 80, "Exported video should retain the blue source frame")

        let preview = directory.appending(path: "preview.mp4")
        _ = try await ClipRenderer().render(spec, sourceURL: source, asset: asset,
                                            outputURL: preview, quality: .preview)
        let previewAsset = try await MediaProbe().probe(fileURL: preview, displayName: "Preview").asset
        XCTAssertEqual(previewAsset.width, 540)
        XCTAssertEqual(previewAsset.height, 960)
        let previewDuration = try await AVURLAsset(url: preview).load(.duration).seconds
        XCTAssertEqual(previewDuration, duration, accuracy: 0.1)
    }

    func testFourKLandscapeExport() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "landscape4k", withExtension: "mp4"))
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "4K").asset
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let format = try OutputFormat(width: 3840, height: 2160)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: format,
            framingMode: .fullFrame, pacingMode: .balanced, soundMode: .mute, captionStyle: nil)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-4k-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "clip.mp4")
        try await renderProfiled("3840x2160", spec: spec, source: source, asset: asset, output: output)
        let rendered = try await MediaProbe().probe(fileURL: output, displayName: "4K output").asset
        XCTAssertEqual(rendered.width, 3840)
        XCTAssertEqual(rendered.height, 2160)
        let video = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let formats = try await video[0].load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
    }

    func testOptInRealFourKRenderProfile() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPHELM_QA_RENDER_SOURCE"] else {
            throw XCTSkip("Set CLIPHELM_QA_RENDER_SOURCE to an authorized 4K MP4")
        }
        let source = URL(fileURLWithPath: path)
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "QA 4K").asset
        XCTAssertEqual(asset.width, 3840)
        XCTAssertEqual(asset.height, 2160)
        let start = try MediaTime(microseconds: 60_000_000)
        let end = try MediaTime(microseconds: 72_000_000)
        XCTAssertGreaterThan(asset.duration.microseconds, end.microseconds)
        let range = try MediaTimeRange(start: start, end: end)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)],
            outputFormat: try OutputFormat(width: 3840, height: 2160),
            framingMode: .classicFullFrame, pacingMode: .natural,
            soundMode: .source, captionStyle: nil)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-real-4k-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "clip.mp4")
        try await renderProfiled("real-3840x2160", spec: spec, source: source, asset: asset, output: output)
        let rendered = try await MediaProbe().probe(fileURL: output, displayName: "QA render").asset
        XCTAssertEqual(rendered.width, 3840)
        XCTAssertEqual(rendered.height, 2160)
        XCTAssertEqual(Double(rendered.duration.microseconds) / 1_000_000, 12, accuracy: 0.2)
        let audioTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        if let retainedPath = ProcessInfo.processInfo.environment["CLIPHELM_QA_RENDER_OUTPUT"] {
            try FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: retainedPath))
        }
    }

    func testCancelledRenderLeavesNoTemporaryMedia() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "landscape4k", withExtension: "mp4"))
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "4K").asset
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)],
            outputFormat: try OutputFormat(width: 3840, height: 2160),
            framingMode: .fullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-cancel-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = Task {
            try await ClipRenderer().render(spec, sourceURL: source, asset: asset,
                outputURL: directory.appending(path: "clip.mp4"))
        }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Canceled render must not return an output")
        } catch is CancellationError { }
        if FileManager.default.fileExists(atPath: directory.path) {
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(remaining.isEmpty, "Canceled render left: \(remaining)")
        }
    }

    func testCropUsesTopLeftNormalizedCoordinates() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "portrait-halves", withExtension: "mp4"))
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Halves").asset
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let rect = try NormalizedRect(x: 0, y: 0, width: 1, height: 0.31640625)
        let path = try CropPath(sourceRange: range,
            keyframes: [CropKeyframe(sourceTime: range.start, rect: rect)])
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .horizontal,
            framingMode: .fullFrame, pacingMode: .balanced, soundMode: .mute,
            captionStyle: nil, cropPaths: [path])
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-crop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "top.mp4")
        _ = try await ClipRenderer().render(spec, sourceURL: source, asset: asset, outputURL: output)
        let (frame, _) = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(
            at: CMTime(seconds: 0.2, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(pixel[0]), Int(pixel[1]) + 70, "Top crop should show red, not green")
    }

    func testCaptionTrackAppearsInFinalFrames() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "portrait1080-audio", withExtension: "mp4"))
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Caption source").asset
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let cueRange = try MediaTimeRange(start: MediaTime(microseconds: 100_000),
                                          end: MediaTime(microseconds: 900_000))
        let track = try CaptionTrack(cues: [CaptionCue(sourceRange: cueRange, text: "HELLO")],
                                     wordByWord: false, blurIn: false)
        let plain = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let captioned = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: .impact, captionTrack: track)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-caption-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "plain.mp4")
        let second = directory.appending(path: "captioned.mp4")
        _ = try await ClipRenderer().render(plain, sourceURL: source, asset: asset, outputURL: first)
        _ = try await ClipRenderer().render(captioned, sourceURL: source, asset: asset, outputURL: second)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (plainFrame, _) = try await AVAssetImageGenerator(asset: AVURLAsset(url: first)).image(at: time)
        let (captionFrame, _) = try await AVAssetImageGenerator(asset: AVURLAsset(url: second)).image(at: time)
        func reducedPixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 120 * 212 * 4)
            bytes.withUnsafeMutableBytes { memory in
                let context = CGContext(data: memory.baseAddress, width: 120, height: 212,
                    bitsPerComponent: 8, bytesPerRow: 120 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 212))
            }
            return bytes
        }
        let firstPixels = reducedPixels(plainFrame)
        let secondPixels = reducedPixels(captionFrame)
        let difference = zip(firstPixels, secondPixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertGreaterThan(difference, 20_000)
    }

    func testSmallSourceUsesSelectedOutputResolution() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Small").asset
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .horizontal,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-upscale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "clip.mp4")
        _ = try await ClipRenderer().render(spec, sourceURL: source, asset: asset, outputURL: output)
        let rendered = try await MediaProbe().probe(fileURL: output, displayName: "Output").asset
        XCTAssertEqual(rendered.width, 1920)
        XCTAssertEqual(rendered.height, 1080)
    }
}
