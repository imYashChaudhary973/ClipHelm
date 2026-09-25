import Foundation
import XCTest
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmMedia
import ClipHelmOpenRouter
import ClipHelmFraming
import ClipHelmFramingVision

final class SmartAutoFrameTests: XCTestCase {
    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(microseconds: Int64((seconds * 1_000_000).rounded()))
    }

    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    private func asset(width: Int = 1920, height: Int = 1080, duration: Double = 12) throws -> MediaAsset {
        try MediaAsset(id: AssetID(), displayName: "fixture.mov", duration: time(duration),
                       width: width, height: height)
    }

    private func track(_ source: MediaAsset, _ points: [(Double, Double)]) throws -> SubjectTrack {
        try SubjectTrack(assetID: source.id, observations: points.map { seconds, x in
            SubjectObservation(time: try! time(seconds),
                bounds: try! NormalizedRect(x: x, y: 0.2, width: 0.18, height: 0.4))
        })
    }

    private func analysis(_ source: MediaAsset, tracks: [SubjectTrack] = [],
                          boundaries: [Double] = [], kind: ContentKind = .talkingHead,
                          screen: Double = 0) throws -> AnalysisResult {
        let points = [0.0] + boundaries + [Double(source.duration.microseconds) / 1_000_000]
        let scenes = try zip(points, points.dropFirst()).map {
            Scene(assetID: source.id, range: try range($0, $1))
        }
        let full = try range(0, points.last!)
        let signals = screen > 0 ? [try LocalSignal(kind: .screenContent,
            range: full, strength: screen, confidence: 0.9)] : []
        return try AnalysisResult(asset: source, scenes: scenes, signals: signals,
            detections: [], subjectTracks: tracks,
            classifications: [ContentClassification(range: full, kind: kind, confidence: 0.8)])
    }

    func testStableSpeakerJitterAndMovingSpeaker() throws {
        let source = try asset()
        let stable = try track(source, [(0, 0.30), (1, 0.315), (2, 0.29), (3, 0.31),
                                        (4, 0.30), (5, 0.315), (6, 0.30), (8, 0.30), (11, 0.30)])
        let result = try SmartAutoFrameEngine().frame(range: range(0, 12), asset: source,
            format: .vertical, analysis: analysis(source, tracks: [stable]))
        XCTAssertEqual(result.paths.count, 1)
        let path = try XCTUnwrap(result.paths.first)
        let xs = path.keyframes.map(\.rect.x)
        XCTAssertLessThan((xs.max() ?? 0) - (xs.min() ?? 0), 0.04)
        XCTAssertTrue(result.uncertainRanges.isEmpty)

        let moving = try track(source, [(0, 0.08), (2, 0.16), (4, 0.28), (6, 0.45),
                                        (8, 0.62), (10, 0.70), (11.5, 0.70)])
        let movingPath = try XCTUnwrap(SmartAutoFrameEngine().frame(range: range(0, 12),
            asset: source, format: .vertical, analysis: analysis(source, tracks: [moving])).paths.first)
        XCTAssertGreaterThan(movingPath.keyframes.last!.rect.x - movingPath.keyframes.first!.rect.x, 0.35)
        for pair in zip(movingPath.keyframes, movingPath.keyframes.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(pair.1.rect.x - pair.0.rect.x), 0.081)
        }
    }

    func testTwoSpeakersScreenAndSceneReset() throws {
        let source = try asset()
        let left = try track(source, [(0, 0.22), (2, 0.22), (4, 0.22), (5, 0.22)])
        let right = try track(source, [(0, 0.40), (2, 0.40), (4, 0.40), (5, 0.40)])
        let pairPath = try XCTUnwrap(SmartAutoFrameEngine().frame(range: range(0, 6),
            asset: source, format: .vertical, analysis: analysis(source, tracks: [left, right])).paths.first)
        XCTAssertEqual(pairPath.keyframes.first!.rect.x + pairPath.keyframes.first!.rect.width / 2,
                       0.40, accuracy: 0.05)

        let screenResult = try SmartAutoFrameEngine().frame(range: range(0, 6), asset: source,
            format: .vertical, analysis: analysis(source, tracks: [left], kind: .screenShare, screen: 0.9))
        XCTAssertEqual(screenResult.paths[0].keyframes[0].rect.x +
            screenResult.paths[0].keyframes[0].rect.width / 2, 0.5, accuracy: 0.001)

        let entering = try track(source, [(6, 0.70), (8, 0.70), (11, 0.70)])
        let cut = try SmartAutoFrameEngine().frame(range: range(0, 12), asset: source,
            format: .vertical, analysis: analysis(source, tracks: [left, entering], boundaries: [6]))
        XCTAssertEqual(cut.paths.count, 2)
        XCTAssertGreaterThan(cut.paths[1].keyframes[0].rect.x - cut.paths[0].keyframes.last!.rect.x, 0.25)
    }

    func testDetectionGapLeavingFrameAndVerticalSource() throws {
        let source = try asset()
        let disappearing = try track(source, [(0, 0.65), (1, 0.65), (2, 0.65), (4, 0.65)])
        let path = try XCTUnwrap(SmartAutoFrameEngine().frame(range: range(0, 12), asset: source,
            format: .vertical, analysis: analysis(source, tracks: [disappearing])).paths.first)
        let atFive = try path.rect(atSourceTime: time(5))
        let atEight = try path.rect(atSourceTime: time(8))
        XCTAssertGreaterThan(atFive.x, atEight.x)
        let confidence = try SmartAutoFrameEngine().frame(range: range(0, 12), asset: source,
            format: .vertical, analysis: analysis(source, tracks: [disappearing]))
        XCTAssertFalse(confidence.uncertainRanges.isEmpty)

        let portrait = try asset(width: 1080, height: 1920)
        let portraitPath = try XCTUnwrap(SmartAutoFrameEngine().frame(range: range(0, 12),
            asset: portrait, format: .vertical, analysis: analysis(portrait)).paths.first)
        XCTAssertEqual(portraitPath.keyframes.count, 1)
        XCTAssertEqual(portraitPath.keyframes[0].rect.width, 1, accuracy: 0.000001)
    }

    func testOnlyUncertainPartOfLongSceneNeedsVision() throws {
        let source = try asset(duration: 60)
        let observations = stride(from: 0.0, through: 27.0, by: 1.0).map { ($0, 0.25) }
        let result = try SmartAutoFrameEngine().frame(range: range(0, 60), asset: source,
            format: .vertical, analysis: analysis(source, tracks: [track(source, observations)]))
        XCTAssertEqual(result.paths.count, 2)
        XCTAssertEqual(result.uncertainRanges, [try range(30, 60)])
    }

    func testValidatedVisionHintCanPrioritizeScreenOverFace() throws {
        let source = try asset(duration: 6)
        let speaker = try track(source, [(0, 0.05), (2, 0.05), (4, 0.05), (5, 0.05)])
        let local = try AnalysisResult(asset: source,
            scenes: [Scene(assetID: source.id, range: range(0, 6))], signals: [],
            detections: [], subjectTracks: [speaker],
            classifications: [ContentClassification(range: range(0, 6), kind: .talkingHead, confidence: 0.3)])
        let vision = try ContentClassification(range: range(0, 6), kind: .screenShare, confidence: 0.9)
        let engine = SmartAutoFrameEngine()
        let localPath = try XCTUnwrap(engine.frame(range: range(0, 6), asset: source,
            format: .vertical, analysis: local).paths.first)
        let assistedPath = try XCTUnwrap(engine.frame(range: range(0, 6), asset: source,
            format: .vertical, analysis: local, visionHints: [vision]).paths.first)
        XCTAssertLessThan(localPath.keyframes[0].rect.x, assistedPath.keyframes[0].rect.x)
        XCTAssertEqual(assistedPath.keyframes[0].rect.x + assistedPath.keyframes[0].rect.width / 2,
                       0.5, accuracy: 0.001)
    }

    func testVisionFallbackRequiresOptInAndRejectsUntrustedFields() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../ClipHelmMediaTests/Fixtures/valid.mp4").standardizedFileURL
        let source = try await MediaProbe().probe(fileURL: fixture, displayName: "valid.mp4").asset
        let full = try MediaTimeRange(start: time(0), end: source.duration)
        let local = try analysis(source, kind: .unknown)
        let all = Data(#"{"data":[{"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":["response_format"]}]}"#.utf8)
        let gateway = MockOpenRouterGateway(catalogs: [.all: all, .transcription: Data(#"{"data":[]}"#.utf8)])
        let suite = "ClipHelm-Vision-\(UUID().uuidString)"
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
        let advisor = FramingVisionAdvisor()
        let skipped = try await advisor.classify(sourceURL: fixture, asset: source,
            configuration: config(false), range: full, analysis: local,
            registry: registry, gateway: gateway)
        XCTAssertTrue(skipped.isEmpty)
        let skippedRequests = await gateway.framingRequests
        XCTAssertTrue(skippedRequests.isEmpty)
        await gateway.setFramingResponses([Data(#"{"kind":"screenShare","confidence":0.9,"crop":"0,0,1,1"}"#.utf8)])
        do {
            _ = try await advisor.classify(sourceURL: fixture, asset: source,
                configuration: config(true), range: full, analysis: local,
                registry: registry, gateway: gateway)
            XCTFail("Extra model fields must be rejected")
        } catch let error as OpenRouterGatewayError {
            XCTAssertEqual(error, .invalidResponse)
        }
        await gateway.setFramingResponses([Data(#"{"kind":"screenShare","confidence":true}"#.utf8)])
        do {
            _ = try await advisor.classify(sourceURL: fixture, asset: source,
                configuration: config(true), range: full, analysis: local,
                registry: registry, gateway: gateway)
            XCTFail("Boolean confidence must be rejected")
        } catch let error as OpenRouterGatewayError {
            XCTAssertEqual(error, .invalidResponse)
        }
        await gateway.setFramingResponses([Data(#"{"kind":"screenShare","confidence":0.9}"#.utf8)])
        let hints = try await advisor.classify(sourceURL: fixture, asset: source,
            configuration: config(true), range: full, analysis: local,
            registry: registry, gateway: gateway)
        XCTAssertEqual(hints.map(\.kind), [.screenShare])
        XCTAssertEqual(hints.first?.range, full)
        let requests = await gateway.framingRequests
        XCTAssertEqual(requests.map(\.frameCount), [2, 2, 2])
    }
}
