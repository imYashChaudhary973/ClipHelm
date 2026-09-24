import Foundation
import CryptoKit
import ClipHelmCore

struct AnalysisCache: Sendable {
    private static let version = 1
    private static let fileName = "analysis-v1.json"
    private static let maximumBytes = 50_000_000

    private struct Envelope: Codable {
        let version: Int
        let sourceFingerprint: String
        let result: AnalysisResult
    }

    func fingerprint(sourceURL: URL) async throws -> String {
        try await runAnalysisOffMain {
            try Task.checkCancellation()
            guard sourceURL.isFileURL else { throw ModelError.invalid("Analysis source URL") }
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw ModelError.invalid("Analysis source file")
            }
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            var evidence = Data("\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):".utf8)
            evidence.append(try handle.read(upToCount: 65_536) ?? Data())
            if size > 65_536 {
                try handle.seek(toOffset: UInt64(max(0, size - 65_536)))
                evidence.append(try handle.read(upToCount: 65_536) ?? Data())
            }
            try Task.checkCancellation()
            return SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
        }
    }

    func load(directory: URL, fingerprint: String, asset: MediaAsset) async throws -> AnalysisResult? {
        try await runAnalysisOffMain {
            try Task.checkCancellation()
            let file = directory.appending(path: Self.fileName)
            guard directory.isFileURL,
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...Self.maximumBytes).contains(size),
                  let data = try? Data(contentsOf: file),
                  let saved = try? JSONDecoder().decode(Envelope.self, from: data),
                  saved.version == Self.version,
                  saved.sourceFingerprint == fingerprint,
                  (try? saved.result.validate(for: asset)) != nil else { return nil }
            try Task.checkCancellation()
            return saved.result
        }
    }

    func save(_ result: AnalysisResult, directory: URL, fingerprint: String) async throws {
        try await runAnalysisOffMain {
            try Task.checkCancellation()
            guard directory.isFileURL else { throw ModelError.invalid("Analysis cache directory") }
            if let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                throw ModelError.invalid("Analysis cache directory")
            }
            try FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(Envelope(version: Self.version,
                sourceFingerprint: fingerprint, result: result))
            guard data.count <= Self.maximumBytes else { throw ModelError.invalid("Analysis cache size") }
            try Task.checkCancellation()
            let file = directory.appending(path: Self.fileName)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: file.path)
            try Task.checkCancellation()
        }
    }
}
