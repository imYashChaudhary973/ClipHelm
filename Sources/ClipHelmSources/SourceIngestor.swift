import Foundation
import Darwin
import ClipHelmCore
import ClipHelmMedia

private let remoteLimit: Int64 = 2_000_000_000

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

private final class YouTubeProcess: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
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

    func readProgress(_ progress: @escaping @Sendable (SourceProgress) -> Void) {
        let handle = output.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                guard line.hasPrefix("download:"),
                      let percent = Double(line.dropFirst(9).trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "%", with: "")) else { continue }
                progress(SourceProgress(stage: .downloading, fraction: min(1, max(0, percent / 100))))
            }
            if buffer.count > 4096 { buffer.removeAll() }
        }
    }
}

public actor SourceIngestor {
    private let directory: URL
    private let youtubeExecutable: URL?
    private let directConfiguration: URLSessionConfiguration?
    private let hostResolver: @Sendable (String) -> Bool
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
    }

    init(temporaryDirectory: URL, directConfiguration: URLSessionConfiguration,
         hostResolver: @escaping @Sendable (String) -> Bool) {
        directory = temporaryDirectory.appending(path: "ClipHelmSources", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        youtubeExecutable = nil
        self.directConfiguration = directConfiguration
        self.hostResolver = hostResolver
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    public func prepare(
        _ descriptor: SourceDescriptor,
        progress: @escaping @Sendable (SourceProgress) -> Void = { _ in }
    ) async throws -> PreparedSource {
        try Task.checkCancellation()
        if let existing = completed[descriptor], FileManager.default.fileExists(atPath: existing.fileURL.path) {
            return existing
        }
        guard active.insert(descriptor).inserted else { throw SourceIngestError.duplicateInProgress }
        defer { active.remove(descriptor) }

        progress(SourceProgress(stage: .checking))
        var ownedURL: URL?
        do {
            let fileURL: URL
            switch descriptor.storage {
            case .local(let url): fileURL = url
            case .directVideo(let url):
                sweepStaleTemporaryStorage()
                fileURL = try await downloadDirect(url, progress: progress)
                ownedURL = fileURL
            case .youtube(let videoID):
                sweepStaleTemporaryStorage()
                fileURL = try await downloadYouTube(videoID: videoID, progress: progress)
                ownedURL = fileURL
            }
            try Task.checkCancellation()
            progress(SourceProgress(stage: .validating))
            let asset = try await inspect(fileURL, displayName: descriptor.displayLabel)
            try Task.checkCancellation()
            let prepared = PreparedSource(descriptor: descriptor, fileURL: fileURL, asset: asset)
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

    private func inspect(_ url: URL, displayName: String) async throws -> MediaAsset {
        do {
            return try await MediaProbe().probe(fileURL: url, displayName: displayName).asset
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

    func moveToTemporaryStore(_ source: URL, extensionName: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appending(path: UUID().uuidString).appendingPathExtension(extensionName)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, Int64(bytes) <= remoteLimit else {
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
                                 progress: @escaping @Sendable (SourceProgress) -> Void) async throws -> URL {
        let candidates = [youtubeExecutable,
                          Bundle.main.resourceURL?.appending(path: "yt-dlp"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
                          URL(fileURLWithPath: "/usr/local/bin/yt-dlp")].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SourceIngestError.youtubeToolUnavailable
        }
        let jobDirectory = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let control = YouTubeProcess()
        control.process.executableURL = executable
        control.process.currentDirectoryURL = jobDirectory
        control.process.environment = ["HOME": jobDirectory.path,
                                       "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                       "TMPDIR": jobDirectory.path]
        control.process.arguments = [
            "--ignore-config", "--no-playlist", "--no-cache-dir", "--no-plugin-dirs",
            "--no-remote-components", "--no-colors", "--newline",
            "--max-filesize", "2G", "--format", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]",
            "--merge-output-format", "mp4",
            "--output", "video.%(ext)s",
            "--progress-template", "download:%(progress._percent_str)s",
            "https://www.youtube.com/watch?v=\(videoID)"
        ]
        control.process.standardOutput = control.output
        control.process.standardError = FileHandle.nullDevice
        progress(SourceProgress(stage: .downloading))
        try Task.checkCancellation()
        do { try control.process.run() }
        catch { throw SourceIngestError.youtubeToolUnavailable }
        let reader = Task.detached { control.readProgress(progress) }
        let status = await withTaskCancellationHandler {
            await Task.detached { control.wait() }.value
        } onCancel: {
            control.terminate()
        }
        await reader.value
        try Task.checkCancellation()
        guard status == 0,
              let file = try? FileManager.default.contentsOfDirectory(at: jobDirectory,
                  includingPropertiesForKeys: [.isRegularFileKey]).first(where: { $0.pathExtension.lowercased() == "mp4" }) else {
            throw SourceIngestError.youtubeUnavailable
        }
        return try moveToTemporaryStore(file, extensionName: "mp4")
    }
}
