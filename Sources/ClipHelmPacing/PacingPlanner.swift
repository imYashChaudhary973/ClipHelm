import Foundation
import ClipHelmCore
import ClipHelmAnalysis

public enum RemovalReason: String, Sendable {
    case deadAir, longPause, fillerWord
}

/// A local, reviewable source-time proposal. Only its validated range reaches EditSpec.
public struct ProposedRemoval: Equatable, Sendable {
    public let range: MediaTimeRange
    public let reason: RemovalReason
    public let confidence: Double

    init(range: MediaTimeRange, reason: RemovalReason, confidence: Double) {
        self.range = range
        self.reason = reason
        self.confidence = confidence
    }
}

public struct PacingPlanner: Sendable {
    public init() { }

    public func propose(in range: MediaTimeRange, asset: MediaAsset,
                        configuration: ClipConfiguration, analysis: AnalysisResult,
                        transcript: Transcript?, protectedRanges: [MediaTimeRange] = [],
                        preserveDemos: Bool = false) throws -> [ProposedRemoval] {
        try analysis.validate(for: asset)
        guard range.end <= asset.duration,
              protectedRanges.allSatisfy({ $0.end <= asset.duration }),
              transcript.map({ $0.assetID == asset.id &&
                  $0.words.allSatisfy { $0.range.end <= asset.duration } }) ?? true else {
            throw ModelError.invalid("PacingPlanner inputs")
        }
        let evidence = PacingEvidence(range: range, configuration: configuration,
            analysis: analysis, transcript: transcript, protectedRanges: protectedRanges,
            preserveDemos: preserveDemos)
        let proposed = try DeadAirDetector().propose(evidence) +
            LongPauseTrimmer().propose(evidence) + FillerWordDetector().propose(evidence)
        var accepted: [ProposedRemoval] = []
        var removed: Int64 = 0
        for item in proposed.sorted(by: { $0.range.start < $1.range.start }) {
            try Task.checkCancellation()
            guard evidence.safe(item),
                  accepted.last.map({ item.range.start.microseconds - $0.range.end.microseconds >= 180_000 }) ?? true,
                  removed + item.range.durationMicroseconds <= range.durationMicroseconds - 1_000_000,
                  accepted.count < 9_999 else { continue }
            accepted.append(item)
            removed += item.range.durationMicroseconds
        }
        return accepted
    }
}

private struct PacingEvidence {
    let range: MediaTimeRange
    let configuration: ClipConfiguration
    let pauses: [LocalSignal]
    let audio: [LocalSignal]
    let words: [TranscriptWord]
    let sceneChanges: [LocalSignal]
    let protected: [MediaTimeRange]

    init(range: MediaTimeRange, configuration: ClipConfiguration,
         analysis: AnalysisResult, transcript: Transcript?, protectedRanges: [MediaTimeRange],
         preserveDemos: Bool) {
        self.range = range
        self.configuration = configuration
        pauses = analysis.signals.filter { $0.kind == .pause && $0.confidence >= 0.35 }
            .sorted { $0.range.start < $1.range.start }
        audio = analysis.signals.filter { $0.kind == .audioActivity }
            .sorted { $0.range.start < $1.range.start }
        sceneChanges = analysis.signals.filter { $0.kind == .sceneChange }
        words = (transcript?.words ?? []).filter { $0.range.start < range.end && range.start < $0.range.end }
            .sorted { $0.range.start < $1.range.start }
        if configuration.smartEdit.keepDemos || preserveDemos {
            let labels = analysis.classifications.filter {
                [.demo, .screenShare, .presentation].contains($0.kind) && $0.confidence >= 0.4
            }.map(\.range)
            let screens = analysis.signals.filter {
                ($0.kind == .screenContent || $0.kind == .textDensity) &&
                    $0.strength * $0.confidence >= 0.28
            }.map(\.range)
            protected = protectedRanges + labels + screens
        } else {
            protected = protectedRanges
        }
    }

    func overlap(_ first: MediaTimeRange, _ second: MediaTimeRange) -> Bool {
        first.start < second.end && second.start < first.end
    }

    func neighbors(of pause: MediaTimeRange) -> (TranscriptWord?, TranscriptWord?) {
        (words.last { $0.range.end <= pause.start }, words.first { $0.range.start >= pause.end })
    }

    func hasAudioAnchor(after pause: MediaTimeRange) -> Bool {
        audio.contains { $0.range.start >= pause.end &&
            $0.range.start.microseconds - pause.end.microseconds <= 2_000_000 &&
            $0.strength >= 0.15 && $0.confidence >= 0.4 }
    }

    func hasAudioAnchor(before pause: MediaTimeRange) -> Bool {
        audio.contains { $0.range.end <= pause.start &&
            pause.start.microseconds - $0.range.end.microseconds <= 2_000_000 &&
            $0.strength >= 0.15 && $0.confidence >= 0.4 }
    }

    func safe(_ item: ProposedRemoval) -> Bool {
        guard range.start <= item.range.start, item.range.end <= range.end,
              !protected.contains(where: { overlap($0, item.range) }) else { return false }
        let touched = words.filter { overlap($0.range, item.range) }
        if item.reason == .fillerWord {
            guard touched.count == 1, FillerWordDetector.isFiller(touched[0].text),
                  item.range.start <= touched[0].range.start,
                  touched[0].range.end <= item.range.end else { return false }
        } else {
            guard touched.isEmpty,
                  !audio.contains(where: { overlap($0.range, item.range) &&
                      $0.strength >= 0.18 && $0.confidence >= 0.4 }) else { return false }
        }
        return true
    }
}

