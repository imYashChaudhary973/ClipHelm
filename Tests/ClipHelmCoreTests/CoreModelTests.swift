import Foundation
import XCTest
@testable import ClipHelmCore

final class CoreModelTests: XCTestCase {
    private func time(_ value: Int64) throws -> MediaTime {
        try MediaTime(microseconds: value)
    }

    private func range(_ start: Int64, _ end: Int64) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    func testSerializationRoundTrip() throws {
        let assetID = AssetID()
        let asset = try MediaAsset(id: assetID, displayName: "Interview.mov",
                                   duration: time(90_000_000), width: 1920, height: 1080)
        let transcript = try Transcript(assetID: assetID, words: [
            TranscriptWord(text: "Hello", range: range(1_000_000, 1_500_000), confidence: 0.98),
            TranscriptWord(text: "world", range: range(1_500_000, 2_000_000), confidence: 0.95),
        ])
        let scene = Scene(assetID: assetID, range: try range(0, 30_000_000))
        let track = try SubjectTrack(assetID: assetID, observations: [
            SubjectObservation(time: time(1_000_000),
                               bounds: NormalizedRect(x: 0.2, y: 0.1, width: 0.4, height: 0.6)),
        ])
        let signal = try MomentSignal(kind: .hook, range: range(1_000_000, 3_000_000), strength: 0.9)
        let candidate = try MomentCandidate(assetID: assetID, range: range(0, 10_000_000),
                                            signals: [signal], score: 0.8)
        let proposal = try ClipProposal(assetID: assetID, range: range(0, 10_000_000),
                                        title: "A strong opening", rationale: "Complete thought", confidence: 0.8)
        let intent = AIEditIntent(proposalID: proposal.id, suggestedRange: try range(1_000_000, 9_000_000),
                                  preserveDemo: true, framingPreference: .smartAuto)
        let smartEdit = SmartEditOptions(useVisionForTrickyShots: true, cutDeadAir: true,
                                         trimLongPauses: true, cleanFillers: false, keepDemos: true)
        let configuration = try ClipConfiguration(outputFormat: .vertical, framingMode: .smartAuto,
                                                  pacingMode: .balanced, selectedLengths: [.seconds10to30, .minutes1to2],
                                                  requestedClipCount: nil, soundMode: .source,
                                                  captionStyle: .pop, smartEdit: smartEdit)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: assetID,
                                       segments: [EditSegment(sourceRange: try range(0, 4_000_000)),
                                                  EditSegment(sourceRange: try range(5_000_000, 10_000_000))],
                                       outputFormat: .vertical, framingMode: .smartAuto,
                                       pacingMode: .balanced, soundMode: .source, captionStyle: .pop)

        func roundTrip<T: Codable & Equatable>(_ value: T) throws {
            XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
        }

