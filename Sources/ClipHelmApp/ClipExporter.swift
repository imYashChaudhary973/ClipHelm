import Foundation

struct ClipExportItem: Sendable {
    let title: String
    let fileURL: URL
}

enum ClipExportError: Error, LocalizedError {
    case invalidSource
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .invalidSource: "A selected clip is missing. Regenerate it before exporting."
        case .invalidDestination: "Choose a writable folder for the exported clips."
        }
    }
}

/// Copies only validated project MP4s. A failed batch removes files created by that batch.
struct ClipExporter: Sendable {
    func export(_ items: [ClipExportItem], from projectDirectory: URL,
                to destination: URL,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        guard !items.isEmpty, destination.isFileURL, projectDirectory.isFileURL,
              (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ClipExportError.invalidDestination
        }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        let sourceRoot = projectDirectory.resolvingSymlinksInPath().standardizedFileURL
        var created: [URL] = []
        do {
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                guard item.fileURL.isFileURL, item.fileURL.pathExtension.lowercased() == "mp4",
                      item.fileURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == sourceRoot,
                      FileManager.default.fileExists(atPath: item.fileURL.path) else {
                    throw ClipExportError.invalidSource
                }
                let base = Self.safeName(item.title)
                var target = destination.appending(path: base).appendingPathExtension("mp4")
                var suffix = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    guard suffix <= 10_000 else { throw ClipExportError.invalidDestination }
                    target = destination.appending(path: "\(base)-\(suffix)").appendingPathExtension("mp4")
                    suffix += 1
                }
                let temporary = destination.appending(path: ".cliphelm-\(UUID().uuidString).tmp")
                do {
                    let source = try FileHandle(forReadingFrom: item.fileURL)
                    defer { try? source.close() }
                    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                        throw ClipExportError.invalidDestination
                    }
                    let output = try FileHandle(forWritingTo: temporary)
                    defer { try? output.close() }
                    let size = (try? item.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    var copied = 0
                    while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                        try Task.checkCancellation()
                        try output.write(contentsOf: chunk)
                        copied += chunk.count
                        progress((Double(index) + Double(copied) / Double(max(1, size))) / Double(items.count))
                    }
                    try output.synchronize()
                    try output.close()
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: target)
                    created.append(target)
                    progress(Double(index + 1) / Double(items.count))
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            }
            return created
        } catch {
            for file in created { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    private static func safeName(_ title: String) -> String {
        let cleaned = title.unicodeScalars.map { scalar in
            scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar)
                ? "-" : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String((cleaned.isEmpty ? "Clip" : cleaned).prefix(80))
    }
}
