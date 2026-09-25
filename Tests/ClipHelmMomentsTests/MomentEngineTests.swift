import Foundation
import Darwin
import XCTest
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmOpenRouter
@testable import ClipHelmMoments

private actor ProposalGateway: OpenRouterGateway {
    var prompts: [String] = []
    var corrupt = false
    var addCommand = false
    var forceWeak = false
    var cancelOnRequest = false

    func testConnection() async throws {}
    func fetchCatalog(_ filter: CatalogFilter) async throws -> Data { Data() }
    func transcribeAudio(_ audio: Data, modelID: String) async throws -> Data { Data() }

    func completeClipProposal(prompt: String, modelID: String) async throws -> Data {
        prompts.append(prompt)
        if cancelOnRequest { withUnsafeCurrentTask { $0?.cancel() } }
        let lines = prompt.split(separator: "\n")
        let id = UUID(uuidString: String(lines.first { $0.hasPrefix("id: ") }!.dropFirst(4)))!
        let assetID = AssetID(UUID(uuidString: String(lines.first { $0.hasPrefix("assetID: ") }!.dropFirst(9)))!)
        let rangeText = lines.first { $0.hasPrefix("range: ") }!.dropFirst(7).split(separator: " ")[0]
        let pieces = rangeText.components(separatedBy: "..<")
        let range = try MediaTimeRange(start: MediaTime(microseconds: Int64(pieces[0])!),
                                       end: MediaTime(microseconds: Int64(pieces[1])!))
        let excerpt = prompt.lowercased()
        let weak = forceWeak || excerpt.contains("contextneeded")
        let score = try MomentScore(hook: weak ? 0.1 : 0.9,
            standaloneCompleteness: weak ? 0.1 : 0.9,
            insight: weak ? 0.1 : 0.85, story: weak ? 0.1 : 0.8,
            questionAnswerCompletion: weak ? 0.1 : 0.85,
            educationalValue: weak ? 0.1 : 0.85, interest: weak ? 0.1 : 0.9,
            contextDependency: weak ? 0.9 : 0.05, repetition: 0.05)
        let proposal = try ClipProposal(id: corrupt ? UUID() : id, assetID: assetID,
            range: range, title: "Useful moment", rationale: "Complete and useful.",
            confidence: 0.9, score: score)
        let data = try JSONEncoder().encode(proposal)
        if addCommand {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["ffmpegCommand"] = "-i /private/source.mov /tmp/output.mov"
            return try JSONSerialization.data(withJSONObject: object)
        }
        return data
    }

    func setCorrupt(_ value: Bool) { corrupt = value }
    func setAddCommand(_ value: Bool) { addCommand = value }
    func setForceWeak(_ value: Bool) { forceWeak = value }
    func setCancelOnRequest(_ value: Bool) { cancelOnRequest = value }
}

/// Returns the short rating form, failing chosen requests to exercise partial-failure handling.
private actor RatingGateway: OpenRouterGateway {
    var calls = 0
    var failure: OpenRouterGatewayError?
    var failEvery = 0
    var level: Double

    init(failure: OpenRouterGatewayError? = nil, failEvery: Int = 0, level: Double = 0.9) {
        self.failure = failure
        self.failEvery = failEvery
        self.level = level
    }

    func testConnection() async throws {}
    func fetchCatalog(_ filter: CatalogFilter) async throws -> Data { Data() }
    func transcribeAudio(_ audio: Data, modelID: String) async throws -> Data { Data() }

    func completeClipProposal(prompt: String, modelID: String) async throws -> Data {
        calls += 1
        if let failure, failEvery == 0 || calls.isMultiple(of: failEvery) { throw failure }
        var scores = Dictionary(uniqueKeysWithValues: ["hook", "standaloneCompleteness", "insight", "story",
            "questionAnswerCompletion", "educationalValue", "interest"].map { ($0, level) })
        scores["contextDependency"] = 0.05
        scores["repetition"] = 0.05
        return try JSONSerialization.data(withJSONObject: [
            "title": "A strong moment", "rationale": "Complete and useful.",
            "confidence": level, "score": scores,
        ])
    }
}

