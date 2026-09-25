import XCTest
import ClipHelmCore
import ClipHelmSources
import ClipHelmTranscription
import ClipHelmMoments
import ClipHelmOpenRouter
import ClipHelmMedia
@testable import ClipHelmProcessing

private struct UnusedBackend: TranscriptionBackend {
    let maximumChunkSeconds = 50
    func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        XCTFail("Silent media should not invoke transcription")
        return []
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessingProgress] = []
    func append(_ value: ProcessingProgress) { lock.lock(); values.append(value); lock.unlock() }
    var stages: [ProcessingStage] { lock.lock(); defer { lock.unlock() }; return values.map(\.stage) }
}

final class ProcessingTests: XCTestCase {
    func testProgressClampsFraction() {
        XCTAssertEqual(ProcessingProgress(stage: .analyzing, fraction: 2).fraction, 1)
    }

    func testSilentSourceRunsAllStagesAndRendersWithoutNetwork() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "silent-motion", withExtension: "mp4"))
        let ingestor = SourceIngestor()
        let source = try await ingestor.prepare(SourceDescriptor(localFile: file))
        let configuration = try ClipConfiguration(outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .natural,
            selectedLengths: [.seconds10to30], requestedClipCount: 1,
            soundMode: .mute, captionStyle: nil,
            smartEdit: SmartEditOptions(useVisionForTrickyShots: false,
                cutDeadAir: false, trimLongPauses: false, cleanFillers: false, keepDemos: false))
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = MockOpenRouterGateway()
        let registry = OpenRouterModelRegistry(gateway: gateway)
        let log = ProgressLog()
        let result = try await ProcessingCoordinator(ingestor: ingestor,
            momentEngine: MomentEngine(minimumQuality: 0)).run(prepared: source,
                expectedAsset: source.asset, configuration: configuration,
                cacheDirectory: directory.appending(path: "Cache"),
                outputDirectory: directory.appending(path: "Exports"),
                backend: UnusedBackend(), modelID: nil, gateway: gateway,
                registry: registry) { log.append($0) }
        XCTAssertEqual(result.clips.count, 1)
        XCTAssertFalse(result.transcript.hasMeaningfulSpeech)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.clips[0].previewURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.clips[0].finalURL.path))
        let final = try await MediaProbe().probe(fileURL: result.clips[0].finalURL,
                                                  displayName: "Final")
        XCTAssertEqual(final.asset.width, 1080)
        XCTAssertEqual(final.asset.height, 1920)
        if let inspectionPath = ProcessInfo.processInfo.environment["CLIPHELM_INSPECT_OUTPUT"] {
            try FileManager.default.copyItem(at: result.clips[0].finalURL,
                                             to: URL(fileURLWithPath: inspectionPath))
        }
        let order = ProcessingStage.allCases
        let observed = log.stages
        XCTAssertEqual(observed.first, .preparing)
        XCTAssertEqual(observed.last, .complete)
        XCTAssertEqual(Set(observed), Set(ProcessingStage.allCases))
        XCTAssertTrue(zip(observed, observed.dropFirst()).allSatisfy {
            order.firstIndex(of: $0.0)! <= order.firstIndex(of: $0.1)!
        })
        let proposalCount = await gateway.proposalRequests.count
        let framingCount = await gateway.framingRequests.count
        XCTAssertEqual(proposalCount, 0)
        XCTAssertEqual(framingCount, 0)
    }

    func testCancellationBeforeFinalRenderRemovesOnlyThisRunsFiles() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "silent-motion", withExtension: "mp4"))
        let ingestor = SourceIngestor()
        let source = try await ingestor.prepare(SourceDescriptor(localFile: file))
        let configuration = try ClipConfiguration(outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .natural,
            selectedLengths: [.seconds10to30], requestedClipCount: 1,
            soundMode: .mute, captionStyle: nil,
            smartEdit: SmartEditOptions(useVisionForTrickyShots: false,
                cutDeadAir: false, trimLongPauses: false, cleanFillers: false, keepDemos: false))
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "Exports")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appending(path: "already-accepted.mp4")
        try Data("keep".utf8).write(to: existing)
        let gateway = MockOpenRouterGateway()
        let registry = OpenRouterModelRegistry(gateway: gateway)
        let coordinator = ProcessingCoordinator(ingestor: ingestor,
            momentEngine: MomentEngine(minimumQuality: 0))
        let cancelledRun = Task {
            try await coordinator.run(prepared: source, expectedAsset: source.asset,
                configuration: configuration, cacheDirectory: directory.appending(path: "Cache"),
                outputDirectory: output, backend: UnusedBackend(), modelID: nil,
                gateway: gateway, registry: registry) { update in
                    if update.stage == .renderingFinals && update.fraction == 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
        }
        do {
            _ = try await cancelledRun.value
            XCTFail("Cancelled render must not return completed clips")
        } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path),
                       [existing.lastPathComponent])
        let recovered = try await coordinator.run(prepared: source, expectedAsset: source.asset,
            configuration: configuration, cacheDirectory: directory.appending(path: "Cache"),
            outputDirectory: output, backend: UnusedBackend(), modelID: nil,
            gateway: gateway, registry: registry)
        XCTAssertEqual(recovered.clips.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }
}
