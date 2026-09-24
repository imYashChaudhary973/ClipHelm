import Foundation
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

    func testConnection() async throws {}
    func fetchCatalog(_ filter: CatalogFilter) async throws -> Data { Data() }
    func transcribeAudio(_ audio: Data, modelID: String) async throws -> Data { Data() }

    func completeClipProposal(prompt: String, modelID: String) async throws -> Data {
        prompts.append(prompt)
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
}

final class MomentEngineTests: XCTestCase {
    private struct Fixture {
        let asset: MediaAsset
        let transcript: Transcript?
        let analysis: AnalysisResult
    }

    private func fixture(_ kind: String, long: Bool = false) throws -> Fixture {
        let duration = long ? 1_200 : 120
        let asset = try MediaAsset(id: AssetID(), displayName: "\(kind).mov",
            duration: MediaTime(microseconds: Int64(duration) * 1_000_000), width: 1920, height: 1080)
        let scenes = try stride(from: 0, to: duration, by: 30).map { start in
            Scene(assetID: asset.id, range: try MediaTimeRange(
                start: MediaTime(microseconds: Int64(start) * 1_000_000),
                end: MediaTime(microseconds: Int64(min(duration, start + 30)) * 1_000_000)))
        }
        let all = try MediaTimeRange(start: MediaTime(microseconds: 0),
                                     end: MediaTime(microseconds: Int64(duration) * 1_000_000))
        let visual = kind == "silentDemo" || kind == "screenRecording" || kind == "codingTutorial"
        let signals = try [LocalSignal(kind: visual ? .motion : .audioActivity, range: all,
                                       strength: 0.95, confidence: 0.95)]
        let content: ContentKind = switch kind {
        case "podcast", "interview": .conversation
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
        case "mixed": ["contextneeded this depends on earlier missing details.", "contextneeded as I said before this is unclear.", "Why the solution follows from a concrete example.", "The completed example explains the useful result."]
        default: ["Why this explanation stands alone."]
        }
        var segments: [TranscriptSegment] = []
        for block in 0..<(duration / 30) {
            let phrase = phrases[block % phrases.count].split(separator: " ").map(String.init)
            var words: [TranscriptWord] = []
            for index in 0..<20 {
                let second = block * 30 + index
                let text = phrase[index % phrase.count]
                let range = try MediaTimeRange(
                    start: MediaTime(microseconds: Int64(second) * 1_000_000),
                    end: MediaTime(microseconds: Int64(second + 1) * 1_000_000))
                words.append(try TranscriptWord(text: text, range: range,
                    speakerID: kind == "interview" ? (block.isMultiple(of: 2) ? "A" : "B") : "A"))
            }
            segments.append(try TranscriptSegment(words: words))
        }
        return .init(asset: asset,
            transcript: try Transcript(assetID: asset.id, segments: segments), analysis: analysis)
    }

    func testSpeechFixturesUseBoundedSemanticWindowsAndReturnStrongMoments() async throws {
        for kind in ["podcast", "interview", "codingTutorial", "lecture", "screenRecording"] {
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
