import Foundation
import CoreFoundation
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmMedia
import ClipHelmOpenRouter
import ClipHelmFraming

/// Optional classification of a few uncertain shots. The model never controls crop geometry.
public struct FramingVisionAdvisor: Sendable {
    public init() { }

    public func classify(sourceURL: URL, asset: MediaAsset, configuration: ClipConfiguration,
                         range: MediaTimeRange, analysis: AnalysisResult, registry: OpenRouterModelRegistry,
                         gateway: any OpenRouterGateway) async throws -> [ContentClassification] {
        guard configuration.framingMode == .smartAuto,
              configuration.smartEdit.useVisionForTrickyShots,
              let model = await registry.selectedModel(for: .visionAnalysis) else { return [] }
        guard sourceURL.isFileURL, range.end <= asset.duration else {
            throw ModelError.invalid("FramingVisionAdvisor inputs")
        }
        let sourceAspect = Double(asset.width) / Double(asset.height)
        let targetAspect = Double(configuration.outputFormat.width) / Double(configuration.outputFormat.height)
        if abs(sourceAspect / targetAspect - 1) < 0.002 { return [] }
        let job = Task.detached(priority: .utility) {
            try SmartAutoFrameEngine().frame(range: range, asset: asset,
                format: configuration.outputFormat, analysis: analysis).uncertainRanges
        }
        let uncertainRanges = try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-vision-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var hints: [ContentClassification] = []
        for range in uncertainRanges.prefix(3) {
            try Task.checkCancellation()
            let duration = range.durationMicroseconds
            let times = try [1, 3].map { fraction in
                try MediaTime(microseconds: range.start.microseconds + (duration / 4) * Int64(fraction))
            }
            let frames = try await ThumbnailEngine().generate(fileURL: sourceURL, at: times,
                outputDirectory: directory, maximumDimension: 512)
            let images = try frames.map { try Data(contentsOf: $0.fileURL, options: .mappedIfSafe) }
            let response = try await gateway.classifyFramingFrames(images, modelID: model.id)
            guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  Set(object.keys) == Set(["kind", "confidence"]),
                  let name = object["kind"] as? String,
                  let kind = ContentKind(rawValue: name),
                  let confidenceNumber = object["confidence"] as? NSNumber,
                  CFGetTypeID(confidenceNumber) != CFBooleanGetTypeID() else {
                throw OpenRouterGatewayError.invalidResponse
            }
            let confidence = confidenceNumber.doubleValue
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw OpenRouterGatewayError.invalidResponse
            }
            if confidence >= 0.65 && kind != .unknown {
                hints.append(try ContentClassification(range: range, kind: kind, confidence: confidence))
            }
        }
        return hints
    }
}
