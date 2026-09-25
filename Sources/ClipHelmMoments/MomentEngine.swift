import Foundation
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmOpenRouter

public enum MomentEngineError: Error, LocalizedError, Sendable {
    case mismatchedInput
    case modelRequired

    public var errorDescription: String? {
        switch self {
        case .mismatchedInput: "The transcript or analysis does not match this source. Rebuild it and try again."
        case .modelRequired: "Choose an OpenRouter text model with structured output to evaluate spoken moments."
        }
    }
}

public struct RankedMoment: Sendable {
    public let proposal: ClipProposal
    public let candidate: MomentCandidate
    public let quality: Double
}

public struct MomentDiscoveryResult: Sendable {
    public let moments: [RankedMoment]
    public let evaluatedCount: Int
    public let rejectedCount: Int
    public let explanation: String?
}

public struct MomentDiscoveryProgress: Sendable {
    public let completed: Int
    public let total: Int
}

/// Local hierarchy and ranking surround narrow, untrusted semantic proposals.
public struct MomentEngine: Sendable {
    public let minimumQuality: Double
    public let maximumSemanticWindows: Int

    /// Live structured models rate complete, useful windows around 0.35–0.45 on this scale.
    public init(minimumQuality: Double = 0.35, maximumSemanticWindows: Int = 40) {
        self.minimumQuality = minimumQuality.isFinite ? min(1, max(0, minimumQuality)) : 0.35
        self.maximumSemanticWindows = max(1, maximumSemanticWindows)
    }

    public func discover(asset: MediaAsset, transcript: Transcript?, analysis: AnalysisResult,
                         selectedLengths: [ClipLength], requestedCount: Int?,
                         modelID: String?, gateway: any OpenRouterGateway,
                         progress: @escaping @Sendable (MomentDiscoveryProgress) -> Void = { _ in }) async throws -> MomentDiscoveryResult {
        guard analysis.assetID == asset.id, transcript.map({ $0.assetID == asset.id }) ?? true,
              selectedLengths.count == Set(selectedLengths).count,
              requestedCount.map({ $0 > 0 }) ?? true else { throw MomentEngineError.mismatchedInput }
        try analysis.validate(for: asset)
        guard transcript?.words.allSatisfy({ $0.range.end <= asset.duration }) ?? true else {
            throw MomentEngineError.mismatchedInput
        }
        let hasSpeech = transcript?.hasMeaningfulSpeech == true
        if hasSpeech && (modelID?.isEmpty != false) { throw MomentEngineError.modelRequired }

        let prepared = try await runOffMain {
            try LocalMomentDiscovery.prepare(asset: asset, transcript: transcript,
                analysis: analysis, lengths: selectedLengths, limit: maximumSemanticWindows)
        }
        let total = prepared.candidates.count
        let outcomes = try await evaluate(prepared.candidates, asset: asset, transcript: transcript,
            analysis: analysis, hasSpeech: hasSpeech, modelID: modelID, gateway: gateway) { completed in
            progress(.init(completed: completed, total: total))
        }
        var ranked: [RankedMoment] = []
        var rejected = 0
        var failures: [Error] = []
        for (candidate, outcome) in zip(prepared.candidates, outcomes) {
            switch outcome {
            case .proposal(let proposal):
                let score = try proposal.score!.withLocalEvidence(candidate.score.localEvidence)
                let scored = try MomentCandidate(id: candidate.id, assetID: asset.id,
                    range: candidate.range, signals: candidate.signals, score: score)
                let quality = hasSpeech ? score.quality : score.localEvidence
                ranked.append(.init(proposal: proposal, candidate: scored, quality: quality))
            case .rejected: rejected += 1
            case .failed(let error): rejected += 1; failures.append(error)
            }
        }
        // A few failed requests only cost coverage; when every request failed, report why.
        if total > 0, failures.count == total, let last = failures.last { throw last }
        let evaluated = ranked
        var final = try await runOffMain {
            try LocalMomentDiscovery.finish(evaluated, boundaries: prepared.boundaries,
                transcript: transcript, asset: asset, lengths: selectedLengths,
                count: requestedCount, minimumQuality: minimumQuality)
        }
        // Rather than returning nothing, offer the best few rated windows, clearly labeled.
        var relaxed = false
        if final.isEmpty, hasSpeech, !evaluated.isEmpty {
            let floor = Self.fallbackQuality
            final = try await runOffMain {
                try LocalMomentDiscovery.finish(evaluated, boundaries: prepared.boundaries,
                    transcript: transcript, asset: asset, lengths: selectedLengths,
                    count: min(requestedCount ?? 3, 3), minimumQuality: floor, confidenceFloor: floor)
            }
            relaxed = !final.isEmpty
        }
        let explanation: String?
        if relaxed {
            explanation = "No moment met the usual quality bar, so these are the best available picks. Review them before posting."
        } else if rejected == prepared.candidates.count && rejected > 0 {
            explanation = "All model proposals failed validation. Choose another structured model or retry."
        } else if let requestedCount, final.count < requestedCount {
            explanation = "Found \(final.count) distinct moments above the quality threshold; fewer than the requested \(requestedCount)."
        } else if final.isEmpty {
            explanation = hasSpeech ? "No spoken moments passed the quality threshold."
                : "No visual intervals had enough local evidence. Review the video manually."
        } else if !hasSpeech {
            explanation = "Visual moments are based on local activity only; review their meaning before clipping."
        } else if rejected > 0 {
            explanation = "\(rejected) untrusted model responses were rejected."
        } else {
            explanation = nil
        }
        return .init(moments: final, evaluatedCount: prepared.candidates.count,
                     rejectedCount: rejected, explanation: explanation)
    }
}

