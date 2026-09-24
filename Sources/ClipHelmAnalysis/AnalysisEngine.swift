import Foundation
import ClipHelmCore
import ClipHelmMedia

public struct AnalysisEngine: Sendable {
    public init() { }

    public func analyze(sourceURL: URL, asset: MediaAsset, cacheDirectory: URL,
                        progress: @escaping AnalysisProgressHandler = { _ in }) async throws -> AnalysisResult {
        guard sourceURL.isFileURL, cacheDirectory.isFileURL else { throw MediaEngineError.invalidFile }
        try Task.checkCancellation()
        let metadata = try await MediaProbe().probe(fileURL: sourceURL,
            displayName: asset.displayName, id: asset.id)
        guard metadata.asset.duration == asset.duration,
              metadata.asset.width == asset.width,
              metadata.asset.height == asset.height else {
            throw ModelError.invalid("Analysis source metadata changed")
        }
        let cache = AnalysisCache()
        let fingerprint = try await cache.fingerprint(sourceURL: sourceURL)
        if let saved = try await cache.load(directory: cacheDirectory,
                                       fingerprint: fingerprint, asset: asset) {
            try Task.checkCancellation()
            return saved
        }

        let samples = try await LocalVideoSampler().sample(sourceURL: sourceURL,
            asset: asset, progress: progress)
        try Task.checkCancellation()
        let audio = try await AudioActivityDetector().analyze(sourceURL: sourceURL,
            asset: asset, hasAudio: metadata.hasAudio, progress: progress)
        try Task.checkCancellation()
        progress(.init(stage: .classifying, fraction: 0))
        let result = try await runAnalysisOffMain {
            let (scenes, cuts) = try SceneDetector().detect(asset: asset, samples: samples)
            let motion = try MotionAnalyzer().analyze(asset: asset, samples: samples)
            let screen = try ScreenContentSignals().analyze(asset: asset, samples: samples)
            let pauses = try PauseDetector().detect(activity: audio)
            let detections = samples.flatMap(\.detections)
            let sampleGap = samples.count > 1
                ? samples[1].time.microseconds - samples[0].time.microseconds : 1_000_000
            let tracks = try SubjectTracker().track(assetID: asset.id, detections: detections,
                maximumGap: max(3_000_000, min(sampleGap, Int64.max / 3) * 3))
            let classifications = try ContentClassifier().classify(asset: asset,
                samples: samples, audio: audio)
            let signals = (cuts + motion + screen + audio + pauses).sorted {
                $0.range.start == $1.range.start
                    ? $0.kind.rawValue < $1.kind.rawValue : $0.range.start < $1.range.start
            }
            return try AnalysisResult(asset: asset, scenes: scenes, signals: signals,
                detections: detections, subjectTracks: tracks,
                classifications: classifications)
        }
        try Task.checkCancellation()
        progress(.init(stage: .classifying, fraction: 1))
        guard try await cache.fingerprint(sourceURL: sourceURL) == fingerprint else {
            throw ModelError.invalid("Analysis source changed during processing")
        }
        progress(.init(stage: .caching, fraction: 0))
        try await cache.save(result, directory: cacheDirectory, fingerprint: fingerprint)
        try Task.checkCancellation()
        progress(.init(stage: .caching, fraction: 1))
        return result
    }
}

struct ContentClassifier: Sendable {
    func classify(asset: MediaAsset, samples: [VideoSample],
                  audio: [LocalSignal]) throws -> [ContentClassification] {
        let sampleGap = samples.count > 1
            ? samples[1].time.microseconds - samples[0].time.microseconds : 1_000_000
        let window = max(5_000_000, min(sampleGap, Int64.max / 3) * 3)
        var output: [ContentClassification] = []
        var start: Int64 = 0
        var sampleIndex = 0
        var audioIndex = 0
        while start < asset.duration.microseconds {
            try Task.checkCancellation()
            let end = start + min(window, asset.duration.microseconds - start)
            var frames: [VideoSample] = []
            while sampleIndex < samples.count && samples[sampleIndex].time.microseconds < end {
                if samples[sampleIndex].time.microseconds >= start { frames.append(samples[sampleIndex]) }
                sampleIndex += 1
            }
            var energy = 0.0
            var audioCount = 0
            while audioIndex < audio.count && audio[audioIndex].range.start.microseconds < end {
                if audio[audioIndex].range.end.microseconds > start {
                    energy += audio[audioIndex].strength
                    audioCount += 1
                }
                audioIndex += 1
            }
            let range = try MediaTimeRange(start: MediaTime(microseconds: start),
                                            end: MediaTime(microseconds: end))
            guard !frames.isEmpty else {
                output.append(try ContentClassification(range: range, kind: .unknown, confidence: 0.1))
                start = end
                continue
            }
            let screen = frames.map(\.screenScore).reduce(0, +) / Double(frames.count)
            let text = frames.map(\.textDensity).reduce(0, +) / Double(frames.count)
            let motion = frames.map(\.motion).reduce(0, +) / Double(frames.count)
            let sound = audioCount > 0 ? energy / Double(audioCount) : 0
            let faceFrames = frames.filter { $0.detections.contains(where: \.isFace) }.count
            let multipleFaces = frames.filter { $0.detections.filter(\.isFace).count >= 2 }.count
            let faceRatio = Double(faceFrames) / Double(frames.count)
            let conversationRatio = Double(multipleFaces) / Double(frames.count)
            let subjectCoverage = Double(frames.filter(\.subjectsReliable).count) / Double(frames.count)

            let kind: ContentKind
            let confidence: Double
            if conversationRatio >= 0.4 && screen < 0.35 {
                kind = .conversation
                confidence = min(0.72, 0.42 + conversationRatio * 0.2 + sound * 0.08)
            } else if faceRatio >= 0.5 && screen < 0.35 {
                kind = .talkingHead
                confidence = min(0.7, 0.39 + faceRatio * 0.19 + sound * 0.08)
            } else if screen >= 0.40 && motion < 0.20 {
                kind = .presentation
                confidence = min(0.65, 0.36 + screen * 0.22)
            } else if screen >= 0.45 && motion >= 0.28 {
                kind = .demo
                confidence = min(0.63, 0.34 + screen * 0.18 + motion * 0.10)
            } else if screen >= 0.35 {
                kind = .screenShare
                confidence = min(0.60, 0.32 + screen * 0.2)
            } else if subjectCoverage >= 0.5 && faceRatio == 0 && text < 0.25 && motion >= 0.45 {
                kind = .gameplay
                confidence = min(0.52, 0.30 + motion * 0.22)
            } else {
                kind = .unknown
                confidence = 0.2
            }
            let coverage = min(1, 5_000_000 / Double(window))
            output.append(try ContentClassification(range: range, kind: kind,
                                                     confidence: confidence * coverage))
            start = end
        }
        return output
    }
}
