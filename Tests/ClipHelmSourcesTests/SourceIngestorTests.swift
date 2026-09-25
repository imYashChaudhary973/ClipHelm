import Foundation
import XCTest
@testable import ClipHelmSources

private final class DownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var fractions: [Double] = []
    var body = Data()
    func record() -> Data {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return body
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests }
    func recordProgress(_ update: SourceProgress) {
        guard let fraction = update.fraction else { return }
        lock.lock(); fractions.append(fraction); lock.unlock()
    }
    func hasMeasuredProgress() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fractions.contains { $0 > 0 }
    }
}

private final class DownloadProtocol: URLProtocol {
    static let state = DownloadState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        let body = Self.state.record()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "video/mp4", "Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SlowDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        Thread.sleep(forTimeInterval: 0.5)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "video/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: DownloadProtocol.state.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class SourceIngestorTests: XCTestCase {
    func testExternalBuildGateRejectsDirectURLsBeforeDNSOrNetwork() async throws {
        XCTAssertFalse(SourceImportPolicy.directURLImportEnabled)
#if DEBUG
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        let ingestor = SourceIngestor(temporaryDirectory: FileManager.default.temporaryDirectory,
            directConfiguration: configuration, hostResolver: { _ in
                XCTFail("The disabled path must not resolve DNS")
                return true
            }, allowUnsafeDirectURLForTests: false)
        let priorRequests = DownloadProtocol.state.count()
#else
        let ingestor = SourceIngestor()
#endif
        for raw in ["https://media.example.com/video.mp4", "https://0x7f.0.0.1/video.mp4",
                    "https://2130706433.example.com/video.mp4"] {
            let descriptor = try SourceDescriptor(remoteURL: raw, youtube: false, authorized: true)
            do {
                _ = try await ingestor.prepare(descriptor)
                XCTFail("Direct import must be disabled: \(raw)")
            } catch let error as SourceIngestError {
                XCTAssertEqual(error, .directURLDisabled)
            }
        }
#if DEBUG
        XCTAssertEqual(DownloadProtocol.state.count(), priorRequests)
#endif
    }

    func testLocalMediaValidationAndMetadata() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        let ingestor = SourceIngestor()
        let prepared = try await ingestor.prepare(SourceDescriptor(localFile: file))
        XCTAssertEqual(prepared.asset.width, 64)
        XCTAssertEqual(prepared.asset.height, 48)
        XCTAssertGreaterThan(prepared.asset.duration.microseconds, 0)
        XCTAssertEqual(prepared.fileURL, file)
        XCTAssertFalse(prepared.hasAudio)

        let bad = FileManager.default.temporaryDirectory.appending(path: "bad-\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        do {
            _ = try await ingestor.prepare(SourceDescriptor(localFile: bad))
            XCTFail("Malformed media must be rejected")
        } catch let error as SourceIngestError {
            XCTAssertEqual(error, .invalidMedia)
        }
    }