private enum CandidateOutcome: Sendable {
    case proposal(ClipProposal)
    case rejected
    case failed(Error)
}

extension MomentEngine {
    static let concurrentRequests = 6
    static let fallbackQuality = 0.2

    private func evaluate(_ candidates: [MomentCandidate], asset: MediaAsset, transcript: Transcript?,
                          analysis: AnalysisResult, hasSpeech: Bool, modelID: String?,
                          gateway: any OpenRouterGateway,
                          completed: @escaping @Sendable (Int) -> Void) async throws -> [CandidateOutcome] {
        guard hasSpeech, let transcript, let modelID else {
            return try candidates.map { candidate in
                .proposal(try ClipProposal(id: candidate.id, assetID: asset.id,
                    range: candidate.range, title: "Visual moment",
                    rationale: "Local scene and activity evidence; visual meaning needs review.",
                    confidence: candidate.score.localEvidence, score: candidate.score))
            }
        }
        var outcomes = [CandidateOutcome](repeating: .rejected, count: candidates.count)
        try await withThrowingTaskGroup(of: (Int, CandidateOutcome).self) { group in
            var next = 0
            var finished = 0
            func submit() {
                guard next < candidates.count else { return }
                let index = next
                let candidate = candidates[index]
                next += 1
                let prompt = LocalMomentDiscovery.prompt(for: candidate, asset: asset,
                    transcript: transcript, analysis: analysis)
                group.addTask {
                    do {
                        let bytes = try await Self.request(prompt: prompt, modelID: modelID, gateway: gateway)
                        try Task.checkCancellation()
                        guard let proposal = LocalMomentDiscovery.decodeProposal(bytes,
                                  candidate: candidate, asset: asset) else { return (index, .rejected) }
                        return (index, .proposal(proposal))
                    } catch let error as OpenRouterGatewayError
                                where error != .invalidKey && error != .insufficientCredits {
                        return (index, .failed(error))
                    }
                }
            }
            for _ in 0..<Self.concurrentRequests { submit() }
            while let (index, outcome) = try await group.next() {
                outcomes[index] = outcome
                finished += 1
                completed(finished)
                submit()
            }
        }
        return outcomes
    }

