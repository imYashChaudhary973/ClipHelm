import Foundation
import ClipHelmCore
import ClipHelmAnalysis

public struct FramingResult: Sendable {
    public let paths: [CropPath]
    public let uncertainRanges: [MediaTimeRange]
}

/// Local, source-time camera planning. AI classifications may influence focus, never coordinates.
public struct SmartAutoFrameEngine: Sendable {
    public init() { }

    public func frame(range: MediaTimeRange, asset: MediaAsset, format: OutputFormat,
                      analysis: AnalysisResult,
                      visionHints: [ContentClassification] = []) throws -> FramingResult {
        try analysis.validate(for: asset)
        guard range.end <= asset.duration,
              visionHints.allSatisfy({ $0.range.end <= asset.duration &&
                  $0.confidence.isFinite && (0...1).contains($0.confidence) }) else {
            throw ModelError.invalid("SmartAutoFrame inputs")
        }
        let sourceAspect = Double(asset.width) / Double(asset.height)
        let targetAspect = Double(format.width) / Double(format.height)
        let cropWidth = min(1, targetAspect / sourceAspect)
        let cropHeight = min(1, sourceAspect / targetAspect)
        var paths: [CropPath] = []
        var uncertain: [MediaTimeRange] = []
        for scene in analysis.scenes {
            let start = max(range.start, scene.range.start)
            let end = min(range.end, scene.range.end)
            guard start < end else { continue }
            let sceneRange = try MediaTimeRange(start: start, end: end)
            var cursor = start
            var previous: Point?
            while cursor < end {
                try Task.checkCancellation()
                let chunkEnd = try MediaTime(microseconds: end.microseconds - cursor.microseconds <= 30_000_000
                    ? end.microseconds : cursor.microseconds + 30_000_000)
                let chunk = try MediaTimeRange(start: cursor, end: chunkEnd)
                let count = min(240, Int((chunk.durationMicroseconds - 1) / 500_000) + 1)
                var confidenceSum = 0.0
                var frames: [CropKeyframe] = []
                for index in 0..<count {
                    let time = try MediaTime(microseconds: cursor.microseconds + Int64(index) * 500_000)
                    let lookAhead = try MediaTime(microseconds: time.microseconds +
                        min(750_000, end.microseconds - 1 - time.microseconds))
                    let focus = focus(at: lookAhead, scene: sceneRange, analysis: analysis,
                                      hints: visionHints, cropWidth: cropWidth)
                    confidenceSum += focus.confidence
                    let next: Point
                    if let previous {
                        let elapsed = 0.5
                        // The dead zone and slow camera keep small face movements from becoming pans.
                        let desired = Point(x: abs(focus.point.x - previous.x) < 0.045 ? previous.x : focus.point.x,
                                            y: abs(focus.point.y - previous.y) < 0.045 ? previous.y : focus.point.y)
                        let alpha = 1 - exp(-elapsed / 1.1)
                        let maxStep = 0.16 * elapsed
                        next = Point(x: previous.x + clamp((desired.x - previous.x) * alpha, -maxStep, maxStep),
                                     y: previous.y + clamp((desired.y - previous.y) * alpha, -maxStep, maxStep))
                    } else {
                        // A new scene starts at its own subject instead of panning across a cut.
                        next = focus.point
                    }
                    previous = next
                    frames.append(CropKeyframe(sourceTime: time,
                        rect: try rect(center: next, width: cropWidth, height: cropHeight)))
                }
                let last = try MediaTime(microseconds: chunkEnd.microseconds)
                frames.append(CropKeyframe(sourceTime: last, rect: frames.last!.rect))
                let movement = frames.dropFirst().reduce(0.0) { value, frame in
                    max(value, abs(frame.rect.x - frames[0].rect.x), abs(frame.rect.y - frames[0].rect.y))
                }
                if movement < 0.003 { frames = [frames[0]] }
                paths.append(try CropPath(sourceRange: chunk, keyframes: frames))
                if confidenceSum / Double(count) < 0.55 { uncertain.append(chunk) }
                cursor = chunkEnd
            }
        }
        return FramingResult(paths: paths, uncertainRanges: uncertain)
    }

