import Foundation
import ClipHelmCore

public enum LocalSignalKind: String, Codable, Sendable {
    case sceneChange, motion, audioActivity, pause, screenContent, textDensity
}

/// All ranges use source-media time. Strength and confidence are independent values in 0...1.
public struct LocalSignal: Codable, Equatable, Sendable {
    public let kind: LocalSignalKind
    public let range: MediaTimeRange
    public let strength: Double
    public let confidence: Double

    public init(kind: LocalSignalKind, range: MediaTimeRange,
                strength: Double, confidence: Double) throws {
        guard [strength, confidence].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ModelError.invalid("LocalSignal")
        }
        self.kind = kind
        self.range = range
        self.strength = strength
        self.confidence = confidence
    }
}

public struct SubjectDetection: Codable, Equatable, Sendable {
    public let time: MediaTime
    public let bounds: NormalizedRect
    public let confidence: Double
    public let isFace: Bool

    public init(time: MediaTime, bounds: NormalizedRect,
                confidence: Double, isFace: Bool) throws {
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw ModelError.invalid("SubjectDetection.confidence")
        }
        self.time = time
        self.bounds = bounds
        self.confidence = confidence
        self.isFace = isFace
    }
}

public enum ContentKind: String, Codable, CaseIterable, Sendable {
    case talkingHead, conversation, screenShare, presentation, demo, gameplay, unknown
}

public struct ContentClassification: Codable, Equatable, Sendable {
    public let range: MediaTimeRange
    public let kind: ContentKind
    public let confidence: Double

    public init(range: MediaTimeRange, kind: ContentKind, confidence: Double) throws {
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw ModelError.invalid("ContentClassification.confidence")
        }
        self.range = range
        self.kind = kind
        self.confidence = confidence
    }

    public var uncertainty: Double { 1 - confidence }
}

public struct AnalysisResult: Codable, Equatable, Sendable {
    public let assetID: AssetID
    public let sourceDuration: MediaTime
    public let scenes: [Scene]
    public let signals: [LocalSignal]
    public let detections: [SubjectDetection]
    public let subjectTracks: [SubjectTrack]
    public let classifications: [ContentClassification]

    public init(asset: MediaAsset, scenes: [Scene], signals: [LocalSignal],
                detections: [SubjectDetection], subjectTracks: [SubjectTrack],
                classifications: [ContentClassification]) throws {
        assetID = asset.id
        sourceDuration = asset.duration
        self.scenes = scenes
        self.signals = signals
        self.detections = detections
        self.subjectTracks = subjectTracks
        self.classifications = classifications
        try validate(for: asset)
    }

    public func validate(for asset: MediaAsset) throws {
        guard assetID == asset.id, sourceDuration == asset.duration,
              !scenes.isEmpty, scenes.first?.range.start.microseconds == 0,
              scenes.last?.range.end == asset.duration,
              zip(scenes, scenes.dropFirst()).allSatisfy({ $0.range.end == $1.range.start }),
              scenes.allSatisfy({ $0.assetID == asset.id && $0.range.end <= asset.duration }),
              signals.allSatisfy({ $0.range.end <= asset.duration &&
                  [$0.strength, $0.confidence].allSatisfy { $0.isFinite && (0...1).contains($0) } }),
              detections.allSatisfy({ $0.time < asset.duration &&
                  $0.confidence.isFinite && (0...1).contains($0.confidence) }),
              subjectTracks.allSatisfy({ $0.assetID == asset.id &&
                  $0.observations.allSatisfy { $0.time < asset.duration } }),
              classifications.first?.range.start.microseconds == 0,
              classifications.last?.range.end == asset.duration,
              classifications.allSatisfy({ $0.range.end <= asset.duration &&
                  $0.confidence.isFinite && (0...1).contains($0.confidence) }),
              zip(classifications, classifications.dropFirst()).allSatisfy({ $0.range.end == $1.range.start }) else {
            throw ModelError.invalid("AnalysisResult")
        }
    }
}

public struct AnalysisProgress: Sendable {
    public enum Stage: Sendable { case video, audio, classifying, caching }
    public let stage: Stage
    public let fraction: Double

    public init(stage: Stage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}

public typealias AnalysisProgressHandler = @Sendable (AnalysisProgress) -> Void

func runAnalysisOffMain<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let job = Task.detached(priority: .utility, operation: operation)
    return try await withTaskCancellationHandler {
        try await job.value
    } onCancel: {
        job.cancel()
    }
}