        try roundTrip(ProjectID())
        try roundTrip(assetID)
        try roundTrip(ClipID())
        try roundTrip(asset)
        try roundTrip(transcript)
        try roundTrip(scene)
        try roundTrip(track)
        try roundTrip(candidate)
        try roundTrip(proposal)
        try roundTrip(intent)
        try roundTrip(configuration)
        try roundTrip(spec)
        XCTAssertNoThrow(try proposal.validate(for: asset))
        XCTAssertNoThrow(try intent.validate(for: proposal))
        XCTAssertNoThrow(try spec.validate(for: asset))
    }

    func testDecodedInputCannotBypassValidation() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(MediaTime.self, from: Data("-1".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(MediaTimeRange.self,
                                                       from: Data(#"{"start":10,"end":10}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(OutputFormat.self,
                                                       from: Data(#"{"width":0,"height":1920}"#.utf8)))

        let assetID = AssetID()
        let proposal = try ClipProposal(assetID: assetID, range: range(0, 10_000_000),
                                        title: "Valid", rationale: "Reason", confidence: 0.8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as? [String: Any])
        json["confidence"] = 4.0
        XCTAssertThrowsError(try JSONDecoder().decode(ClipProposal.self,
                                                       from: JSONSerialization.data(withJSONObject: json)))

        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: assetID,
                                       segments: [EditSegment(sourceRange: try range(0, 10_000_000))],
                                       outputFormat: .horizontal, framingMode: .classicFullFrame,
                                       pacingMode: .natural, soundMode: .source, captionStyle: nil)
        var specJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        specJSON["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(ClipHelmEditSpec.self,
                                                       from: JSONSerialization.data(withJSONObject: specJSON)))
    }

    func testTranscriptSegmentsRoundTripAndRejectBadWordMetadata() throws {
        let assetID = AssetID()
        let first = try TranscriptWord(text: "Hello", range: range(100_000, 300_000),
                                       confidence: 0.8, speakerID: "A")
        let second = try TranscriptWord(text: "world", range: range(300_000, 500_000),
                                        speakerID: "A")
        let transcript = try Transcript(assetID: assetID,
                                        segments: [TranscriptSegment(words: [first, second])])
        XCTAssertEqual(try JSONDecoder().decode(Transcript.self,
            from: JSONEncoder().encode(transcript)), transcript)
        XCTAssertEqual(transcript.segments.first?.text, "Hello world")
        XCTAssertThrowsError(try TranscriptWord(text: "bad", range: range(0, 1), confidence: 1.1))
        XCTAssertThrowsError(try TranscriptSegment(words: [first,
            TranscriptWord(text: "other", range: range(300_000, 500_000), speakerID: "B")]))

        let legacy = try JSONSerialization.data(withJSONObject: [
            "assetID": assetID.rawValue.uuidString,
            "words": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))]
        ])
        XCTAssertEqual(try JSONDecoder().decode(Transcript.self, from: legacy).words, [first])
    }

    func testSemanticBoundsAndTimelineOrder() throws {
        let asset = try MediaAsset(id: AssetID(), displayName: "Source.mp4",
                                   duration: time(10_000_000), width: 1920, height: 1080)
        let proposal = try ClipProposal(assetID: asset.id, range: range(0, 11_000_000),
                                        title: "Outside", rationale: "", confidence: 0.5)
        XCTAssertThrowsError(try proposal.validate(for: asset))
        XCTAssertThrowsError(try AIEditIntent(proposalID: proposal.id,
                                               suggestedRange: range(1_000_000, 12_000_000)).validate(for: proposal))
        XCTAssertThrowsError(try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
                                                   segments: [EditSegment(sourceRange: range(0, 5_000_000)),
                                                              EditSegment(sourceRange: range(4_000_000, 6_000_000))],
                                                   outputFormat: .vertical, framingMode: .blurred,
                                                   pacingMode: .fast, soundMode: .mute, captionStyle: nil))
        let outsideSpec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
                                               segments: [EditSegment(sourceRange: range(0, 11_000_000))],
                                               outputFormat: .vertical, framingMode: .blurred,
                                               pacingMode: .fast, soundMode: .mute, captionStyle: nil)
        XCTAssertThrowsError(try outsideSpec.validate(for: asset))
    }

    func testMediaTimeMapPreservesEndpointsAndLongTimelinePrecision() throws {
        let source = try range(3_000_000, 604_803_000_000)
        let proxy = try range(0, 604_800_000_417)
        let map = MediaTimeMap(source: source, proxy: proxy)
        XCTAssertEqual(try map.proxyTime(for: source.start), proxy.start)
        XCTAssertEqual(try map.proxyTime(for: source.end), proxy.end)
        XCTAssertEqual(try map.sourceTime(for: proxy.end), source.end)
        for offset: Int64 in [1, 33_366, 86_400_000_000, 604_799_999_999] {
            let original = try time(source.start.microseconds + offset)
            let mapped = try map.proxyTime(for: original)
            let roundTrip = try map.sourceTime(for: mapped)
            XCTAssertLessThanOrEqual(abs(roundTrip.microseconds - original.microseconds), 1)
        }
        XCTAssertThrowsError(try map.proxyTime(for: time(source.end.microseconds + 1)))
        XCTAssertEqual(try JSONDecoder().decode(MediaTimeMap.self, from: JSONEncoder().encode(map)), map)
    }
}
