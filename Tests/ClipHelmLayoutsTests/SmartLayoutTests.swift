import Foundation
import XCTest
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmMedia
import ClipHelmOpenRouter
@testable import ClipHelmLayouts
import ClipHelmLayoutVision

final class SmartLayoutTests: XCTestCase {
    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(microseconds: Int64((seconds * 1_000_000).rounded()))
    }

    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    private func asset(duration: Double = 12) throws -> MediaAsset {
        try MediaAsset(id: AssetID(), displayName: "screen.mov", duration: time(duration),
                       width: 1920, height: 1080)
    }

    private func tracks(_ asset: MediaAsset, count: Int) throws -> [SubjectTrack] {
        try (0..<count).map { index in
            try SubjectTrack(assetID: asset.id, observations: stride(from: 0.0,
                through: Double(asset.duration.microseconds) / 1_000_000 - 1, by: 1).map { seconds in
                SubjectObservation(time: try! time(seconds),
                    bounds: try! NormalizedRect(x: 0.15 + Double(index) * 0.45, y: 0.2,
                                                width: 0.2, height: 0.4))
            })
        }
    }

    private func analysis(_ asset: MediaAsset, kind: ContentKind = .unknown,
                          faces: Int = 0, screen: Double = 0,
                          classifications: [ContentClassification]? = nil) throws -> AnalysisResult {
        let full = try MediaTimeRange(start: time(0), end: asset.duration)
        let signals = screen > 0 ? [try LocalSignal(kind: .screenContent, range: full,
            strength: screen, confidence: 0.9)] : []
        return try AnalysisResult(asset: asset, scenes: [Scene(assetID: asset.id, range: full)],
            signals: signals, detections: [], subjectTracks: tracks(asset, count: faces),
            classifications: classifications ?? [ContentClassification(range: full,
                kind: kind, confidence: kind == .unknown ? 0.2 : 0.65)])
    }

    private func layout(_ asset: MediaAsset, _ analysis: AnalysisResult,
                        format: OutputFormat = .vertical, keepDemos: Bool = false,
                        hints: [ScreenContentHint] = []) throws -> [LayoutCue] {
        try SmartLayoutEngine().plan(segments: [EditSegment(sourceRange: range(0,
            Double(asset.duration.microseconds) / 1_000_000))], asset: asset,
            format: format, analysis: analysis, keepDemos: keepDemos, screenHints: hints)
    }

    func testSevenLayoutsFromLocalEvidence() throws {
        let source = try asset()
        XCTAssertEqual(try layout(source, analysis(source)).map(\.layout), [.original])
        XCTAssertEqual(try layout(source, analysis(source, kind: .talkingHead, faces: 1)).map(\.layout),
                       [.speakerFocus])
        XCTAssertEqual(try layout(source, analysis(source, kind: .conversation, faces: 2)).map(\.layout),
                       [.stackedSpeakers])
        XCTAssertEqual(try layout(source, analysis(source, kind: .conversation, faces: 2),
                                  format: .horizontal).map(\.layout), [.sideBySide])
        XCTAssertEqual(try layout(source, analysis(source, kind: .demo, faces: 1, screen: 0.8),
                                  keepDemos: true).map(\.layout), [.screenFocus])
        XCTAssertEqual(try layout(source, analysis(source, kind: .screenShare, faces: 1, screen: 0.4),
                                  format: .horizontal).map(\.layout), [.screenAndSpeaker])
        XCTAssertEqual(try layout(source, analysis(source, kind: .screenShare, faces: 1, screen: 0.4))
            .map(\.layout), [.pictureInPicture])
    }

    func testRepeatedDetectionsOfOneSpeakerDoNotCreateTwoSpeakerLayout() throws {
        let source = try asset()
        let full = try range(0, 12)
        let box = try NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4)
        let detections = try [
            SubjectDetection(time: time(0), bounds: box, confidence: 0.9, isFace: true),
            SubjectDetection(time: time(1), bounds: box, confidence: 0.9, isFace: true),
        ]
        let local = try AnalysisResult(asset: source,
            scenes: [Scene(assetID: source.id, range: full)], signals: [],
            detections: detections, subjectTracks: tracks(source, count: 1),
            classifications: [ContentClassification(range: full, kind: .talkingHead, confidence: 0.7)])
        XCTAssertEqual(try layout(source, local).map(\.layout), [.speakerFocus])
    }

    func testDemoAndCodeHintsProtectReadability() throws {
        let source = try asset()
        let local = try analysis(source, kind: .talkingHead, faces: 1, screen: 0.45)
        let code = try ScreenContentHint(range: range(0, 12), kind: .ideCode, confidence: 0.85)
        XCTAssertEqual(try layout(source, local, hints: [code]).map(\.layout), [.screenFocus])
        XCTAssertEqual(ScreenContentDetector.classify(textLines: ["import SwiftUI", "func view() {"],
            averageHeight: 0.02).0, .ideCode)
        XCTAssertEqual(ScreenContentDetector.classify(textLines: ["https://localhost:3000"],
            averageHeight: 0.02).0, .browserDemo)
        XCTAssertEqual(ScreenContentDetector.classify(textLines: ["Agenda", "Q3 results"],
            averageHeight: 0.07).0, .slides)
        XCTAssertEqual(ScreenContentDetector.classify(textLines: ["File", "Edit", "Settings"],
            averageHeight: 0.02).0, .softwareUI)
        XCTAssertEqual(ScreenContentDetector.classify(textLines: [], averageHeight: 0).0, .screenShare)
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenContentHint.self,
            from: Data(#"{"range":{"start":0,"end":1000000},"kind":"ideCode","confidence":2.0}"#.utf8)))
    }

    func testHysteresisIgnoresOneSecondFlashAndSwitchesForSustainedDemo() throws {
        let source = try asset()
        let brief = try [
            ContentClassification(range: range(0, 4), kind: .talkingHead, confidence: 0.7),
            ContentClassification(range: range(4, 5), kind: .demo, confidence: 0.7),
            ContentClassification(range: range(5, 12), kind: .talkingHead, confidence: 0.7),
        ]
        XCTAssertEqual(try layout(source, analysis(source, faces: 1,
            classifications: brief), keepDemos: true).map(\.layout), [.speakerFocus])
        let sustained = try [
            ContentClassification(range: range(0, 4), kind: .talkingHead, confidence: 0.7),
            ContentClassification(range: range(4, 12), kind: .demo, confidence: 0.7),
        ]
        let cues = try layout(source, analysis(source, faces: 1,
            classifications: sustained), keepDemos: true)
        XCTAssertEqual(cues.map(\.layout), [.speakerFocus, .screenFocus])
        XCTAssertEqual(cues[0].sourceRange, try range(0, 4))
        XCTAssertEqual(cues[1].sourceRange, try range(4, 12))
        XCTAssertTrue(cues.allSatisfy { $0.sourceRange.durationMicroseconds >= 3_000_000 })
    }

    func testVisionOnlyForUncertainScreensAndRejectsRendererFields() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../ClipHelmMediaTests/Fixtures/valid.mp4").standardizedFileURL
        let source = try await MediaProbe().probe(fileURL: fixture, displayName: "valid.mp4").asset
        let full = try MediaTimeRange(start: time(0), end: source.duration)
        let local = try AnalysisResult(asset: source,
            scenes: [Scene(assetID: source.id, range: full)], signals: [], detections: [],
            subjectTracks: [], classifications: [ContentClassification(range: full,
                kind: .screenShare, confidence: 0.45)])
        let onDevice = try await ScreenContentDetector().detect(sourceURL: fixture, asset: source,
            analysis: local, range: full)
        XCTAssertEqual(onDevice.map(\.range), [full])
        let catalog = Data(#"{"data":[{"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":["response_format"]}]}"#.utf8)
        let gateway = MockOpenRouterGateway(catalogs: [.all: catalog, .transcription: Data(#"{"data":[]}"#.utf8)])
        let suite = "ClipHelm-Layout-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = OpenRouterModelRegistry(gateway: gateway, defaultsSuiteName: suite)
        _ = try await registry.refresh()
        try await registry.selectModel(id: "vendor/vision", for: .visionAnalysis)
        func config(_ enabled: Bool) throws -> ClipConfiguration {
            try ClipConfiguration(outputFormat: .vertical, framingMode: .smartAuto,
                pacingMode: .balanced, selectedLengths: [], requestedClipCount: nil,
                soundMode: .source, captionStyle: nil,
                smartEdit: SmartEditOptions(useVisionForTrickyShots: enabled, cutDeadAir: false,
                    trimLongPauses: false, cleanFillers: false, keepDemos: true))
        }
        let advisor = LayoutVisionAdvisor()
        let skipped = try await advisor.classify(sourceURL: fixture, asset: source,
            configuration: config(false), range: full, analysis: local, localHints: [],
            registry: registry, gateway: gateway)
        XCTAssertTrue(skipped.isEmpty)
        let noRequests = await gateway.layoutRequests
        XCTAssertTrue(noRequests.isEmpty)
        await gateway.setLayoutResponses([Data(#"{"kind":"ideCode","confidence":0.9,"layout":"screenFocus"}"#.utf8)])
        do {
            _ = try await advisor.classify(sourceURL: fixture, asset: source,
                configuration: config(true), range: full, analysis: local, localHints: [],
                registry: registry, gateway: gateway)
            XCTFail("Model-provided layout must be rejected")
        } catch let error as OpenRouterGatewayError {
            XCTAssertEqual(error, .invalidResponse)
        }
        await gateway.setLayoutResponses([Data(#"{"kind":"ideCode","confidence":true}"#.utf8)])
        do {
            _ = try await advisor.classify(sourceURL: fixture, asset: source,
                configuration: config(true), range: full, analysis: local, localHints: [],
                registry: registry, gateway: gateway)
            XCTFail("Boolean confidence must be rejected")
        } catch let error as OpenRouterGatewayError {
            XCTAssertEqual(error, .invalidResponse)
        }
        await gateway.setLayoutResponses([Data(#"{"kind":"ideCode","confidence":0.9}"#.utf8)])
        let hints = try await advisor.classify(sourceURL: fixture, asset: source,
            configuration: config(true), range: full, analysis: local, localHints: [],
            registry: registry, gateway: gateway)
        XCTAssertEqual(hints.map(\.kind), [.ideCode])
        XCTAssertEqual(hints[0].range, full)
        let unknownScreen = try AnalysisResult(asset: source,
            scenes: [Scene(assetID: source.id, range: full)],
            signals: [LocalSignal(kind: .screenContent, range: full,
                                  strength: 0.8, confidence: 0.8)],
            detections: [], subjectTracks: [],
            classifications: [ContentClassification(range: full, kind: .unknown, confidence: 0.2)])
        await gateway.setLayoutResponses([Data(#"{"kind":"slides","confidence":0.8}"#.utf8)])
        let recovered = try await advisor.classify(sourceURL: fixture, asset: source,
            configuration: config(true), range: full, analysis: unknownScreen,
            localHints: [], registry: registry, gateway: gateway)
        XCTAssertEqual(recovered.map(\.kind), [.slides])
        let requests = await gateway.layoutRequests
        XCTAssertEqual(requests.map(\.frameCount), [2, 2, 2, 2])
    }
}
