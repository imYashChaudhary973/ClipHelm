import Foundation
import Darwin
import ClipHelmCore
import ClipHelmMedia

private let remoteLimit: Int64 = 2_000_000_000
private let youtubeLimit: Int64 = 8_000_000_000

private final class DirectDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (SourceProgress) -> Void
    let destination: URL
    private let lock = NSLock()
    private var exceededLimit = false
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var savedFile: URL?
    private var saveError: Error?

    init(destination: URL, progress: @escaping @Sendable (SourceProgress) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    var isTooLarge: Bool { lock.lock(); defer { lock.unlock() }; return exceededLimit }

    func begin(_ task: URLSessionDownloadTask,
               continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            lock.lock(); savedFile = destination; lock.unlock()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lock.lock(); saveError = SourceIngestError.downloadFailed; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > remoteLimit || totalBytesExpectedToWrite > remoteLimit {
            lock.lock(); exceededLimit = true; lock.unlock()
            downloadTask.cancel()
            return
        }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        progress(SourceProgress(stage: .downloading, fraction: fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let file = savedFile
        let failure = saveError
        lock.unlock()
        guard let pending else { return }
        if let error { pending.resume(throwing: error) }
        else if let failure { pending.resume(throwing: failure) }
        else if let file, let response = task.response { pending.resume(returning: (file, response)) }
        else { pending.resume(throwing: SourceIngestError.downloadFailed) }
    }
}

public actor SourceIngestor {
    private let directory: URL
    private let youtubeExecutable: URL?
    private let directConfiguration: URLSessionConfiguration?
    private let hostResolver: @Sendable (String) -> Bool
    private let directURLImportEnabled: Bool
    private var completed: [SourceDescriptor: PreparedSource] = [:]
    private var active: Set<SourceDescriptor> = []
    private var sweptTemporaryStorage = false

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                youtubeExecutable: URL? = nil) {
        directory = temporaryDirectory.appending(path: "ClipHelmSources", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        self.youtubeExecutable = youtubeExecutable
        directConfiguration = nil
        hostResolver = Self.resolvesOnlyToPublicAddresses
        directURLImportEnabled = SourceImportPolicy.directURLImportEnabled
    }

#if DEBUG
    init(temporaryDirectory: URL, directConfiguration: URLSessionConfiguration,
         hostResolver: @escaping @Sendable (String) -> Bool,
         allowUnsafeDirectURLForTests: Bool = true) {
        directory = temporaryDirectory.appending(path: "ClipHelmSources", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        youtubeExecutable = nil
        self.directConfiguration = directConfiguration
        self.hostResolver = hostResolver
        directURLImportEnabled = allowUnsafeDirectURLForTests
    }
#endif

    deinit { try? FileManager.default.removeItem(at: directory) }

    public func prepare(
        _ descriptor: SourceDescriptor,
        progress: @escaping @Sendable (SourceProgress) -> Void = { _ in }
    ) async throws -> PreparedSource {
        try Task.checkCancellation()
        if descriptor.kind == .directVideo && !directURLImportEnabled {
            throw SourceIngestError.directURLDisabled
        }
        if let existing = completed[descriptor], FileManager.default.fileExists(atPath: existing.fileURL.path) {
            return existing
        }
        guard active.insert(descriptor).inserted else { throw SourceIngestError.duplicateInProgress }
        defer { active.remove(descriptor) }

        progress(SourceProgress(stage: .checking))
        var ownedURL: URL?
        do {
            let fileURL: URL
            var title: String?
            switch descriptor.storage {
            case .local(let url): fileURL = url
            case .directVideo(let url):
                sweepStaleTemporaryStorage()
                fileURL = try await downloadDirect(url, progress: progress)
                ownedURL = fileURL
            case .youtube(let videoID):
                sweepStaleTemporaryStorage()
                (fileURL, title) = try await downloadYouTube(videoID: videoID, progress: progress)
                ownedURL = fileURL
            }
            try Task.checkCancellation()
            progress(SourceProgress(stage: .validating))
            let metadata = try await inspect(fileURL, displayName: descriptor.displayLabel)
            try Task.checkCancellation()
            let prepared = PreparedSource(descriptor: descriptor, fileURL: fileURL,
                                          asset: metadata.asset, hasAudio: metadata.hasAudio, title: title)
            completed[descriptor] = prepared
            return prepared
        } catch {
            if let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func sweepStaleTemporaryStorage() {
        guard !sweptTemporaryStorage else { return }
        sweptTemporaryStorage = true
        let parent = directory.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        for entry in entries where entry != directory {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let created = values.creationDate, created < Date().addingTimeInterval(-86_400) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func inspect(_ url: URL, displayName: String) async throws -> MediaMetadata {
        do {
            return try await MediaProbe().probe(fileURL: url, displayName: displayName)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SourceIngestError.invalidMedia
        }
    }

    private func downloadDirect(_ url: URL, progress: @escaping @Sendable (SourceProgress) -> Void) async throws -> URL {
        guard let host = url.host, hostResolver(host) else {
            throw SourceIngestError.unsafeURL
        }
        try Task.checkCancellation()
        let configuration = directConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 1_800
        let extensionName = ["mp4", "mov", "mkv"].contains(url.pathExtension.lowercased())
            ? url.pathExtension.lowercased() : "mp4"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appending(path: UUID().uuidString).appendingPathExtension(extensionName)
        var keepDownload = false
        defer { if !keepDownload { try? FileManager.default.removeItem(at: destination) } }
        let delegate = DirectDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("video/mp4, video/quicktime, video/x-matroska, application/octet-stream", forHTTPHeaderField: "Accept")
        progress(SourceProgress(stage: .downloading))
        let location: URL
        let response: URLResponse
        do {
            let task = session.downloadTask(with: request)
            (location, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.begin(task, continuation: continuation)
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if delegate.isTooLarge { throw SourceIngestError.downloadTooLarge }
            if Task.isCancelled { throw CancellationError() }
            throw SourceIngestError.downloadFailed
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == url.host,
              http.statusCode == 200 else {
            throw SourceIngestError.downloadFailed
        }
        let mime = http.mimeType?.lowercased() ?? ""
        guard !["text/html", "text/plain", "application/json", "application/xml"].contains(mime) else {
            throw SourceIngestError.invalidMedia
        }
        let bytes = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, Int64(bytes) <= remoteLimit else {
            throw SourceIngestError.downloadTooLarge
        }
        keepDownload = true
        return location
    }

    func moveToTemporaryStore(_ source: URL, extensionName: String,
                              limit: Int64 = remoteLimit) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appending(path: UUID().uuidString).appendingPathExtension(extensionName)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, Int64(bytes) <= limit else {
                throw SourceIngestError.downloadTooLarge
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let error = error as? SourceIngestError { throw error }
            throw SourceIngestError.downloadFailed
        }
    }

    private static func resolvesOnlyToPublicAddresses(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            guard let address = current.pointee.ai_addr else { return false }
            switch current.pointee.ai_family {
            case AF_INET:
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                let bytes = withUnsafeBytes(of: ip) { Array($0) }
                let a = bytes[0], b = bytes[1], c = bytes[2]
                if a == 0 || a == 10 || a == 127 || a >= 224 ||
                    (a == 100 && (64...127).contains(b)) ||
                    (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                    (a == 192 && (b == 168 || (b == 0 && c == 0) || (b == 0 && c == 2))) ||
                    (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
                    (a == 203 && b == 0 && c == 113) { return false }
            case AF_INET6:
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let firstByte = withUnsafeBytes(of: ip) { $0[0] }
                if !(0x20...0x3f).contains(firstByte) { return false }
            default: return false
            }
            node = current.pointee.ai_next
        }
        return true
    }

    private func downloadYouTube(videoID: String,
                                 progress: @escaping @Sendable (SourceProgress) -> Void) async throws -> (URL, String?) {
        guard let executable = youtubeExecutable ?? YouTubeToolManager.shared.installedExecutable(),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SourceIngestError.youtubeToolUnavailable
        }
        let jobDirectory = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let control = ToolProcess()
        control.process.executableURL = executable
        control.process.currentDirectoryURL = jobDirectory
        control.process.environment = ["HOME": jobDirectory.path,
                                       "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                       "TMPDIR": jobDirectory.path]
        control.process.arguments = YouTubeDownload.arguments(videoID: videoID)
        control.process.standardOutput = control.output
        control.process.standardError = control.errors
        progress(SourceProgress(stage: .downloading))
        try Task.checkCancellation()
        do { try control.process.run() }
        catch { throw SourceIngestError.youtubeToolUnavailable }
        let reader = Task.detached { YouTubeDownload.readProgress(control.output.fileHandleForReading, progress) }
        let diagnostics = Task.detached { YouTubeDownload.readTail(control.errors.fileHandleForReading) }
        let status = await withTaskCancellationHandler {
            await Task.detached { control.wait() }.value
        } onCancel: {
            control.terminate()
        }
        await reader.value
        let errorText = await diagnostics.value
        try Task.checkCancellation()
        guard status == 0 else { throw YouTubeDownload.classify(errorText) }
        let files = ((try? FileManager.default.contentsOfDirectory(at: jobDirectory,
            includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { ["mp4", "m4a"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.pathExtension.lowercased() == "mp4" && $1.pathExtension.lowercased() != "mp4" }
        guard files.contains(where: { $0.pathExtension.lowercased() == "mp4" }) else {
            throw YouTubeDownload.classify(errorText)
        }
        progress(SourceProgress(stage: .validating))
        let combined = jobDirectory.appending(path: "combined.mp4")
        try await YouTubeStreamMuxer.mux(files, to: combined)
        for file in files { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        let title = YouTubeDownload.title(in: jobDirectory.appending(path: YouTubeDownload.titleFile))
        return (try moveToTemporaryStore(combined, extensionName: "mp4", limit: youtubeLimit), title)
    }
}

/// Fixed yt-dlp arguments and parsing of its output. Nothing from the network reaches a shell.
enum YouTubeDownload {
    static let progressPrefix = "[cliphelm] "
    static let titleFile = "title.txt"

    static func arguments(videoID: String) -> [String] {
        [
            "--ignore-config", "--no-playlist", "--no-cache-dir", "--no-plugin-dirs",
            "--no-remote-components", "--no-colors", "--newline", "--no-part",
            "--retries", "5", "--fragment-retries", "5", "--socket-timeout", "30",
            "--max-filesize", "4G",
            // H.264 and AAC decode on every supported Mac. They arrive as separate DASH streams,
            // which ClipHelm muxes itself, so FFmpeg is not required.
            "--format", "(bv*[ext=mp4][vcodec^=avc1][height<=1080],ba[ext=m4a])/(bv*[ext=mp4][vcodec^=avc1],ba[ext=m4a])/b[ext=mp4]",
            "--output", "%(format_id)s.%(ext)s",
            "--print-to-file", "after_move:%(title).200s", titleFile,
            // The leading "download:" selects the progress type; yt-dlp does not print it.
            "--progress-template",
            "download:\(progressPrefix)%(info.vcodec)s %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s",
            "https://www.youtube.com/watch?v=\(videoID)",
        ]
    }

    /// The first line of the published title with control characters removed.
    static func title(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), data.count <= 8_192,
              let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first else { return nil }
        let cleaned = String(String.UnicodeScalarView(line.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        })).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
    }

    /// Video is most of the transfer; the audio stream follows it.
    static func fraction(forLine line: String) -> Double? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let fields = line.dropFirst(progressPrefix.count).split(separator: " ")
        guard fields.count == 3, let done = Double(fields[1]), let total = Double(fields[2]),
              done.isFinite, total.isFinite, total > 0 else { return nil }
        let part = min(1, max(0, done / total))
        return fields[0] == "none" ? 0.9 + 0.1 * part : 0.9 * part
    }

    static func readProgress(_ handle: FileHandle, _ progress: @Sendable (SourceProgress) -> Void) {
        var buffer = Data()
        var furthest = 0.0
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                guard let fraction = fraction(forLine: line), fraction >= furthest else { continue }
                furthest = fraction
                progress(SourceProgress(stage: .downloading, fraction: fraction))
            }
            if buffer.count > 4096 { buffer.removeAll() }
        }
    }

    static func readTail(_ handle: FileHandle) -> String {
        var tail = Data()
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            tail.append(chunk)
            if tail.count > 16_384 { tail.removeFirst(tail.count - 16_384) }
        }
        return String(decoding: tail, as: UTF8.self)
    }

    /// Maps yt-dlp's diagnostics to a fixed message; its raw text is never shown.
    static func classify(_ diagnostics: String) -> SourceIngestError {
        let text = diagnostics.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("not a bot", "confirm you\u{2019}re not", "confirm you're not") { return .youtubeBotCheck }
        if has("confirm your age", "age-restricted", "inappropriate for some users") { return .youtubeRestricted }
        if has("private video", "members-only", "join this channel", "sign in to view",
               "drm protected", "this video is drm") { return .youtubeUnavailable }
        if has("live event", "is live", "premieres in", "is_live") { return .youtubeLive }
        if has("larger than max-filesize", "file is larger than") { return .downloadTooLarge }
        if has("requested format is not available", "no video formats found",
               "signature extraction failed", "nsig extraction failed", "unable to extract",
               "please report this issue") { return .youtubeToolOutdated }
        if has("unable to download", "urlopen error", "timed out", "connection reset",
               "name resolution", "nodename nor servname", "network is unreachable",
               "no route to host", "ssl") { return .downloadFailed }
        return .youtubeUnavailable
    }
}
