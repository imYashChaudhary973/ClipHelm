import XCTest
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmEditing
@testable import ClipHelmPacing

final class PacingTests: XCTestCase {
    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(microseconds: Int64((seconds * 1_000_000).rounded()))
    }

    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    private func asset() throws -> MediaAsset {
        try MediaAsset(id: AssetID(), displayName: "speech.mov", duration: time(10),
                       width: 1920, height: 1080)
    }

    private func config(_ mode: PacingMode = .balanced, deadAir: Bool = true,
                        pauses: Bool = true, fillers: Bool = true, keepDemos: Bool = false) throws -> ClipConfiguration {
        try ClipConfiguration(outputFormat: .vertical, framingMode: .classicFullFrame,
            pacingMode: mode, selectedLengths: [], requestedClipCount: nil,
            soundMode: .source, captionStyle: .pop,
            smartEdit: SmartEditOptions(useVisionForTrickyShots: false, cutDeadAir: deadAir,
                trimLongPauses: pauses, cleanFillers: fillers, keepDemos: keepDemos))
    }

    private func word(_ text: String, _ start: Double, _ end: Double,
                      speaker: String? = nil, confidence: Double? = nil) throws -> TranscriptWord {
        try TranscriptWord(text: text, range: range(start, end),
                           confidence: confidence, speakerID: speaker)
    }

    private func analysis(_ asset: MediaAsset, pauses: [MediaTimeRange],
                          activity: [LocalSignal] = [], kind: ContentKind = .talkingHead,
                          screens: [LocalSignal] = []) throws -> AnalysisResult {
        let full = try MediaTimeRange(start: time(0), end: asset.duration)
        let quiet = try pauses.map { try LocalSignal(kind: .pause, range: $0,
            strength: 0.9, confidence: 0.7) }
        return try AnalysisResult(asset: asset, scenes: [Scene(assetID: asset.id, range: full)],
            signals: quiet + activity + screens, detections: [], subjectTracks: [],
            classifications: [ContentClassification(range: full, kind: kind,
                confidence: kind == .talkingHead ? 0.8 : 0.6)])
    }

    func testModesRetainDifferentContextualPauseLengths() throws {
        let source = try asset()
        let local = try analysis(source, pauses: [range(2, 5)])
        let transcript = try Transcript(assetID: source.id, words: [
            word("Think", 1, 1.5), word("again", 5.5, 6)])
        let cuts = try PacingMode.allCases.map { mode in
            try PacingPlanner().propose(in: range(0, 10), asset: source,
                configuration: config(mode), analysis: local, transcript: transcript)
        }
        XCTAssertTrue(cuts.allSatisfy { $0.count == 1 && $0[0].reason == .longPause })
        XCTAssertTrue(zip(cuts, cuts.dropFirst()).allSatisfy {
            $0[0].range.durationMicroseconds < $1[0].range.durationMicroseconds
        })
        XCTAssertEqual(cuts[0][0].range, try range(2.475, 4.525))
        XCTAssertEqual(cuts[3][0].range, try range(2.14, 4.86))
    }

    func testSentenceAndSpeakerTransitionKeepMoreBreathingRoom() throws {
        let source = try asset()
        let local = try analysis(source, pauses: [range(2, 5)])
        let ordinary = try Transcript(assetID: source.id, words: [
            word("Done", 1, 1.5, speaker: "A"), word("Next", 5.5, 6, speaker: "A")])
        let transition = try Transcript(assetID: source.id, segments: [
            TranscriptSegment(words: [word("Done.", 1, 1.5, speaker: "A")]),
            TranscriptSegment(words: [word("Next", 5.5, 6, speaker: "B")])])
        let plain = try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: ordinary)
        let contextual = try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: transition)
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(contextual.count, 1)
        XCTAssertEqual(plain[0].range.durationMicroseconds - contextual[0].range.durationMicroseconds,
                       550_000)
    }

    func testTranscriptAndAudioPreventSpeechClipping() throws {
        let source = try asset()
        let speech = try Transcript(assetID: source.id, words: [
            word("Before", 1, 1.5), word("Wait", 3, 3.3), word("After", 5.5, 6)])
        let local = try analysis(source, pauses: [range(2, 5)])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: speech).isEmpty)
        let cleanSpeech = try Transcript(assetID: source.id, words: [
            word("Before", 1, 1.5), word("After", 5.5, 6)])
        let activity = try LocalSignal(kind: .audioActivity, range: range(3, 3.25),
            strength: 0.8, confidence: 0.8)
        let noisy = try analysis(source, pauses: [range(2, 5)], activity: [activity])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: noisy, transcript: cleanSpeech).isEmpty)
    }

    func testDeadAirNeedsSpeechAnchorAndKeepsOnsetShoulder() throws {
        let source = try asset()
        let local = try analysis(source, pauses: [range(0, 2)])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: nil).isEmpty)
        let transcript = try Transcript(assetID: source.id, words: [word("Hello", 2.3, 2.8)])
        let cuts = try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: transcript)
        XCTAssertEqual(cuts.map(\.range), [try range(0, 1.88)])
        XCTAssertEqual(cuts.map(\.reason), [.deadAir])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(deadAir: false), analysis: local, transcript: transcript).isEmpty)
    }

    func testTrailingDeadAirAndPauseToggle() throws {
        let source = try asset()
        let local = try analysis(source, pauses: [range(2, 5), range(8, 10)])
        let speech = try Transcript(assetID: source.id, words: [
            word("First", 1, 1.5), word("Second", 5.5, 6), word("Last", 7.3, 7.7)])
        let cuts = try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(pauses: false), analysis: local, transcript: speech)
        XCTAssertEqual(cuts.map(\.range), [try range(8.12, 10)])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(deadAir: false, pauses: false), analysis: local,
            transcript: speech).isEmpty)
    }

    func testFillerNeedsIsolationAndNeverCutsNeighboringWords() throws {
        let source = try asset()
        let local = try analysis(source, pauses: [])
        let speech = try Transcript(assetID: source.id, words: [
            word("I", 1, 1.2), word("um,", 2, 2.2, confidence: 0.9),
            word("agree", 2.5, 2.8)])
        let cuts = try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: speech)
        XCTAssertEqual(cuts.map(\.range), [try range(1.96, 2.24)])
        XCTAssertEqual(cuts.map(\.reason), [.fillerWord])
        let close = try Transcript(assetID: source.id, words: [
            word("I", 1, 1.2), word("um", 1.25, 1.45), word("agree", 1.5, 1.8)])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: close).isEmpty)
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(fillers: false), analysis: local, transcript: speech).isEmpty)
        let uncertain = try Transcript(assetID: source.id, words: [
            word("I", 1, 1.2), word("uh", 2, 2.2, confidence: 0.4),
            word("agree", 2.5, 2.8)])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: uncertain).isEmpty)
    }

    func testKeepDemosProtectsSilentScreen() throws {
        let source = try asset()
        let screen = try LocalSignal(kind: .screenContent, range: range(2, 5),
            strength: 0.8, confidence: 0.8)
        let local = try analysis(source, pauses: [range(2, 5)], kind: .unknown, screens: [screen])
        let speech = try Transcript(assetID: source.id, words: [
            word("Watch", 1, 1.5), word("Done", 5.5, 6)])
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(keepDemos: true), analysis: local, transcript: speech).isEmpty)
        XCTAssertEqual(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: speech).count, 1)
        XCTAssertTrue(try PacingPlanner().propose(in: range(0, 10), asset: source,
            configuration: config(), analysis: local, transcript: speech,
            protectedRanges: [range(3, 4)]).isEmpty)
    }

    func testPlannerConvertsOnlyValidatedRemovalsToEditSpec() throws {
        let source = try asset()
        let local = try analysis(source, pauses: [range(0, 2), range(4, 6)])
        let speech = try Transcript(assetID: source.id, words: [
            word("Start", 2.3, 2.7), word("um", 3, 3.2),
            word("point", 3.5, 3.8), word("End", 6.3, 6.7)])
        let proposal = try ClipProposal(assetID: source.id, range: range(0, 10),
            title: "Point", rationale: "", confidence: 0.9)
        let spec = try ClipPlanner().plan(clipID: ClipID(), proposal: proposal,
            configuration: config(), asset: source, analysis: local, transcript: speech)
        XCTAssertEqual(spec.segments.map(\.sourceRange), try [
            range(1.88, 2.96), range(3.24, 4.325), range(5.675, 10)])
        XCTAssertEqual(spec.captionTrack?.cues.map(\.text), ["Start", "point", "End"])
        XCTAssertNoThrow(try EditSpecValidator().validate(spec, for: source, proposal: proposal))
        XCTAssertEqual(try JSONDecoder().decode(ClipHelmEditSpec.self,
            from: JSONEncoder().encode(spec)), spec)
    }
}
