import Foundation
import AVFoundation
import ClipHelmCore

@MainActor
enum MediaExport {
    static func run(sourceURL: URL, preset: String, fileType: AVFileType,
                    extension fileExtension: String, outputDirectory: URL,
                    range: MediaTimeRange? = nil,
                    stage: MediaProgress.Stage,
                    progress: @escaping MediaProgressHandler) async throws -> URL {
        guard sourceURL.isFileURL, outputDirectory.isFileURL else {
            throw MediaEngineError.invalidFile
        }
        try Task.checkCancellation()
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
              exporter.supportedFileTypes.contains(fileType) else {
            throw MediaEngineError.exportUnavailable
        }
        if let range {
            exporter.timeRange = CMTimeRange(start: CMTime(value: range.start.microseconds,
                                                           timescale: 1_000_000),
                                             end: CMTime(value: range.end.microseconds,
                                                         timescale: 1_000_000))
        }
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = outputDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        let observer = Task {
            while !Task.isCancelled {
                progress(MediaProgress(stage: stage, fraction: Double(exporter.progress)))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { observer.cancel() }
        do {
            try await exporter.export(to: temporary, as: fileType)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: temporary.path)
            progress(MediaProgress(stage: stage, fraction: 1))
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if Task.isCancelled { throw CancellationError() }
            throw MediaEngineError.processingFailed
        }
    }
}