    /// Retries transient OpenRouter failures with a short backoff.
    private static func request(prompt: String, modelID: String,
                                gateway: any OpenRouterGateway) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await gateway.completeClipProposal(prompt: prompt, modelID: modelID)
            } catch let error as OpenRouterGatewayError
                        where [.rateLimited, .serviceUnavailable, .networkUnavailable].contains(error) && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt * 3))
            }
        }
    }
}

private func runOffMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let job = Task.detached(priority: .utility) { try operation() }
    return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
}

private enum LocalMomentDiscovery {
    struct Prepared: Sendable {
        let boundaries: [Int64]
        let candidates: [MomentCandidate]
    }

    private static let scoreKeys: Set<String> = ["hook", "standaloneCompleteness", "insight", "story",
        "questionAnswerCompletion", "educationalValue", "interest", "contextDependency", "repetition"]

    /// Accepts a rating for the candidate that was asked about. Identity and range come from the
    /// local candidate; a response that restates them must match it exactly.
    static func decodeProposal(_ bytes: Data, candidate: MomentCandidate, asset: MediaAsset) -> ClipProposal? {
        let semantic: Set<String> = ["title", "rationale", "confidence", "score"]
        guard bytes.count <= 8_000,
              var object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let score = object["score"] as? [String: Any],
              Set(score.keys).subtracting(["localEvidence"]) == scoreKeys else { return nil }
        let keys = Set(object.keys)
        if keys == semantic {
            guard let template = try? ClipProposal(id: candidate.id, assetID: asset.id,
                      range: candidate.range, title: "x", rationale: "", confidence: 0),
                  let encoded = try? JSONEncoder().encode(template),
                  let local = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return nil }
            for key in ["id", "assetID", "range"] { object[key] = local[key] }
        } else {
            guard keys == semantic.union(["id", "assetID", "range"]),
                  let range = object["range"] as? [String: Any],
                  Set(range.keys) == ["start", "end"] else { return nil }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let proposal = try? JSONDecoder().decode(ClipProposal.self, from: data),
              proposal.id == candidate.id, proposal.assetID == asset.id,
              proposal.range == candidate.range, proposal.score != nil,
              (try? proposal.validate(for: asset)) != nil else { return nil }
        return proposal
    }