private struct DeadAirDetector {
    func propose(_ e: PacingEvidence) throws -> [ProposedRemoval] {
        guard e.configuration.smartEdit.cutDeadAir else { return [] }
        let minimum: Int64
        switch e.configuration.pacingMode {
        case .natural: minimum = 2_000_000
        case .balanced: minimum = 1_200_000
        case .tight: minimum = 800_000
        case .fast: minimum = 500_000
        }
        return try e.pauses.compactMap { signal in
            try Task.checkCancellation()
            guard let pause = try intersect(signal.range, e.range),
                  pause.durationMicroseconds >= minimum else { return nil }
            let leading = pause.start == e.range.start
            let trailing = pause.end == e.range.end
            guard leading || trailing,
                  leading ? (e.words.contains { $0.range.start >= pause.end &&
                      $0.range.start.microseconds - pause.end.microseconds <= 2_000_000 } ||
                      e.hasAudioAnchor(after: pause)) :
                    (e.words.contains { $0.range.end <= pause.start &&
                      pause.start.microseconds - $0.range.end.microseconds <= 2_000_000 } ||
                      e.hasAudioAnchor(before: pause)) else { return nil }
            let shoulder: Int64 = 120_000
            let start = leading ? pause.start : try MediaTime(microseconds: pause.start.microseconds + shoulder)
            let end = leading ? try MediaTime(microseconds: pause.end.microseconds - shoulder) : pause.end
            guard start < end else { return nil }
            return ProposedRemoval(range: try MediaTimeRange(start: start, end: end),
                reason: .deadAir, confidence: signal.confidence)
        }
    }
}

private struct LongPauseTrimmer {
    func propose(_ e: PacingEvidence) throws -> [ProposedRemoval] {
        guard e.configuration.smartEdit.trimLongPauses else { return [] }
        let base: Int64
        switch e.configuration.pacingMode {
        case .natural: base = 950_000
        case .balanced: base = 650_000
        case .tight: base = 420_000
        case .fast: base = 280_000
        }
        return try e.pauses.compactMap { signal in
            try Task.checkCancellation()
            guard let pause = try intersect(signal.range, e.range),
                  pause.start > e.range.start, pause.end < e.range.end else { return nil }
            let (before, after) = e.neighbors(of: pause)
            guard before != nil || e.hasAudioAnchor(before: pause),
                  after != nil || e.hasAudioAnchor(after: pause) else { return nil }
            var retained = base
            if let before, before.text.last.map({ ".!?".contains($0) }) == true {
                retained += 200_000
            }
            if let before, let after, before.speakerID != nil, after.speakerID != nil,
               before.speakerID != after.speakerID { retained += 350_000 }
            if before == nil || after == nil { retained += 350_000 }
            if e.sceneChanges.contains(where: { abs($0.range.start.microseconds - pause.start.microseconds) < 300_000 ||
                abs($0.range.start.microseconds - pause.end.microseconds) < 300_000 }) { retained += 250_000 }
            guard pause.durationMicroseconds >= retained + 180_000 else { return nil }
            let left = max(120_000, retained / 2)
            let right = max(120_000, retained - left)
            let start = try MediaTime(microseconds: pause.start.microseconds + left)
            let end = try MediaTime(microseconds: pause.end.microseconds - right)
            guard start < end else { return nil }
            return ProposedRemoval(range: try MediaTimeRange(start: start, end: end),
                reason: .longPause, confidence: signal.confidence)
        }
    }
}

private struct FillerWordDetector {
    static func isFiller(_ text: String) -> Bool {
        let token = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return ["um", "uh", "erm", "er", "ah", "hmm"].contains(token)
    }

    func propose(_ e: PacingEvidence) throws -> [ProposedRemoval] {
        guard e.configuration.smartEdit.cleanFillers else { return [] }
        let gap: Int64
        switch e.configuration.pacingMode {
        case .natural: gap = 180_000
        case .balanced: gap = 140_000
        case .tight: gap = 110_000
        case .fast: gap = 90_000
        }
        guard e.words.count >= 3 else { return [] }
        var output: [ProposedRemoval] = []
        for index in 1..<(e.words.count - 1) {
            try Task.checkCancellation()
            let previous = e.words[index - 1]
            let word = e.words[index]
            let next = e.words[index + 1]
            guard Self.isFiller(word.text), word.range.durationMicroseconds <= 700_000,
                  word.confidence.map({ $0 >= 0.6 }) ?? true,
                  previous.range.end.microseconds + gap <= word.range.start.microseconds,
                  word.range.end.microseconds + gap <= next.range.start.microseconds,
                  previous.speakerID == nil || next.speakerID == nil || previous.speakerID == next.speakerID,
                  e.range.start <= word.range.start, word.range.end <= e.range.end else { continue }
            let removal = try MediaTimeRange(
                start: MediaTime(microseconds: word.range.start.microseconds - 40_000),
                end: MediaTime(microseconds: word.range.end.microseconds + 40_000))
            output.append(ProposedRemoval(range: removal, reason: .fillerWord,
                confidence: word.confidence ?? 0.75))
        }
        return output
    }
}

private func intersect(_ first: MediaTimeRange, _ second: MediaTimeRange) throws -> MediaTimeRange? {
    let start = max(first.start, second.start)
    let end = min(first.end, second.end)
    return start < end ? try MediaTimeRange(start: start, end: end) : nil
}
