import Foundation
import XCTest
import ClipHelmCore
@testable import ClipHelmMedia

final class MediaEngineTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4"))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testProbeAndProxyForPortrait() async throws {
        let source = try fixture("portrait1080-audio")
        let metadata = try await MediaProbe().probe(fileURL: source, displayName: "Portrait")
        XCTAssertEqual(metadata.asset.width, 1080)
        XCTAssertEqual(metadata.asset.height, 1920)
        XCTAssertEqual(metadata.frameRate, 30)
        XCTAssertTrue(metadata.hasAudio)
        XCTAssertTrue(ProxyEngine().shouldCreateProxy(for: metadata))

        let output = try directory()
        defer { try? FileManager.default.removeItem(at: output) }
        let originalBytes = try Data(contentsOf: source)
        let maybeProxy = try await ProxyEngine().createIfUseful(sourceURL: source,
            metadata: metadata, outputDirectory: output)
        let proxy = try XCTUnwrap(maybeProxy)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertLessThanOrEqual(proxy.metadata.asset.width, 1280)
        XCTAssertLessThanOrEqual(proxy.metadata.asset.height, 1280)
        XCTAssertTrue(proxy.metadata.isPortrait)
        XCTAssertEqual(try proxy.timeMap.proxyTime(for: metadata.asset.duration),
                       proxy.metadata.asset.duration)
        XCTAssertEqual(try proxy.timeMap.sourceTime(for: proxy.metadata.asset.duration),
                       metadata.asset.duration)
        let permissions = try FileManager.default.attributesOfItem(atPath: proxy.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testFramesAndAudioRemainBounded() async throws {
        let source = try fixture("portrait1080-audio")
        let output = try directory()
        defer { try? FileManager.default.removeItem(at: output) }
        let zero = try MediaTime(microseconds: 0)
        let range = try MediaTimeRange(start: zero, end: MediaTime(microseconds: 150_000))
        let frames = try await FrameSampler().sample(fileURL: source, range: range,
            count: 3, outputDirectory: output, maximumDimension: 320)
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        XCTAssertLessThan(frames.last!.requestedTime.microseconds, range.end.microseconds)

        let audio = try await AudioExtractor().extract(sourceURL: source,
            outputDirectory: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let audioMetadata = try FileManager.default.attributesOfItem(atPath: audio.path)
        XCTAssertGreaterThan(audioMetadata[.size] as? Int ?? 0, 0)
    }

    func testSmallSourceNeedsNoProxyAndNoAudioFailsCleanly() async throws {
        let source = try fixture("valid")
        let metadata = try await MediaProbe().probe(fileURL: source, displayName: "Small")
        XCTAssertEqual(metadata.asset.width, 64)
        XCTAssertEqual(metadata.frameRate, 25)
        XCTAssertFalse(metadata.hasAudio)
        let output = try directory()
        defer { try? FileManager.default.removeItem(at: output) }
        let proxy = try await ProxyEngine().createIfUseful(sourceURL: source,
            metadata: metadata, outputDirectory: output)
        XCTAssertNil(proxy)
        do {
            _ = try await AudioExtractor().extract(sourceURL: source, outputDirectory: output)
            XCTFail("Silent video must not produce a fake audio file")
        } catch let error as MediaEngineError {
            XCTAssertEqual(error, .noAudio)
        }
    }

    func test4KLandscapeProbe() async throws {
        let source = try fixture("landscape4k")
        let metadata = try await MediaProbe().probe(fileURL: source, displayName: "4K")
        XCTAssertEqual(metadata.asset.width, 3840)
        XCTAssertEqual(metadata.asset.height, 2160)
        XCTAssertTrue(ProxyEngine().shouldCreateProxy(for: metadata))
        let output = try directory()
        defer { try? FileManager.default.removeItem(at: output) }
        let maybeProxy = try await ProxyEngine().createIfUseful(sourceURL: source,
            metadata: metadata, outputDirectory: output)
        let proxy = try XCTUnwrap(maybeProxy)
        XCTAssertEqual(proxy.metadata.asset.width, 1280)
        XCTAssertEqual(proxy.metadata.asset.height, 720)
    }

    func test60FPSMetadata() async throws {
        let source = try fixture("landscape60")
        let metadata = try await MediaProbe().probe(fileURL: source, displayName: "60 FPS")
        XCTAssertEqual(metadata.frameRate, 60)
        XCTAssertFalse(ProxyEngine().shouldCreateProxy(for: metadata))
    }

    func testCancelledProxyLeavesNoPartialFile() async throws {
        let source = try fixture("landscape4k")
        let metadata = try await MediaProbe().probe(fileURL: source, displayName: "4K")
        let output = try directory()
        defer { try? FileManager.default.removeItem(at: output) }
        let job = Task {
            try await ProxyEngine().createIfUseful(sourceURL: source,
                metadata: metadata, outputDirectory: output)
        }
        try await Task.sleep(for: .milliseconds(20))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Canceled proxy must not complete")
        } catch is CancellationError { }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertTrue(remaining.isEmpty, "Canceled proxy left: \(remaining)")
    }
}