final class MomentEngineTests: XCTestCase {
    func testShortRatingFormUsesLocalIdentityAndRange() async throws {
        let input = try fixture("lecture")
        let result = try await MomentEngine(maximumSemanticWindows: 8).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: 3,
            modelID: "fixture/model", gateway: RatingGateway())
        XCTAssertFalse(result.moments.isEmpty)
        XCTAssertEqual(result.rejectedCount, 0)
        XCTAssertTrue(result.moments.allSatisfy {
            $0.proposal.id == $0.candidate.id && $0.proposal.range == $0.candidate.range &&
                $0.proposal.assetID == input.asset.id && $0.proposal.title == "A strong moment"
        })
    }

    func testWordsStraddlingSceneCutsDoNotInvalidateCandidates() async throws {
        let input = try fixture("lecture")
        // A window from 40 s to the 60 s scene cut ends inside the first word of the
        // next speaker's segment, which starts at 59.5 s.
        let layout: [(start: Int64, speaker: String)] = [(10_000_000, "A"), (40_000_000, "B"), (59_500_000, "A")]
        let segments = try layout.map { item -> TranscriptSegment in
            let words = try (0..<15).map { index -> TranscriptWord in
                let start = item.start + Int64(index) * 1_000_000
                return try TranscriptWord(text: index == 14 ? "done." : "word",
                    range: MediaTimeRange(start: MediaTime(microseconds: start),
                                          end: MediaTime(microseconds: start + 1_000_000)),
                    speakerID: item.speaker)
            }
            return try TranscriptSegment(words: words)
        }
        let transcript = try Transcript(assetID: input.asset.id, segments: segments)
        let result = try await MomentEngine(maximumSemanticWindows: 12).discover(
            asset: input.asset, transcript: transcript, analysis: input.analysis,
            selectedLengths: [.seconds10to30], requestedCount: nil,
            modelID: "fixture/model", gateway: RatingGateway())
        XCTAssertGreaterThan(result.evaluatedCount, 0)
        XCTAssertTrue(result.moments.allSatisfy { moment in
            moment.candidate.signals.allSatisfy { moment.candidate.range.start <= $0.range.start &&
                $0.range.end <= moment.candidate.range.end }
        })
    }

    func testMiddlingScoresFallBackToLabeledBestAvailablePicks() async throws {
        let input = try fixture("lecture")
        let result = try await MomentEngine(maximumSemanticWindows: 8).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: nil,
            modelID: "fixture/model", gateway: RatingGateway(level: 0.3))
        XCTAssertFalse(result.moments.isEmpty)
        XCTAssertLessThanOrEqual(result.moments.count, 3)
        XCTAssertTrue((result.explanation ?? "").contains("best available"))
    }

    func testSelectedMomentsNeverShareHalfOfTheShorterClip() async throws {
        let input = try fixture("podcast", long: true)
        let result = try await MomentEngine(maximumSemanticWindows: 40).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: nil,
            modelID: "fixture/model", gateway: RatingGateway())
        XCTAssertGreaterThan(result.moments.count, 1)
        for (index, first) in result.moments.enumerated() {
            for second in result.moments.dropFirst(index + 1) {
                let a = first.proposal.range, b = second.proposal.range
                let overlap = max(0, min(a.end.microseconds, b.end.microseconds) - max(a.start.microseconds, b.start.microseconds))
                XCTAssertLessThan(Double(overlap) / Double(min(a.durationMicroseconds, b.durationMicroseconds)), 0.5)
            }
        }
    }

    func testSomeFailedRequestsStillProduceMoments() async throws {
        let input = try fixture("podcast")
        let gateway = RatingGateway(failure: .invalidResponse, failEvery: 3)
        let result = try await MomentEngine(maximumSemanticWindows: 9).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: nil,
            modelID: "fixture/model", gateway: gateway)
        XCTAssertFalse(result.moments.isEmpty)
        XCTAssertGreaterThan(result.rejectedCount, 0)
    }

    func testEveryRequestFailingReportsTheCauseAndKeyErrorsStopImmediately() async throws {
        let input = try fixture("podcast")
        for (failure, expectedCalls) in [(OpenRouterGatewayError.modelUnsupported, nil as Int?),
                                          (.invalidKey, MomentEngine.concurrentRequests)] {
            let gateway = RatingGateway(failure: failure)
            do {
                _ = try await MomentEngine(maximumSemanticWindows: 12).discover(
                    asset: input.asset, transcript: input.transcript, analysis: input.analysis,
                    selectedLengths: [.seconds30to60], requestedCount: nil,
                    modelID: "fixture/model", gateway: gateway)
                XCTFail("Expected \(failure)")
            } catch let error as OpenRouterGatewayError {
                XCTAssertEqual(error, failure)
            }
            if let expectedCalls {
                let calls = await gateway.calls
                XCTAssertLessThanOrEqual(calls, expectedCalls)
            }
        }
    }

    private struct Fixture {
        let asset: MediaAsset
        let transcript: Transcript?
        let analysis: AnalysisResult
    }

    private func fixture(_ kind: String, long: Bool = false,
                         durationOverride: Int? = nil, width: Int = 1920,
                         height: Int = 1080, wordsPerBlock: Int = 20) throws -> Fixture {
        let duration = durationOverride ?? (long ? 1_200 : 120)
        let asset = try MediaAsset(id: AssetID(), displayName: "\(kind).mov",
            duration: MediaTime(microseconds: Int64(duration) * 1_000_000), width: width, height: height)
        let scenes = try stride(from: 0, to: duration, by: 30).map { start in
            Scene(assetID: asset.id, range: try MediaTimeRange(
                start: MediaTime(microseconds: Int64(start) * 1_000_000),
                end: MediaTime(microseconds: Int64(min(duration, start + 30)) * 1_000_000)))
        }
        let all = try MediaTimeRange(start: MediaTime(microseconds: 0),
                                     end: MediaTime(microseconds: Int64(duration) * 1_000_000))
        let visual = ["silentDemo", "screenRecording", "codingTutorial", "gameplay",
                      "mixedSpeakerScreen"].contains(kind)
        let signals = try [LocalSignal(kind: visual ? .motion : .audioActivity, range: all,
                                       strength: 0.95, confidence: 0.95)]
        let content: ContentKind = switch kind {
        case "podcast", "interview": .conversation
        case "talkingHead": .talkingHead
        case "presentation": .presentation
        case "gameplay": .gameplay
        case "mixedSpeakerScreen": .screenShare
        case "codingTutorial", "screenRecording", "silentDemo": .demo
        default: .presentation
        }
        let analysis = try AnalysisResult(asset: asset, scenes: scenes, signals: signals,
            detections: [], subjectTracks: [],
            classifications: [ContentClassification(range: all, kind: content, confidence: 0.8)])
        if kind == "silentDemo" { return .init(asset: asset, transcript: nil, analysis: analysis) }
        let phrases: [String] = switch kind {
        case "podcast": ["Why the launch failed because timing mattered.", "The customer story explains the decision.", "Here is the lesson teams can use.", "That completes the surprising story."]
        case "interview": ["What was the hardest question you faced?", "The answer started with a small experiment.", "Here is what changed after that test.", "The result taught us a clear lesson."]
        case "codingTutorial": ["How this function handles an empty array.", "First we inspect the failing example.", "Then the code returns a safe default.", "The passing test shows the fix works."]
        case "lecture": ["Why the theorem follows from this definition.", "Consider the first useful example carefully.", "This derivation gives the central insight.", "The conclusion completes the proof."]
        case "screenRecording": ["How to set up the dashboard step by step.", "Click the filter and watch the result.", "The display now shows the selected rows.", "This completes the useful demo."]
        case "talkingHead": ["Why this tip changed my workflow.", "Here is the mistake I made.", "The new approach fixed that issue.", "The result is easy to repeat."]
        case "presentation": ["What this chart reveals about growth.", "The first number gives us context.", "The comparison shows the important change.", "That is the conclusion of this slide."]
        case "gameplay": ["Why this strategy works in this encounter.", "The first move creates space.", "The next choice protects the objective.", "The round ends with a clear win."]
        case "mixedSpeakerScreen": ["How this speaker uses the screen demo.", "First the code shows the failing case.", "Then the speaker explains the correction.", "The visible result completes the explanation."]
        case "mixed": ["contextneeded this depends on earlier missing details.", "contextneeded as I said before this is unclear.", "Why the solution follows from a concrete example.", "The completed example explains the useful result."]
        default: ["Why this explanation stands alone."]
        }
        var segments: [TranscriptSegment] = []
        for block in 0..<(duration / 30) {
            let phrase = phrases[block % phrases.count].split(separator: " ").map(String.init)
            var words: [TranscriptWord] = []
            for index in 0..<wordsPerBlock {
                let start = Int64(block * 30) * 1_000_000 +
                    (wordsPerBlock == 20 ? Int64(index) * 1_000_000 : Int64(index) * 400_000)
                let text = phrase[index % phrase.count]
                let range = try MediaTimeRange(
                    start: MediaTime(microseconds: start),
                    end: MediaTime(microseconds: start + (wordsPerBlock == 20 ? 1_000_000 : 300_000)))
                words.append(try TranscriptWord(text: text, range: range,
                    speakerID: kind == "interview" ? (block.isMultiple(of: 2) ? "A" : "B") : "A"))
            }
            segments.append(try TranscriptSegment(words: words))
        }
        return .init(asset: asset,
            transcript: try Transcript(assetID: asset.id, segments: segments), analysis: analysis)
    }

    func testSpeechFixturesUseBoundedSemanticWindowsAndReturnStrongMoments() async throws {
        for kind in ["podcast", "interview", "talkingHead", "codingTutorial", "screenRecording",
                     "presentation", "lecture", "gameplay", "mixedSpeakerScreen"] {
            let input = try fixture(kind)
            let gateway = ProposalGateway()
            let result = try await MomentEngine(maximumSemanticWindows: 12).discover(
                asset: input.asset, transcript: input.transcript, analysis: input.analysis,
                selectedLengths: [.seconds30to60], requestedCount: 3,
                modelID: "fixture/model", gateway: gateway)
            XCTAssertFalse(result.moments.isEmpty, kind)
            XCTAssertLessThanOrEqual(result.moments.count, 3)
            XCTAssertTrue(result.moments.allSatisfy { $0.proposal.range == $0.candidate.range })
            let prompts = await gateway.prompts
            XCTAssertEqual(prompts.count, result.evaluatedCount)
            XCTAssertTrue(prompts.allSatisfy { $0.utf8.count < 4_000 })
            XCTAssertTrue(prompts.allSatisfy { $0.contains("transcript excerpt") })
        }
    }

    func testLongTimelineBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["CLIPHELM_RUN_LONG_BENCHMARKS"] == "1" else {
            throw XCTSkip("Run explicitly for the 30-minute to 4-hour synthetic timeline profile")
        }
        for minutes in [30, 60, 120, 240] {
            for (width, height) in [(1920, 1080), (3840, 2160)] {
                let input = try fixture("podcast", durationOverride: minutes * 60,
                                        width: width, height: height, wordsPerBlock: 60)
                let gateway = ProposalGateway()
                var before = rusage()
                var after = rusage()
                getrusage(RUSAGE_SELF, &before)
                let started = Date()
                let result = try await MomentEngine(maximumSemanticWindows: 24).discover(
                    asset: input.asset, transcript: input.transcript, analysis: input.analysis,
                    selectedLengths: [.seconds30to60], requestedCount: 3,
                    modelID: "fixture/model", gateway: gateway)
                let elapsed = Date().timeIntervalSince(started)
                getrusage(RUSAGE_SELF, &after)
                let cpu = Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec) +
                    Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec) / 1_000_000 +
                    Double(after.ru_stime.tv_sec - before.ru_stime.tv_sec) +
                    Double(after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
                print(String(format: "CLIPHELM_BENCHMARK minutes=%d size=%dx%d words=%d windows=%d wall=%.3f cpu=%.3f peak_rss_bytes=%lld",
                    minutes, width, height, input.transcript!.words.count,
                    result.evaluatedCount, elapsed, cpu, after.ru_maxrss))
                XCTAssertFalse(result.moments.isEmpty)
                XCTAssertLessThanOrEqual(result.evaluatedCount, 24)
            }
        }
    }

    func testLongTranscriptIsSampledAndInsufficientQualityExplained() async throws {
        let input = try fixture("podcast", long: true)
        let gateway = ProposalGateway()
        let result = try await MomentEngine(maximumSemanticWindows: 8).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.minutes5to10], requestedCount: 30,
            modelID: "fixture/model", gateway: gateway)
        XCTAssertLessThanOrEqual(result.evaluatedCount, 8)
        XCTAssertLessThan(result.moments.count, 30)
        XCTAssertNotNil(result.explanation)
        let prompts = await gateway.prompts
        XCTAssertTrue(prompts.allSatisfy { $0.utf8.count < 4_000 })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("sampled first/middle/last") })
        XCTAssertTrue(result.moments.allSatisfy { $0.proposal.range.durationMicroseconds >= 300_000_000 })
        XCTAssertGreaterThan(input.transcript!.words.count, 500)
    }

    func testCancelledOpenRouterResponseCannotBecomeAClip() async throws {
        let input = try fixture("podcast")
        let gateway = ProposalGateway()
        await gateway.setCancelOnRequest(true)
        let job = Task {
            try await MomentEngine().discover(asset: input.asset, transcript: input.transcript,
                analysis: input.analysis, selectedLengths: [.seconds30to60],
                requestedCount: 1, modelID: "fixture/model", gateway: gateway)
        }
        do {
            _ = try await job.value
            XCTFail("A cancelled model call must not yield a clip")
        } catch is CancellationError { }
    }

    func testSilentDemoUsesLocalEvidenceWithoutAICall() async throws {
        let input = try fixture("silentDemo")
        let gateway = ProposalGateway()
        let result = try await MomentEngine().discover(asset: input.asset, transcript: nil,
            analysis: input.analysis, selectedLengths: [.seconds30to60], requestedCount: 2,
            modelID: nil, gateway: gateway)
        XCTAssertFalse(result.moments.isEmpty)
        XCTAssertTrue(result.moments.allSatisfy { $0.quality >= 0.55 })
        let prompts = await gateway.prompts
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(result.explanation?.contains("Visual") == true)
    }

    func testAudioActivityWithoutTranscriptDoesNotClaimVisualMoment() async throws {
        let input = try fixture("podcast")
        let gateway = ProposalGateway()
        let result = try await MomentEngine().discover(asset: input.asset, transcript: nil,
            analysis: input.analysis, selectedLengths: [.seconds30to60], requestedCount: nil,
            modelID: nil, gateway: gateway)
        XCTAssertTrue(result.moments.isEmpty)
        XCTAssertTrue((result.explanation ?? "").contains("No visual"))
    }

    func testRejectsUntrustedProposalAndValidatesDuration() async throws {
        let input = try fixture("lecture")
        let gateway = ProposalGateway()
        await gateway.setCorrupt(true)
        let result = try await MomentEngine(maximumSemanticWindows: 4).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.minutes1to2], requestedCount: 2,
            modelID: "fixture/model", gateway: gateway)
        XCTAssertTrue(result.moments.isEmpty)
        XCTAssertGreaterThan(result.rejectedCount, 0)
    }

    func testRejectsRendererInstructionsAndWeakSemanticScores() async throws {
        let input = try fixture("codingTutorial")
        let gateway = ProposalGateway()
        await gateway.setAddCommand(true)
        let unsafe = try await MomentEngine(maximumSemanticWindows: 3).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: nil,
            modelID: "fixture/model", gateway: gateway)
        XCTAssertTrue(unsafe.moments.isEmpty)
        XCTAssertGreaterThan(unsafe.rejectedCount, 0)

        let weakGateway = ProposalGateway()
        await weakGateway.setForceWeak(true)
        let weak = try await MomentEngine(maximumSemanticWindows: 3).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: nil,
            modelID: "fixture/model", gateway: weakGateway)
        XCTAssertTrue(weak.moments.isEmpty)
    }

    func testDeduplicatesRepeatedIdeasAcrossNaturalBoundaries() async throws {
        let input = try fixture("repeated")
        let gateway = ProposalGateway()
        let result = try await MomentEngine(maximumSemanticWindows: 12).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: 4,
            modelID: "fixture/model", gateway: gateway)
        XCTAssertEqual(result.moments.count, 1)
        XCTAssertNotNil(result.explanation)
        XCTAssertTrue(result.moments.allSatisfy { $0.proposal.range.durationMicroseconds >= 30_000_000 })
    }

    func testContextDependentWindowsLoseToStandaloneAnswer() async throws {
        let input = try fixture("mixed")
        let gateway = ProposalGateway()
        let result = try await MomentEngine(maximumSemanticWindows: 16).discover(
            asset: input.asset, transcript: input.transcript, analysis: input.analysis,
            selectedLengths: [.seconds30to60], requestedCount: 3,
            modelID: "fixture/model", gateway: gateway)
        XCTAssertFalse(result.moments.isEmpty)
        XCTAssertTrue(result.moments.allSatisfy { $0.proposal.range.start.microseconds >= 50_000_000 })
    }
}
