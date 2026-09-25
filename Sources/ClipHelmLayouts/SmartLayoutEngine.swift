import Foundation
import ClipHelmCore
import ClipHelmAnalysis

public enum ScreenContentKind: String, Codable, CaseIterable, Sendable {
    case ideCode, browserDemo, slides, softwareUI, screenShare, unknown
}

/// A local or validated AI label. It carries no placement or renderer parameters.
public struct ScreenContentHint: Codable, Equatable, Sendable {
    public let range: MediaTimeRange
    public let kind: ScreenContentKind
    public let confidence: Double

    public init(range: MediaTimeRange, kind: ScreenContentKind, confidence: Double) throws {
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw ModelError.invalid("ScreenContentHint.confidence")
        }
        self.range = range
        self.kind = kind
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey { case range, kind, confidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(range: c.decode(MediaTimeRange.self, forKey: .range),
                      kind: c.decode(ScreenContentKind.self, forKey: .kind),
                      confidence: c.decode(Double.self, forKey: .confidence))
    }
}

/// Chooses typed compositions from local evidence; every decision stays in source time.
public struct SmartLayoutEngine: Sendable {
    public init() { }

    public func plan(segments: [EditSegment], asset: MediaAsset, format: OutputFormat,
                     analysis: AnalysisResult, keepDemos: Bool,
                     screenHints: [ScreenContentHint] = []) throws -> [LayoutCue] {
        try analysis.validate(for: asset)
        guard screenHints.allSatisfy({ $0.range.end <= asset.duration &&
            $0.confidence.isFinite && (0...1).contains($0.confidence) }) else {
            throw ModelError.invalid("SmartLayoutEngine hints")
        }
        var output: [LayoutCue] = []
        for segment in segments {
            let segmentOutputStart = output.count
            let range = segment.sourceRange
            guard range.end <= asset.duration else { throw ModelError.invalid("SmartLayoutEngine range") }
            var current: ShotLayout?
            var start = range.start
            var pending: ShotLayout?
            var pendingStart = range.start
            var cursor = range.start.microseconds
            while cursor < range.end.microseconds {
                try Task.checkCancellation()
                let end = min(range.end.microseconds, cursor + min(1_000_000,
                    range.end.microseconds - cursor))
                let time = try MediaTime(microseconds: cursor + (end - cursor) / 2)
                let scores = scores(at: time, format: format, analysis: analysis,
                                    keepDemos: keepDemos, hints: screenHints)
                let best = scores.max { left, right in
                    left.value == right.value ? left.key.rawValue > right.key.rawValue : left.value < right.value
                }!.key
                if current == nil { current = best }
                if best == current || scores[best, default: 0] < scores[current!, default: 0] + 0.12 {
                    pending = nil
                } else if pending != best {
                    pending = best
                    pendingStart = try MediaTime(microseconds: cursor)
                } else if cursor - pendingStart.microseconds >= 2_000_000,
                          cursor - start.microseconds >= 3_000_000 {
                    let switchTime = max(pendingStart, try MediaTime(microseconds: start.microseconds + 3_000_000))
                    if start < switchTime {
                        output.append(LayoutCue(sourceRange: try MediaTimeRange(start: start, end: switchTime),
                                                layout: current!))
                    }
                    current = best
                    start = switchTime
                    pending = nil
                }
                cursor = end
            }
            let final = current ?? .original
            if output.count > segmentOutputStart, let previous = output.last,
               previous.sourceRange.end == start,
               range.end.microseconds - start.microseconds < 3_000_000 {
                output.removeLast()
                output.append(LayoutCue(sourceRange: try MediaTimeRange(start: previous.sourceRange.start,
                    end: range.end), layout: previous.layout))
            } else {
                output.append(LayoutCue(sourceRange: try MediaTimeRange(start: start, end: range.end),
                                        layout: final))
            }
        }
        return output
    }

    private func scores(at time: MediaTime, format: OutputFormat, analysis: AnalysisResult,
                        keepDemos: Bool, hints: [ScreenContentHint]) -> [ShotLayout: Double] {
        var scores: [ShotLayout: Double] = [.original: 0.35]
        let local = analysis.classifications.first { $0.range.start <= time && time < $0.range.end }
        let hint = hints.filter { $0.range.start <= time && time < $0.range.end }
            .max { $0.confidence < $1.confidence }
        let screenSignal = analysis.signals.filter { $0.kind == .screenContent &&
            $0.range.start <= time && time < $0.range.end }
            .map { $0.strength * $0.confidence }.max() ?? 0
        let textSignal = analysis.signals.filter { $0.kind == .textDensity &&
            $0.range.start <= time && time < $0.range.end }
            .map { $0.strength * $0.confidence }.max() ?? 0
        let screenLabel = local.map { [.screenShare, .presentation, .demo].contains($0.kind) } ?? false
        let screen = max(screenSignal, screenLabel ? (local?.confidence ?? 0) * 0.8 : 0,
                         hint?.kind == .unknown ? 0 : (hint?.confidence ?? 0) * 0.8)
        let speakers = analysis.subjectTracks.filter { track in
            track.observations.contains { abs($0.time.microseconds - time.microseconds) <= 1_000_000 }
        }.count
        let vertical = format.height > format.width
        if speakers >= 2 {
            scores[vertical ? .stackedSpeakers : .sideBySide] = 0.78
        } else if speakers == 1 || local?.kind == .talkingHead {
            scores[.speakerFocus] = 0.68
        }
        if screen >= 0.28 {
            scores[.screenFocus] = 0.62 + min(0.16, screen * 0.2)
            if speakers > 0 && textSignal < 0.30 {
                scores[vertical ? .pictureInPicture : .screenAndSpeaker] = 0.73
            }
        }
        let readable = hint.map { [.ideCode, .slides, .softwareUI].contains($0.kind) &&
            $0.confidence >= 0.6 } ?? false
        let demo = screenLabel && local?.kind == .demo || hint?.kind == .browserDemo
        if readable || textSignal >= 0.42 || (keepDemos && demo) {
            scores[.screenFocus] = 0.94
        } else if keepDemos && screenLabel && screen >= 0.32 {
            scores[.screenFocus] = 0.88
        }
        return scores
    }
}