    private func focus(at time: MediaTime, scene: MediaTimeRange, analysis: AnalysisResult,
                       hints: [ContentClassification], cropWidth: Double) -> Focus {
        let classification = (hints + analysis.classifications)
            .filter { $0.range.start <= time && time < $0.range.end }
            .max { $0.confidence < $1.confidence }
        let screen = analysis.signals.filter { $0.kind == .screenContent &&
            $0.range.start <= time && time < $0.range.end }
            .map { $0.strength * $0.confidence }.max() ?? 0
        let screenKind = classification.map { [.screenShare, .presentation, .demo, .gameplay].contains($0.kind) } ?? false
        if screenKind && (screen > 0.28 || (classification?.confidence ?? 0) >= 0.75) {
            return Focus(point: Point(x: 0.5, y: 0.5), confidence: max(screen, classification?.confidence ?? 0) * 0.8)
        }
        let candidates: [(point: Point, score: Double, confidence: Double)] = analysis.subjectTracks.compactMap { track in
            guard let sample = sample(track, at: time, scene: scene) else { return nil }
            let span = max(0, min(scene.end.microseconds, track.observations.last!.time.microseconds) -
                max(scene.start.microseconds, track.observations.first!.time.microseconds))
            let persistence = min(1, Double(span) / max(1, Double(scene.durationMicroseconds)))
            let size = min(1, sample.bounds.width * sample.bounds.height * 6)
            let face = analysis.detections.contains { detection in
                detection.isFace && abs(detection.time.microseconds - time.microseconds) <= 1_500_000 &&
                hypot(detection.bounds.x + detection.bounds.width / 2 - sample.point.x,
                      detection.bounds.y + detection.bounds.height / 2 - sample.point.y) < 0.12
            }
            let score = sample.confidence * (0.65 + 0.2 * persistence + 0.15 * size) + (face ? 0.08 : 0)
            return (sample.point, score, sample.confidence)
        }.sorted { $0.score > $1.score }
        guard let primary = candidates.first else {
            return Focus(point: Point(x: 0.5, y: 0.5), confidence: screenKind ? 0.55 : 0.1)
        }
        if let second = candidates.dropFirst().first,
           abs(primary.point.x - second.point.x) < cropWidth * 0.72,
           second.score >= primary.score * 0.68 {
            return Focus(point: Point(x: (primary.point.x + second.point.x) / 2,
                                      y: (primary.point.y + second.point.y) / 2),
                         confidence: min(primary.confidence, second.confidence))
        }
        return Focus(point: primary.point, confidence: primary.confidence)
    }

    private func sample(_ track: SubjectTrack, at time: MediaTime,
                        scene: MediaTimeRange) -> (point: Point, bounds: NormalizedRect, confidence: Double)? {
        let observations = track.observations.filter { scene.start <= $0.time && $0.time < scene.end }
        guard !observations.isEmpty else { return nil }
        let nextIndex = observations.firstIndex { $0.time >= time }
        if let nextIndex, observations[nextIndex].time == time {
            let box = observations[nextIndex].bounds
            return (Point(x: box.x + box.width / 2, y: box.y + box.height / 2), box, 0.9)
        }
        if let nextIndex, nextIndex > 0 {
            let before = observations[nextIndex - 1], after = observations[nextIndex]
            let gap = after.time.microseconds - before.time.microseconds
            guard gap <= 3_000_000 else { return nil }
            let fraction = Double(time.microseconds - before.time.microseconds) / Double(gap)
            let x = before.bounds.x + before.bounds.width / 2
            let y = before.bounds.y + before.bounds.height / 2
            let afterX = after.bounds.x + after.bounds.width / 2
            let afterY = after.bounds.y + after.bounds.height / 2
            return (Point(x: x + (afterX - x) * fraction, y: y + (afterY - y) * fraction),
                    before.bounds, 0.8)
        }
        let nearby = nextIndex == nil ? observations.last! : observations[0]
        let gap = abs(time.microseconds - nearby.time.microseconds)
        guard gap <= 2_000_000 else { return nil }
        let box = nearby.bounds
        return (Point(x: box.x + box.width / 2, y: box.y + box.height / 2), box,
                0.65 * (1 - Double(gap) / 3_000_000))
    }

    private func rect(center: Point, width: Double, height: Double) throws -> NormalizedRect {
        try NormalizedRect(x: clamp(center.x - width / 2, 0, 1 - width),
                           y: clamp(center.y - height / 2, 0, 1 - height),
                           width: width, height: height)
    }
}

private struct Point { let x: Double; let y: Double }
private struct Focus { let point: Point; let confidence: Double }
private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
}
