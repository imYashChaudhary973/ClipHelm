import Foundation
import XCTest
import ClipHelmCore
import ClipHelmMedia
@testable import ClipHelmAnalysis

final class AnalysisTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAnalysisTimelineAndVersionedCache() async throws {
        let source = try fixture("valid")
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Fixture").asset
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectory = root.appending(path: "Cache")

        let first = try await AnalysisEngine().analyze(sourceURL: source, asset: asset,
                                                       cacheDirectory: cacheDirectory)
        XCTAssertEqual(first.scenes.first?.range.start.microseconds, 0)
        XCTAssertEqual(first.scenes.last?.range.end, asset.duration)
        XCTAssertTrue(first.signals.allSatisfy { $0.range.end <= asset.duration })
        XCTAssertTrue(first.classifications.allSatisfy { $0.range.end <= asset.duration })
        XCTAssertFalse(first.signals.contains { $0.kind == .audioActivity })

        let cacheFile = cacheDirectory.appending(path: "analysis-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let second = try await AnalysisEngine().analyze(sourceURL: source, asset: asset,
                                                        cacheDirectory: cacheDirectory)
        XCTAssertEqual(second, first)

        let fingerprint = try await AnalysisCache().fingerprint(sourceURL: source)
        let stale = try await AnalysisCache().load(directory: cacheDirectory,
            fingerprint: "stale-\(fingerprint)", asset: asset)
        XCTAssertNil(stale)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any])
        envelope["version"] = 999
        try JSONSerialization.data(withJSONObject: envelope).write(to: cacheFile, options: .atomic)
        let futureVersion = try await AnalysisCache().load(directory: cacheDirectory,
            fingerprint: fingerprint, asset: asset)
        XCTAssertNil(futureVersion)
    }

    func testAudioActivityAndPossiblePauses() async throws {
        let tone = try fixture("tone3")
        let toneMetadata = try await MediaProbe().probe(fileURL: tone, displayName: "Tone")
        let toneSignals = try await AudioActivityDetector().analyze(sourceURL: tone,
            asset: toneMetadata.asset, hasAudio: toneMetadata.hasAudio)
        XCTAssertFalse(toneSignals.isEmpty)
        XCTAssertTrue(toneSignals.contains { $0.strength > 0.075 })
        XCTAssertTrue(toneSignals.allSatisfy { $0.range.end <= toneMetadata.asset.duration })

        let silent = try fixture("silent-audio")
        let silentMetadata = try await MediaProbe().probe(fileURL: silent, displayName: "Silent")
        let quiet = try await AudioActivityDetector().analyze(sourceURL: silent,
            asset: silentMetadata.asset, hasAudio: silentMetadata.hasAudio)
        let pauses = try PauseDetector().detect(activity: quiet)
        XCTAssertFalse(pauses.isEmpty)
        XCTAssertTrue(pauses.allSatisfy { $0.kind == .pause && $0.confidence < 1 })
    }

    func testSceneSubjectAndContentEvidence() throws {
        let asset = try MediaAsset(id: AssetID(), displayName: "Synthetic",
            duration: MediaTime(microseconds: 3_000_000), width: 1920, height: 1080)
        let rectangle = try NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.3)
        let times = try [500_000, 1_500_000, 2_500_000].map(MediaTime.init(microseconds:))
        let detections = try times.map {
            try SubjectDetection(time: $0, bounds: rectangle, confidence: 0.8, isFace: true)
        }
        let samples = times.enumerated().map { index, time in
            VideoSample(time: time, motion: 0.1, cut: index == 1 ? 0.8 : 0,
                        edgeDensity: 0.2, textDensity: 0, screenScore: 0,
                        detections: [detections[index]], subjectsReliable: true,
                        textReliable: true)
        }
        let (scenes, changes) = try SceneDetector().detect(asset: asset, samples: samples)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].range.end, scenes[1].range.start)
        XCTAssertEqual(changes.map(\.kind), [.sceneChange])
        let tracks = try SubjectTracker().track(assetID: asset.id, detections: detections)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].observations.count, 3)
        let labels = try ContentClassifier().classify(asset: asset, samples: samples, audio: [])
        XCTAssertEqual(labels.first?.kind, .talkingHead)
        XCTAssertLessThan(labels[0].confidence, 0.8)
    }

    func testCancelStopsDetachedAnalysisWork() async throws {
        let job = Task {
            try await runAnalysisOffMain { () async throws -> Int in
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Cancellation must reach the worker task")
        } catch is CancellationError { }
    }
}
