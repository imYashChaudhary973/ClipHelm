import Foundation
import CoreFoundation
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmLayouts
import ClipHelmMedia
import ClipHelmOpenRouter

/// Optional subtype evidence for screen segments the local detector could not identify.
public struct LayoutVisionAdvisor: Sendable {
    public init() { }

    public func classify(sourceURL: URL, asset: MediaAsset, configuration: ClipConfiguration,
                         range: MediaTimeRange, analysis: AnalysisResult,
                         localHints: [ScreenContentHint], registry: OpenRouterModelRegistry,
                         gateway: any OpenRouterGateway) async throws -> [ScreenContentHint] {
        guard configuration.smartEdit.useVisionForTrickyShots,
              let model = await registry.selectedModel(for: .visionAnalysis) else { return [] }
        guard sourceURL.isFileURL, range.end <= asset.duration,
              localHints.allSatisfy({ $0.range.end <= asset.duration }) else {
            throw ModelError.invalid("LayoutVisionAdvisor inputs")
        }
        try analysis.validate(for: asset)
        let uncertain = analysis.classifications.compactMap { label -> MediaTimeRange? in
            let screenLabel = [.screenShare, .presentation, .demo].contains(label.kind)
            let screenSignal = analysis.signals.contains { $0.kind == .screenContent &&
                $0.range.start < label.range.end && label.range.start < $0.range.end &&
                $0.strength * $0.confidence >= 0.25 }
            guard (screenLabel || screenSignal),
                  label.range.start < range.end, range.start < label.range.end else { return nil }
            let start = max(range.start, label.range.start)
            let end = min(range.end, label.range.end)
            guard start < end else { return nil }
            let supported = localHints.contains { $0.confidence >= 0.65 &&
                $0.kind != .unknown && $0.kind != .screenShare &&
                $0.range.start <= start && end <= $0.range.end }
            return supported ? nil : try? MediaTimeRange(start: start, end: end)
        }
        guard !uncertain.isEmpty else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-layout-vision-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var hints: [ScreenContentHint] = []
        for window in uncertain.prefix(3) {
            try Task.checkCancellation()
            let duration = window.durationMicroseconds
            let times = try [1, 3].map { fraction in
                try MediaTime(microseconds: window.start.microseconds + (duration / 4) * Int64(fraction))
            }
            let frames = try await ThumbnailEngine().generate(fileURL: sourceURL, at: times,
                outputDirectory: directory, maximumDimension: 512)
            let images = try frames.map { try Data(contentsOf: $0.fileURL, options: .mappedIfSafe) }
            let response = try await gateway.classifyLayoutFrames(images, modelID: model.id)
            guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  Set(object.keys) == Set(["kind", "confidence"]),
                  let name = object["kind"] as? String,
                  let kind = ScreenContentKind(rawValue: name),
                  let number = object["confidence"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw OpenRouterGatewayError.invalidResponse
            }
            let confidence = number.doubleValue
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw OpenRouterGatewayError.invalidResponse
            }
            if confidence >= 0.65 && kind != .unknown {
                hints.append(try ScreenContentHint(range: window, kind: kind, confidence: confidence))
            }
        }
        return hints
    }
}
