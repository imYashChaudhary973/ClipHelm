import Foundation
import ClipHelmCore

/// Optional decoder/export fallback. Arguments are built here; no shell is involved.
enum FFmpegMediaAdapter {
    private static var executable: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func hasSound(fileURL: URL) async throws -> Bool {
        guard let executable, fileURL.isFileURL else { throw MediaEngineError.processingFailed }
        let command = FFmpegProcess(executable: executable,
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file,pipe",
                        "-i", fileURL.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "pipe:1"])
        return try await withTaskCancellationHandler {
            try await Task.detached { try command.hasSound() }.value
        } onCancel: {
            command.terminate()
        }
    }

    static func proxy(source: URL, output: URL, width: Int, height: Int, duration: MediaTime,
                      progress: @escaping MediaProgressHandler) async throws {
        let targetWidth = min(1280, width)
        let targetHeight = min(720, height)
        try await run(source: source, output: output,
            arguments: ["-vf", "scale=w=\(targetWidth):h=\(targetHeight):force_original_aspect_ratio=decrease:force_divisible_by=2",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "25",
                        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"],
            duration: duration, stage: .proxy, progress: progress)
    }

    static func audio(source: URL, output: URL, range: MediaTimeRange,
                      progress: @escaping MediaProgressHandler) async throws {
        let start = String(format: "%.6f", Double(range.start.microseconds) / 1_000_000)
        let duration = String(format: "%.6f", Double(range.durationMicroseconds) / 1_000_000)
        try await run(source: source, output: output,
            arguments: ["-ss", start, "-t", duration, "-vn", "-c:a", "aac", "-b:a", "128k"],
            duration: try MediaTime(microseconds: range.durationMicroseconds),
            stage: .audio, progress: progress)
    }

    static func frame(source: URL, output: URL, time: MediaTime,
                      maximumDimension: Int) async throws {
        let seconds = String(format: "%.6f", Double(time.microseconds) / 1_000_000)
        try await run(source: source, output: output,
            arguments: ["-ss", seconds, "-frames:v", "1", "-vf",
                        "scale=w=\(maximumDimension):h=\(maximumDimension):force_original_aspect_ratio=decrease",
                        "-q:v", "3"], duration: nil, stage: .thumbnail, progress: { _ in })
    }

    private static func run(source: URL, output: URL, arguments: [String],
                            duration: MediaTime?, stage: MediaProgress.Stage,
                            progress: @escaping MediaProgressHandler) async throws {
        guard let executable, source.isFileURL, output.isFileURL,
              source.standardizedFileURL != output.standardizedFileURL else {
            throw MediaEngineError.exportUnavailable
        }
        try Task.checkCancellation()
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = FFmpegProcess(executable: executable,
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error",
                        "-protocol_whitelist", "file,pipe", "-progress", "pipe:1",
                        "-i", source.path] + arguments + ["-y", output.path])
        do {
            try await withTaskCancellationHandler {
                try await Task.detached {
                    try command.execute { line in
                        guard let duration, duration.microseconds > 0,
                              line.hasPrefix("out_time_us="),
                              let elapsed = Int64(line.dropFirst("out_time_us=".count)) else { return }
                        progress(MediaProgress(stage: stage,
                            fraction: Double(elapsed) / Double(duration.microseconds)))
                    }
                }.value
            } onCancel: {
                command.terminate()
            }
            try Task.checkCancellation()
            guard let values = try? output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw MediaEngineError.processingFailed
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: output.path)
            progress(MediaProgress(stage: stage, fraction: 1))
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw CancellationError() }
            throw MediaEngineError.processingFailed
        }
    }
}

private final class FFmpegProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func terminate() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
    }

    func execute(onLine: (String) -> Void) throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw MediaEngineError.processingFailed }
        lock.unlock()
        let handle = output.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                onLine(line)
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 16_384 { buffer.removeAll() }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MediaEngineError.processingFailed }
    }

    func hasSound() throws -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw MediaEngineError.processingFailed }
        lock.unlock()
        let handle = output.fileHandleForReading
        var activeSamples = 0
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            for index in stride(from: 0, to: chunk.count - chunk.count % 2, by: 2) {
                let value = Int16(bitPattern: UInt16(chunk[index]) | (UInt16(chunk[index + 1]) << 8))
                if abs(Int(value)) > 131 { activeSamples += 1 }
            }
            if activeSamples >= 1_280 {
                terminate()
                process.waitUntilExit()
                return true
            }
        }
        process.waitUntilExit()
        if cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw MediaEngineError.processingFailed }
        return false
    }
}