    func testRemoteDescriptorRejectsUnsafeAndUnauthorizedLinks() throws {
        XCTAssertThrowsError(try SourceDescriptor(remoteURL: "https://example.com/video.mp4",
                                                   youtube: false, authorized: false))
        for link in ["http://example.com/video.mp4", "file:///tmp/video.mp4",
                     "ftp://example.com/video.mp4", "data:video/mp4;base64,AA",
                     "https://127.0.0.1/video.mp4", "https://10.0.0.1/video.mp4",
                     "https://169.254.169.254/video.mp4", "https://[::1]/video.mp4",
                     "https://[fc00::1]/video.mp4", "https://[fe80::1]/video.mp4",
                     "https://localhost/video.mp4", "https://user:pass@example.com/video.mp4",
                     "https://youtube.com.evil.example/watch?v=abcdefghijk"] {
            XCTAssertThrowsError(try SourceDescriptor(remoteURL: link, youtube: link.contains("youtube"),
                                                       authorized: true), link)
        }
        let youtube = try SourceDescriptor(remoteURL: "https://youtu.be/abcdefghijk?t=60",
                                           youtube: true, authorized: true)
        XCTAssertEqual(youtube.kind, .youtube)
        let direct = try SourceDescriptor(remoteURL: "https://media.example.com/video.mp4?token=private",
                                          youtube: false, authorized: true)
        XCTAssertEqual(direct.displayLabel, "media.example.com")
    }

#if DEBUG
    func testDirectDownloadIsValidatedAndReused() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        DownloadProtocol.state.body = try Data(contentsOf: fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        let ingestor = SourceIngestor(temporaryDirectory: FileManager.default.temporaryDirectory,
                                      directConfiguration: configuration, hostResolver: { _ in true })
        let descriptor = try SourceDescriptor(remoteURL: "https://media.example.com/video.mp4",
                                              youtube: false, authorized: true)
        let observed = DownloadState()
        let first = try await ingestor.prepare(descriptor) { observed.recordProgress($0) }
        let second = try await ingestor.prepare(descriptor)
        XCTAssertEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(first.asset.id, second.asset.id)
        XCTAssertEqual(first.asset.width, 64)
        XCTAssertEqual(DownloadProtocol.state.count(), 1)
        XCTAssertTrue(observed.hasMeasuredProgress())
        let permissions = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
#endif

    func testYouTubeAdapterUsesCanonicalPublicURLAndValidatesMedia() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-YouTube-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "yt-dlp")
        let quotedFixture = "'\(fixture.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let script = """
        #!/bin/sh
        [ "$1" = "--ignore-config" ] || exit 1
        case "$*" in *'https://www.youtube.com/watch?v=abcdefghijk'*) ;; *) exit 1;; esac
        case "$*" in
          *'--format bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]'*) ;;
          *'--format best[ext=mp4]'*) ;;
          *) exit 1;;
        esac
        cp \(quotedFixture) video.mp4
        printf 'download:50%%\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let ingestor = SourceIngestor(temporaryDirectory: root, youtubeExecutable: executable)
        let descriptor = try SourceDescriptor(remoteURL: "https://youtu.be/abcdefghijk?t=60",
                                              youtube: true, authorized: true)
        let observed = DownloadState()
        let prepared = try await ingestor.prepare(descriptor) { observed.recordProgress($0) }
        XCTAssertEqual(prepared.asset.width, 64)
        XCTAssertTrue(observed.hasMeasuredProgress())
    }

    func testOptInAuthorizedYouTubeImport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["CLIPHELM_QA_YOUTUBE_URL"],
              let executablePath = environment["CLIPHELM_QA_YTDLP_BIN"] else {
            throw XCTSkip("Set CLIPHELM_QA_YOUTUBE_URL and CLIPHELM_QA_YTDLP_BIN for live authorized import")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-youtube-qa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try SourceDescriptor(remoteURL: raw, youtube: true, authorized: true)
        let ingestor = SourceIngestor(temporaryDirectory: root,
            youtubeExecutable: URL(fileURLWithPath: executablePath))
        let started = Date()
        let prepared = try await ingestor.prepare(descriptor)
        print("QA_YOUTUBE_DOWNLOAD_SECONDS=\(Date().timeIntervalSince(started))")
        print("QA_YOUTUBE_DIMENSIONS=\(prepared.asset.width)x\(prepared.asset.height)")
        print("QA_YOUTUBE_DURATION_SECONDS=\(Double(prepared.asset.duration.microseconds) / 1_000_000)")
        XCTAssertGreaterThan(prepared.asset.duration.microseconds, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
    }

#if DEBUG
    func testDirectDownloadCancellation() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        DownloadProtocol.state.body = try Data(contentsOf: fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowDownloadProtocol.self]
        let ingestor = SourceIngestor(temporaryDirectory: FileManager.default.temporaryDirectory,
                                      directConfiguration: configuration, hostResolver: { _ in true })
        let descriptor = try SourceDescriptor(remoteURL: "https://media.example.com/video.mp4",
                                              youtube: false, authorized: true)
        let job = Task { try await ingestor.prepare(descriptor) }
        try await Task.sleep(for: .milliseconds(50))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Canceled download must not yield a source")
        } catch is CancellationError { }
    }
#endif
}