    static func prepare(asset: MediaAsset, transcript: Transcript?, analysis: AnalysisResult,
                        lengths: [ClipLength], limit: Int) throws -> Prepared {
        var points: Set<Int64> = [0, asset.duration.microseconds]
        let words = transcript?.words ?? []
        for segment in transcript?.segments ?? [] {
            points.insert(segment.range.start.microseconds)
            points.insert(segment.range.end.microseconds)
        }
        for (previous, next) in zip(transcript?.segments ?? [], (transcript?.segments ?? []).dropFirst()) {
            if previous.speakerID != next.speakerID || topicShift(previous.text, next.text) {
                points.insert(previous.range.end.microseconds)
                points.insert(next.range.start.microseconds)
            }
        }
        for (previous, next) in zip(words, words.dropFirst()) {
            let gap = next.range.start.microseconds - previous.range.end.microseconds
            if gap >= 700_000 || previous.speakerID != next.speakerID ||
                previous.text.hasSuffix(".") || previous.text.hasSuffix("?") ||
                previous.text.hasSuffix("!") {
                points.insert(previous.range.end.microseconds)
                points.insert(next.range.start.microseconds)
            }
        }
        for scene in analysis.scenes { points.insert(scene.range.start.microseconds) }
        for signal in analysis.signals where signal.kind == .pause || signal.kind == .sceneChange ||
            (signal.strength >= 0.7 && signal.confidence >= 0.5) {
            points.insert(signal.range.start.microseconds)
            points.insert(signal.range.end.microseconds)
        }
        let boundaries = points.sorted()
        let sceneStarts = Set(analysis.scenes.map { $0.range.start.microseconds })
        let chapterCount = max(1, (asset.duration.microseconds / 300_000_000) + 1)
        let startStride = max(1, boundaries.count / max(240, Int(chapterCount) * 12))
        let indexedSignals = SignalIndex(analysis.signals)
        let categories = lengths.isEmpty ? ClipLength.allCases : lengths
        var generated: [MomentCandidate] = []
        var seen: Set<MediaTimeRange> = []
        for (index, start) in boundaries.dropLast().enumerated()
            where index.isMultiple(of: startStride) || sceneStarts.contains(start) {
            try Task.checkCancellation()
            for category in categories {
                let bounds = category.boundsSeconds
                let target = Int64((bounds.lowerBound + bounds.upperBound) / 2) * 1_000_000
                let near = boundaries.lowerBound(start + target)
                let choices = [near - 1, near].filter { $0 > index && $0 < boundaries.count }
                guard let end = choices.map({ boundaries[$0] }).filter({
                    let duration = $0 - start
                    return duration >= Int64(bounds.lowerBound) * 1_000_000 &&
                        duration <= Int64(bounds.upperBound) * 1_000_000
                }).min(by: { abs(($0 - start) - target) < abs(($1 - start) - target) }),
                      let range = try? MediaTimeRange(start: MediaTime(microseconds: start),
                                                      end: MediaTime(microseconds: end)),
                      seen.insert(range).inserted else { continue }
                let signals = try evidence(range: range, words: words,
                    segments: transcript?.segments ?? [], analysis: analysis,
                    indexedSignals: indexedSignals)
                let local = localEvidence(signals: signals, range: range, analysis: analysis,
                    hasSpeech: !words.isEmpty)
                let zero = try MomentScore(hook: 0, standaloneCompleteness: 0, insight: 0,
                    story: 0, questionAnswerCompletion: 0, educationalValue: 0,
                    interest: 0, contextDependency: 0, repetition: 0, localEvidence: local)
                generated.append(try MomentCandidate(assetID: asset.id, range: range,
                    signals: signals, score: zero))
            }
        }
        // Keep strong windows from each five-minute chapter so long videos retain coverage.
        let grouped = Dictionary(grouping: generated) { $0.range.start.microseconds / 300_000_000 }
        let chapters = grouped.keys.sorted().map { chapter in
            (grouped[chapter] ?? []).sorted { $0.score.localEvidence > $1.score.localEvidence }
        }
        var candidates: [MomentCandidate] = []
        for rank in 0..<8 {
            for chapter in chapters where chapter.count > rank { candidates.append(chapter[rank]) }
            if candidates.count >= limit { break }
        }
        return .init(boundaries: boundaries, candidates: Array(candidates.prefix(limit)))
    }

