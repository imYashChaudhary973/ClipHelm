import Foundation
import CryptoKit

public enum YouTubeToolError: Error, LocalizedError, Equatable, Sendable {
    case downloadFailed
    case verificationFailed
    case launchFailed

    public var errorDescription: String? {
        switch self {
        case .downloadFailed: "The YouTube downloader could not be downloaded. Check your connection and try again."
        case .verificationFailed: "The downloaded YouTube downloader did not match its published checksum, so it was discarded. Try again later."
        case .launchFailed: "The YouTube downloader could not start on this Mac."
        }
    }
}

public struct YouTubeToolStatus: Equatable, Sendable {
    public enum Origin: Sendable { case managed, system }
    public let executable: URL
    public let origin: Origin
    public let version: String?
}

/// Installs the upstream, unmodified `yt-dlp_macos` release into Application Support.
/// The binary is verified against the release's SHA2-256SUMS file and is never re-signed:
/// ClipHelm's hardened runtime applies to ClipHelm only, not to this separate helper process.
public actor YouTubeToolManager {
    public static let shared = YouTubeToolManager()

    private static let asset = "yt-dlp_macos"
    private static let releases = "https://github.com/yt-dlp/yt-dlp/releases"
    private static let binaryLimit = 150_000_000
    private let directory: URL
    private let session: URLSession
    private var installing = false

    public init(directory: URL = YouTubeToolManager.defaultDirectory) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: GitHubRedirects(), delegateQueue: nil)
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "ClipHelm/Tools", directoryHint: .isDirectory)
    }

    public nonisolated var managedExecutable: URL { directory.appending(path: "yt-dlp") }

    /// The in-app copy wins because ClipHelm can keep it current; Homebrew installs remain supported.
    public nonisolated func installedExecutable() -> URL? {
        Self.candidates(managed: managedExecutable).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func candidates(managed: URL) -> [URL] {
        [managed, Bundle.main.resourceURL?.appending(path: "yt-dlp"),
         URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
         URL(fileURLWithPath: "/usr/local/bin/yt-dlp")].compactMap { $0 }
    }

    public func status() async -> YouTubeToolStatus? {
        guard let executable = installedExecutable() else { return nil }
        let version = try? await Self.version(of: executable)
        return YouTubeToolStatus(executable: executable,
            origin: executable == managedExecutable ? .managed : .system, version: version)
    }

    /// Downloads the latest release (or replaces an older in-app copy) and verifies it before use.
    public func install() async throws -> YouTubeToolStatus {
        guard !installing else { throw YouTubeToolError.downloadFailed }
        installing = true
        defer { installing = false }
        let tag = try await latestTag()
        let base = "\(Self.releases)/download/\(tag)/"
        guard let sumsURL = URL(string: base + "SHA2-256SUMS"),
              let binaryURL = URL(string: base + Self.asset) else { throw YouTubeToolError.downloadFailed }
        let sums = try await fetch(sumsURL, limit: 64_000)
        guard let expected = Self.checksum(for: Self.asset, in: String(decoding: sums, as: UTF8.self)) else {
            throw YouTubeToolError.verificationFailed
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let staged = directory.appending(path: ".yt-dlp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        let download: URL
        let response: URLResponse
        do { (download, response) = try await session.download(from: binaryURL) }
        catch is CancellationError { throw CancellationError() }
        catch { throw YouTubeToolError.downloadFailed }
        defer { try? FileManager.default.removeItem(at: download) }
        guard Self.isTrusted(response), (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw YouTubeToolError.downloadFailed
        }
        try FileManager.default.moveItem(at: download, to: staged)
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (1...Self.binaryLimit).contains(size), try Self.sha256(of: staged) == expected else {
            throw YouTubeToolError.verificationFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        removexattr(staged.path, "com.apple.quarantine", 0)
        let version: String
        do { version = try await Self.version(of: staged) }
        catch { throw YouTubeToolError.launchFailed }
        if FileManager.default.fileExists(atPath: managedExecutable.path) {
            _ = try FileManager.default.replaceItemAt(managedExecutable, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: managedExecutable)
        }
        return YouTubeToolStatus(executable: managedExecutable, origin: .managed, version: version)
    }

    /// Resolves `releases/latest` to a concrete tag so the checksum and binary come from one release.
    private func latestTag() async throws -> String {
        guard let url = URL(string: "\(Self.releases)/latest") else { throw YouTubeToolError.downloadFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw YouTubeToolError.downloadFailed }
        guard let final = response.url, Self.isTrusted(response),
              final.pathComponents.count >= 2,
              final.pathComponents[final.pathComponents.count - 2] == "tag" else {
            throw YouTubeToolError.downloadFailed
        }
        let tag = final.lastPathComponent
        guard (1...40).contains(tag.count),
              tag.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) else {
            throw YouTubeToolError.downloadFailed
        }
        return tag
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw YouTubeToolError.downloadFailed }
        guard Self.isTrusted(response), (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= limit else { throw YouTubeToolError.downloadFailed }
        return data
    }

    static func checksum(for asset: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == asset else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            return hash
        }
        return nil
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isTrustedHost(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    private static func isTrusted(_ response: URLResponse) -> Bool { isTrustedHost(response.url) }

    static func version(of executable: URL) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-ytdlp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let job = ToolProcess()
        job.process.executableURL = executable
        job.process.arguments = ["--ignore-config", "--version"]
        job.process.currentDirectoryURL = scratch
        job.process.environment = ["HOME": scratch.path, "TMPDIR": scratch.path, "PATH": "/usr/bin:/bin"]
        job.process.standardOutput = job.output
        job.process.standardError = FileHandle.nullDevice
        try job.process.run()
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(60))
            job.terminate()
        }
        let data = await Task.detached { job.output.fileHandleForReading.readDataToEndOfFile() }.value
        let status = await Task.detached { job.wait() }.value
        watchdog.cancel()
        let version = String(decoding: data.prefix(100), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !version.isEmpty else { throw YouTubeToolError.launchFailed }
        return version
    }
}

/// Owns a helper process so it can be observed and stopped from detached tasks.
final class ToolProcess: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    private let lock = NSLock()

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }

    func wait() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Release downloads redirect to GitHub's asset CDN; nothing else is followed.
private final class GitHubRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(YouTubeToolManager.isTrustedHost(request.url) ? request : nil)
    }
}
