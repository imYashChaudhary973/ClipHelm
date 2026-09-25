import Foundation
import XCTest
import ClipHelmCore
import ClipHelmAnalysis
@testable import ClipHelmEditing

final class EditingEngineTests: XCTestCase {
    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(microseconds: Int64((seconds * 1_000_000).rounded()))
    }

    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    private func asset(_ duration: Double = 60) throws -> MediaAsset {
        try MediaAsset(id: AssetID(), displayName: "Fixture.mov", duration: time(duration),
                       width: 1920, height: 1080)
    }

    private func configuration(framing: FramingMode = .smartAuto,
                               keepDemos: Bool = false) throws -> ClipConfiguration {
        try ClipConfiguration(outputFormat: .vertical, framingMode: framing,
            pacingMode: .balanced, selectedLengths: [], requestedClipCount: nil,
            soundMode: .normalize, captionStyle: .pop,
            smartEdit: SmartEditOptions(useVisionForTrickyShots: false, cutDeadAir: true,
                trimLongPauses: true, cleanFillers: false, keepDemos: keepDemos),
            captionWordByWord: true, captionBlurIn: true)
    }

    private func analysis(for asset: MediaAsset, signals: [LocalSignal] = [],
                          tracks: [SubjectTrack] = [], kind: ContentKind = .talkingHead) throws -> AnalysisResult {
        let full = try MediaTimeRange(start: time(0), end: asset.duration)
        return try AnalysisResult(asset: asset, scenes: [Scene(assetID: asset.id, range: full)],
            signals: signals, detections: [], subjectTracks: tracks,
            classifications: [ContentClassification(range: full, kind: kind, confidence: 0.9)])
    }

    func testPlannerBuildsNonDestructiveSpecFromLocalEvidence() throws {
        let source = try asset()
        let pauses = try [
            LocalSignal(kind: .pause, range: range(0, 2), strength: 0.9, confidence: 0.9),
            LocalSignal(kind: .pause, range: range(5, 7), strength: 0.9, confidence: 0.9),
        ]
        let observations = try [
            SubjectObservation(time: time(2.1), bounds: NormalizedRect(x: 0.12, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(4.9), bounds: NormalizedRect(x: 0.52, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(7), bounds: NormalizedRect(x: 0.55, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(59), bounds: NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4)),
        ]
        let track = try SubjectTrack(assetID: source.id, observations: observations)
        let local = try analysis(for: source, signals: pauses, tracks: [track])
        let proposal = try ClipProposal(assetID: source.id, range: range(0, 60),
                                         title: "Lesson", rationale: "Complete point", confidence: 0.9)
        let words = try [
            TranscriptWord(text: "Begin", range: range(2.5, 2.8)),
            TranscriptWord(text: "pause", range: range(6, 6.2)),
            TranscriptWord(text: "finish", range: range(8, 8.3)),
        ]
        let transcript = try Transcript(assetID: source.id, words: words)
        let clipID = ClipID()
        let spec = try ClipPlanner().plan(clipID: clipID, proposal: proposal,
            configuration: configuration(), asset: source, analysis: local, transcript: transcript)
        XCTAssertEqual(spec.clipID, clipID)
        XCTAssertEqual(spec.schemaVersion, 2)
        XCTAssertEqual(spec.segments.map(\.sourceRange), try [range(2, 5.2), range(6.8, 60)])
        XCTAssertEqual(spec.layout, .fill)
        XCTAssertEqual(spec.audioOperation, .normalize)
        XCTAssertEqual(spec.cropPaths.count, 3)
        XCTAssertGreaterThan(spec.cropPaths.first?.keyframes.count ?? 0, 2)
        XCTAssertEqual(spec.captionTrack?.cues.map(\.text), ["Begin", "finish"])
        XCTAssertTrue(spec.captionTrack?.wordByWord == true)
        XCTAssertTrue(spec.captionTrack?.blurIn == true)
        let timeline = try EditSpecValidator().validate(spec, for: source, proposal: proposal)
        XCTAssertEqual(timeline.duration, try time(56.4))
        XCTAssertNil(try timeline.editedTime(forSource: time(6)))
        XCTAssertEqual(try timeline.sourceTime(forEdited: time(3.2)), try time(6.8))
        XCTAssertEqual(try JSONDecoder().decode(ClipHelmEditSpec.self,
            from: JSONEncoder().encode(spec)), spec)
    }

    func testPlannerRejectsMismatchedGeneratedAndLocalInputs() throws {
        let source = try asset()
        let other = try asset()
        let local = try analysis(for: source)
        let valid = try ClipProposal(assetID: source.id, range: range(5, 20),
                                     title: "Valid", rationale: "", confidence: 0.8)
        let wrongAsset = try ClipProposal(assetID: other.id, range: range(5, 20),
                                          title: "Wrong", rationale: "", confidence: 0.8)
        let planner = ClipPlanner()
        let config = try configuration()
        XCTAssertThrowsError(try planner.plan(clipID: ClipID(), proposal: wrongAsset,
            configuration: config, asset: source, analysis: local))
        XCTAssertThrowsError(try planner.plan(clipID: ClipID(), proposal: valid,
            configuration: config, asset: source, analysis: local,
            intent: AIEditIntent(proposalID: valid.id, suggestedRange: range(0, 10))))
        XCTAssertThrowsError(try planner.plan(clipID: ClipID(), proposal: valid,
            configuration: config, asset: source, analysis: analysis(for: other)))
        XCTAssertThrowsError(try planner.plan(clipID: ClipID(), proposal: valid,
            configuration: config, asset: source, analysis: local,
            transcript: Transcript(assetID: other.id, words: [])))
    }

    func testPlannerKeepsIndependentCropPathsAcrossSceneCut() throws {
        let source = try asset(12)
        let first = try Scene(assetID: source.id, range: range(0, 6))
        let second = try Scene(assetID: source.id, range: range(6, 12))
        let left = try SubjectTrack(assetID: source.id, observations: [
            SubjectObservation(time: time(0), bounds: NormalizedRect(x: 0.05, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(2), bounds: NormalizedRect(x: 0.05, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(4), bounds: NormalizedRect(x: 0.05, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(5), bounds: NormalizedRect(x: 0.05, y: 0.2, width: 0.2, height: 0.4)),
        ])
        let right = try SubjectTrack(assetID: source.id, observations: [
            SubjectObservation(time: time(6), bounds: NormalizedRect(x: 0.75, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(8), bounds: NormalizedRect(x: 0.75, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(10), bounds: NormalizedRect(x: 0.75, y: 0.2, width: 0.2, height: 0.4)),
            SubjectObservation(time: time(11), bounds: NormalizedRect(x: 0.75, y: 0.2, width: 0.2, height: 0.4)),
        ])
        let local = try AnalysisResult(asset: source, scenes: [first, second], signals: [],
            detections: [], subjectTracks: [left, right],
            classifications: [ContentClassification(range: range(0, 12), kind: .conversation, confidence: 0.8)])
        let proposal = try ClipProposal(assetID: source.id, range: range(0, 12),
            title: "Cut", rationale: "", confidence: 0.9)
        let spec = try ClipPlanner().plan(clipID: ClipID(), proposal: proposal,
            configuration: configuration(), asset: source, analysis: local)
        XCTAssertEqual(spec.segments.count, 1)
        XCTAssertEqual(spec.cropPaths.count, 2)
        XCTAssertGreaterThan(spec.cropPaths[1].keyframes[0].rect.x -
            spec.cropPaths[0].keyframes[0].rect.x, 0.4)
        XCTAssertNoThrow(try EditSpecValidator().validate(spec, for: source))
        XCTAssertEqual(try JSONDecoder().decode(ClipHelmEditSpec.self,
            from: JSONEncoder().encode(spec)), spec)
    }

    func testDemoPreservationAndClassicLayout() throws {
        let source = try asset()
        let pause = try LocalSignal(kind: .pause, range: range(0, 3),
                                    strength: 0.9, confidence: 0.9)
        let local = try analysis(for: source, signals: [pause], kind: .demo)
        let proposal = try ClipProposal(assetID: source.id, range: range(0, 60),
                                         title: "Demo", rationale: "", confidence: 0.8)
        let config = try configuration(framing: .classicFullFrame, keepDemos: true)
        let spec = try ClipPlanner().plan(clipID: ClipID(), proposal: proposal,
            configuration: config, asset: source, analysis: local)
        XCTAssertEqual(spec.segments.map(\.sourceRange), [try range(0, 60)])
        XCTAssertEqual(spec.layout, .fit)
        XCTAssertTrue(spec.cropPaths.isEmpty)
        XCTAssertNil(spec.captionStyle)
        XCTAssertNil(spec.captionTrack)
    }

    func testTimelineMapsCutsAndLongSourceTimes() throws {
        let source = try asset(700_000)
        let segments = try [EditSegment(sourceRange: range(3, 10)),
                            EditSegment(sourceRange: range(604_800, 604_810))]
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: source.id,
            segments: segments, outputFormat: .horizontal, framingMode: .classicFullFrame,
            pacingMode: .natural, soundMode: .source, captionStyle: nil)
        let map = try EditTimeline(spec: spec)
        XCTAssertEqual(map.duration, try time(17))
        XCTAssertEqual(try map.editedTime(forSource: time(604_805)), try time(12))
        XCTAssertNil(try map.editedTime(forSource: time(100)))
        XCTAssertEqual(try map.sourceTime(forEdited: time(7)), try time(604_800))
        XCTAssertEqual(try map.sourceTime(forEdited: time(17)), try time(604_810))
        XCTAssertEqual(try map.editedRanges(forSource: range(8, 604_805)),
                       [try range(5, 7), try range(7, 12)])
        XCTAssertEqual(try map.sourceRanges(forEdited: range(5, 12)),
                       [try range(8, 10), try range(604_800, 604_805)])
        XCTAssertThrowsError(try map.sourceTime(forEdited: time(18)))

        let nearLimit = try MediaTime(microseconds: Int64.max - 20)
        let nearEnd = try MediaTime(microseconds: Int64.max - 10)
        let huge = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: source.id,
            segments: [EditSegment(sourceRange: MediaTimeRange(start: nearLimit, end: nearEnd))],
            outputFormat: .horizontal, framingMode: .classicFullFrame,
            pacingMode: .natural, soundMode: .source, captionStyle: nil)
        let hugeMap = try EditTimeline(spec: huge)
        let inside = try MediaTime(microseconds: Int64.max - 15)
        XCTAssertEqual(try hugeMap.editedTime(forSource: inside), try MediaTime(microseconds: 5))
        XCTAssertEqual(try hugeMap.sourceTime(forEdited: MediaTime(microseconds: 5)), inside)
    }

    func testHistoryAppliesTypedEditsAndUndoRedo() throws {
        let source = try asset()
        let proposal = try ClipProposal(assetID: source.id, range: range(0, 60),
                                         title: "Edit", rationale: "", confidence: 0.8)
        let initial = try ClipPlanner().plan(clipID: ClipID(), proposal: proposal,
            configuration: configuration(), asset: source, analysis: analysis(for: source))
        var history = try EditHistory(initial: initial, asset: source, proposal: proposal)
        try history.apply(.remove(range(10, 20)), asset: source, proposal: proposal)
        XCTAssertEqual(history.current.segments.map(\.sourceRange), try [range(0, 10), range(20, 60)])
        XCTAssertEqual(history.current.cropPaths.map(\.sourceRange), try [range(30, 60)])
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.current, initial)
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.current.segments.count, 2)
        try history.apply(.setLayout(.blurredBackground), asset: source, proposal: proposal)
        XCTAssertEqual(history.current.framingMode, .blurred)
        try history.apply(.setAudio(.mute), asset: source, proposal: proposal)
        XCTAssertEqual(history.current.audioOperation, .mute)
        let before = history.current
        XCTAssertThrowsError(try history.apply(.trim(to: range(100, 110)),
                                               asset: source, proposal: proposal))
        XCTAssertEqual(history.current, before)
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.canRedo)
        try history.apply(.setAudio(.original), asset: source, proposal: proposal)
        XCTAssertFalse(history.canRedo)
    }

    func testManualTrimAnimatedCropAndCaptionOperations() throws {
        let source = try asset()
        let initial = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: source.id,
            segments: [EditSegment(sourceRange: range(0, 20))], outputFormat: .vertical,
            framingMode: .smartAuto, pacingMode: .balanced, soundMode: .source,
            captionStyle: nil)
        var history = try EditHistory(initial: initial, asset: source)
        try history.apply(.trim(to: range(5, 15)), asset: source)
        XCTAssertEqual(history.current.segments.map(\.sourceRange), [try range(5, 15)])

        let crop = try CropPath(sourceRange: range(5, 15), keyframes: [
            CropKeyframe(sourceTime: time(5),
                rect: NormalizedRect(x: 0.2, y: 0, width: 0.31640625, height: 1)),
            CropKeyframe(sourceTime: time(15),
                rect: NormalizedRect(x: 0.5, y: 0, width: 0.31640625, height: 1)),
        ])
        try history.apply(.setCropPaths([crop]), asset: source)
        XCTAssertEqual(history.current.cropPaths.first?.keyframes.count, 2)
        XCTAssertEqual(try crop.rect(atSourceTime: time(10)).x, 0.35, accuracy: 0.000001)
        let track = try CaptionTrack(cues: [CaptionCue(sourceRange: range(6, 7), text: "Hello")],
                                     wordByWord: true, blurIn: false)
        try history.apply(.setCaptions(style: .impact, track: track), asset: source)
        XCTAssertEqual(history.current.captionTrack, track)
        let beforeInvalid = history.current
        let wrongAspect = try CropPath(sourceRange: range(5, 15), keyframes: [
            CropKeyframe(sourceTime: time(5),
                rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)),
        ])
        XCTAssertThrowsError(try history.apply(.setCropPaths([wrongAspect]), asset: source))
        XCTAssertEqual(history.current, beforeInvalid)
        try history.apply(.trim(to: range(10, 15)), asset: source)
        XCTAssertTrue(history.current.cropPaths.isEmpty)
        XCTAssertNil(history.current.captionTrack)
        XCTAssertNil(history.current.captionStyle)
    }

    func testInvalidSpecDataIsRejectedAndVersionOneMigrates() throws {
        let source = try asset()
        let segment = EditSegment(sourceRange: try range(0, 10))
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: source.id,
            segments: [segment], outputFormat: .vertical, framingMode: .smartAuto,
            pacingMode: .balanced, soundMode: .source, captionStyle: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        json["layout"] = "fit"
        XCTAssertThrowsError(try JSONDecoder().decode(ClipHelmEditSpec.self,
            from: JSONSerialization.data(withJSONObject: json)))

        let wrongAspect = try CropPath(sourceRange: range(0, 10), keyframes: [
            CropKeyframe(sourceTime: time(0),
                rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        ])
        let badSpec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: source.id,
            segments: [segment], outputFormat: .vertical, framingMode: .smartAuto,
            pacingMode: .balanced, soundMode: .source, captionStyle: nil,
            cropPaths: [wrongAspect])
        XCTAssertThrowsError(try EditSpecValidator().validate(badSpec, for: source))
        var badJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(badSpec)) as? [String: Any])
        var paths = try XCTUnwrap(badJSON["cropPaths"] as? [[String: Any]])
        var frames = try XCTUnwrap(paths[0]["keyframes"] as? [[String: Any]])
        var rectangle = try XCTUnwrap(frames[0]["rect"] as? [String: Any])
        rectangle["width"] = 2.0
        frames[0]["rect"] = rectangle
        paths[0]["keyframes"] = frames
        badJSON["cropPaths"] = paths
        XCTAssertThrowsError(try JSONDecoder().decode(ClipHelmEditSpec.self,
            from: JSONSerialization.data(withJSONObject: badJSON)))
        XCTAssertThrowsError(try CropPath(sourceRange: range(0, 10), keyframes: [
            CropKeyframe(sourceTime: time(5), rect: wrongAspect.keyframes[0].rect)]))

        json.removeValue(forKey: "layout")
        json.removeValue(forKey: "cropPaths")
        json.removeValue(forKey: "audioOperation")
        json.removeValue(forKey: "captionTrack")
        json["schemaVersion"] = 1
        json["soundMode"] = "source"
        let migrated = try JSONDecoder().decode(ClipHelmEditSpec.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.layout, .fill)
        XCTAssertTrue(migrated.cropPaths.isEmpty)
    }
}