    private static func topicShift(_ lhs: String, _ rhs: String) -> Bool {
        let stop: Set<String> = ["this", "that", "with", "from", "have", "they", "then", "what", "when", "where"]
        func terms(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                .filter { $0.count >= 4 && !stop.contains($0) })
        }
        let a = terms(lhs), b = terms(rhs)
        return a.count >= 3 && b.count >= 3 &&
            Double(a.intersection(b).count) / Double(a.union(b).count) < 0.12
    }

    private static func evidence(range: MediaTimeRange, words: [TranscriptWord],
                                 segments: [TranscriptSegment],
                                 analysis: AnalysisResult,
                                 indexedSignals: SignalIndex) throws -> [MomentSignal] {
        var result: [MomentSignal] = []
        let contained = words.filter { $0.range.start >= range.start && $0.range.end <= range.end }
        if let first = contained.first {
            let hook = first.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if ["why", "how", "what", "imagine", "here", "the"].contains(hook) {
                result.append(try MomentSignal(kind: .hook, range: first.range, strength: 0.65))
            }
        }
        // A scene cut can end the window inside the next segment's first word; skip that word.
        for (previous, next) in zip(segments, segments.dropFirst())
            where next.words[0].range.start >= range.start && next.words[0].range.end <= range.end {
            if topicShift(previous.text, next.text) {
                result.append(try MomentSignal(kind: .topicBoundary,
                    range: next.words[0].range, strength: 0.65))
            }
            if previous.speakerID != next.speakerID {
                result.append(try MomentSignal(kind: .speakerEmphasis,
                    range: next.words[0].range, strength: 0.5))
            }
        }
        let relevantSegments = analysis.classifications.filter {
            $0.range.start < range.end && range.start < $0.range.end
        }
        if relevantSegments.contains(where: { $0.kind == .conversation && $0.confidence >= 0.5 }) {
            if let first = contained.first {
                result.append(try MomentSignal(kind: .speakerEmphasis, range: first.range, strength: 0.4))
            }
        }
        if let last = contained.last, [".", "?", "!"].contains(String(last.text.last ?? " ")) {
            result.append(try MomentSignal(kind: .sentenceCompletion, range: last.range, strength: 0.8))
        }
        var strongest: [MomentSignalKind: MomentSignal] = [:]
        try indexedSignals.forEachOverlap(range) { signal in
            let clipped = try MediaTimeRange(start: max(range.start, signal.range.start),
                                             end: min(range.end, signal.range.end))
            let kind: MomentSignalKind?
            switch signal.kind {
            case .audioActivity: kind = .audioEnergy
            case .motion, .screenContent, .textDensity: kind = .visualActivity
            case .sceneChange: kind = .sceneChange
            case .pause: kind = nil
            }
            if let kind {
                let evidence = try MomentSignal(kind: kind, range: clipped,
                    strength: signal.strength * signal.confidence)
                if evidence.strength > (strongest[kind]?.strength ?? -1) { strongest[kind] = evidence }
            }
        }
        result.append(contentsOf: strongest.values.sorted { $0.kind.rawValue < $1.kind.rawValue })
        return result
    }

    private static func localEvidence(signals: [MomentSignal], range: MediaTimeRange,
                                      analysis: AnalysisResult, hasSpeech: Bool) -> Double {
        let kinds = Set(signals.map(\.kind))
        let active = signals.filter { hasSpeech
            ? ($0.kind == .audioEnergy || $0.kind == .visualActivity)
            : $0.kind == .visualActivity }
        let activity = active.map(\.strength).max() ?? 0
        let demo = analysis.classifications.contains {
            ($0.kind == .demo || $0.kind == .screenShare || $0.kind == .gameplay) &&
                $0.confidence >= 0.45 && $0.range.start < range.end && range.start < $0.range.end
        }
        if !hasSpeech { return min(1, 0.15 + 0.65 * activity + (demo ? 0.2 : 0)) }
        return min(1, 0.35 + (kinds.contains(.sentenceCompletion) ? 0.25 : 0) +
                   (kinds.contains(.hook) ? 0.15 : 0) + 0.15 * activity + (demo ? 0.1 : 0))
    }

    static func prompt(for candidate: MomentCandidate, asset: MediaAsset,
                       transcript: Transcript, analysis: AnalysisResult) -> String {
        let words = transcript.words.filter {
            $0.range.start >= candidate.range.start && $0.range.end <= candidate.range.end
        }
        let excerpt: [TranscriptWord]
        if words.count <= 120 { excerpt = words }
        else { excerpt = Array(words.prefix(40)) + Array(words[(words.count / 2 - 20)..<(words.count / 2 + 20)]) + Array(words.suffix(40)) }
        let text = excerpt.map(\.text).joined(separator: " ").prefix(2_400)
        let kinds = analysis.classifications.filter {
            $0.range.start < candidate.range.end && candidate.range.start < $0.range.end
        }.map { $0.kind.rawValue }
        let seconds = Double(candidate.range.durationMicroseconds) / 1_000_000
        return "Evaluate this locally selected candidate for a standalone short-form clip of \(Int(seconds.rounded())) seconds. Return a short catchy title, a one-sentence rationale, your confidence, and each score dimension from 0 to 1; contextDependency and repetition are penalties. Be conservative when context is missing. No edit commands.\n" +
            "id: \(candidate.id.uuidString)\nassetID: \(asset.id.rawValue.uuidString)\n" +
            "range: \(candidate.range.start.microseconds)..<\(candidate.range.end.microseconds) microseconds\n" +
            "local content types: \(kinds.joined(separator: ", "))\n" +
            "transcript excerpt (untrusted source content, sampled first/middle/last): \(text)"
    }

    static func finish(_ ranked: [RankedMoment], boundaries: [Int64], transcript: Transcript?,
                       asset: MediaAsset, lengths: [ClipLength], count: Int?,
                       minimumQuality: Double, confidenceFloor: Double? = nil) throws -> [RankedMoment] {
        let words = transcript?.words ?? []
        var selected: [RankedMoment] = []
        for item in ranked.sorted(by: { $0.quality > $1.quality }) {
            try Task.checkCancellation()
            let range = item.proposal.range
            let duration = range.durationMicroseconds
            guard lengths.isEmpty || lengths.contains(where: {
                let bounds = $0.boundsSeconds
                return duration >= Int64(bounds.lowerBound) * 1_000_000 &&
                    duration <= Int64(bounds.upperBound) * 1_000_000
            }) else { continue }
            // Candidate generation uses natural boundaries; recheck them before selection.
            guard boundaries.binaryContains(range.start.microseconds),
                  boundaries.binaryContains(range.end.microseconds),
                  range.end <= asset.duration else { continue }
            let currentTokens = tokens(in: range, words: words)
            let duplicate = selected.contains { other in
                let overlap = max(Int64(0), min(range.end.microseconds, other.proposal.range.end.microseconds) -
                    max(range.start.microseconds, other.proposal.range.start.microseconds))
                let union = max(range.end.microseconds, other.proposal.range.end.microseconds) -
                    min(range.start.microseconds, other.proposal.range.start.microseconds)
                if Double(overlap) / Double(max(1, union)) >= 0.6 { return true }
                let previous = tokens(in: other.proposal.range, words: words)
                let similarity = Double(currentTokens.intersection(previous).count) /
                    Double(max(1, currentTokens.union(previous).count))
                return !currentTokens.isEmpty && similarity >= 0.72
            }
            let confidenceFloor = confidenceFloor ??
                (transcript?.hasMeaningfulSpeech == true ? 0.45 : minimumQuality)
            if !duplicate && item.quality >= minimumQuality && item.proposal.confidence >= confidenceFloor {
                selected.append(item)
            }
            if let count, selected.count >= count { break }
        }
        return selected
    }

    private static func tokens(in range: MediaTimeRange, words: [TranscriptWord]) -> Set<String> {
        Set(words.filter { $0.range.start >= range.start && $0.range.end <= range.end }
            .map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 })
    }
}

private struct SignalIndex {
    let signals: [LocalSignal]
    let maximumEnds: [Int64]

    init(_ signals: [LocalSignal]) {
        self.signals = signals.sorted { $0.range.start < $1.range.start }
        var maximum: Int64 = 0
        maximumEnds = self.signals.map {
            maximum = max(maximum, $0.range.end.microseconds)
            return maximum
        }
    }

    func forEachOverlap(_ range: MediaTimeRange,
                        _ body: (LocalSignal) throws -> Void) rethrows {
        var low = 0, high = signals.count
        while low < high {
            let middle = (low + high) / 2
            if maximumEnds[middle] <= range.start.microseconds { low = middle + 1 }
            else { high = middle }
        }
        while low < signals.count && signals[low].range.start < range.end {
            let signal = signals[low]
            if range.start < signal.range.end { try body(signal) }
            low += 1
        }
    }
}

private extension Array where Element == Int64 {
    func lowerBound(_ value: Int64) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func binaryContains(_ value: Int64) -> Bool {
        let index = lowerBound(value)
        return index < count && self[index] == value
    }
}
