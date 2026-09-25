import XCTest
import Darwin
import ClipHelmCore
import ClipHelmSecurity
import ClipHelmSources
import ClipHelmTranscription
import ClipHelmOpenRouter
import ClipHelmMedia
@testable import ClipHelmProcessing

private final class StageTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = ProcessingStage.preparing
    private var started = Date()

    func observe(_ next: ProcessingStage) {
        lock.lock()
        defer { lock.unlock() }
        guard next != stage else { return }
        print("QA_E2E_STAGE \(stage.rawValue)=\(Date().timeIntervalSince(started))")
        stage = next
        started = Date()
    }
}

/// Opt-in live run of the quick flow: YouTube link → download → on-device transcript →
/// OpenRouter moment discovery → captioned vertical clips. Uses the Keychain key and API credits.
final class YouTubeEndToEndTests: XCTestCase {
    func testOptInYouTubeLinkBecomesCaptionedClips() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["CLIPHELM_QA_E2E_YOUTUBE_URL"] else {
            throw XCTSkip("Set CLIPHELM_QA_E2E_YOUTUBE_URL to an authorized YouTube link; uses OpenRouter credits")
        }
        let output = environment["CLIPHELM_QA_E2E_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "ClipHelm-e2e-\(UUID().uuidString)")
        let started = Date()
        let ingestor = SourceIngestor(youtubeExecutable: environment["CLIPHELM_QA_YTDLP_BIN"].map(URL.init(fileURLWithPath:)))
        let source = try await ingestor.prepare(SourceDescriptor(remoteURL: link, youtube: true, authorized: true))
        print("QA_E2E_TITLE=\(source.title ?? "none")")
        print("QA_E2E_SOURCE=\(source.asset.width)x\(source.asset.height) \(Double(source.asset.duration.microseconds) / 1_000_000)s")
        print("QA_E2E_DOWNLOAD_SECONDS=\(Date().timeIntervalSince(started))")

        let gateway = LiveOpenRouterGateway(secrets: OpenRouterSecretVault())
        let registry = OpenRouterModelRegistry(gateway: gateway,
            defaultsSuiteName: "ClipHelm-e2e-\(UUID().uuidString)")
        try await registry.refresh()
        let recommended = await registry.preferredModel(for: .clipDiscovery)
        let model = try XCTUnwrap(environment["CLIPHELM_QA_MODEL"] ?? recommended?.id)
        print("QA_E2E_MODEL=\(model)")
        let configuration = try ClipConfiguration(outputFormat: .vertical, framingMode: .smartAuto,
            pacingMode: .balanced, selectedLengths: [.seconds30to60], requestedClipCount: 3,
            soundMode: .source, captionStyle: .pop,
            smartEdit: SmartEditOptions(useVisionForTrickyShots: false, cutDeadAir: true,
                trimLongPauses: true, cleanFillers: false, keepDemos: true))
        let timer = StageTimer()
        let processed = Date()
        let result = try await ProcessingCoordinator(ingestor: ingestor).run(prepared: source,
            expectedAsset: source.asset, configuration: configuration,
            cacheDirectory: output.appending(path: "Cache"), outputDirectory: output.appending(path: "Exports"),
            backend: AppleSpeechBackend(), modelID: model, gateway: gateway, registry: registry) { timer.observe($0.stage) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("QA_E2E_PROCESS_SECONDS=\(Date().timeIntervalSince(processed))")
        print("QA_E2E_PEAK_RSS_MB=\(usage.ru_maxrss / 1_048_576)")
        print("QA_E2E_WORDS=\(result.transcript.words.count)")
        print("QA_E2E_EXPLANATION=\(result.explanation ?? "none")")
        XCTAssertTrue(result.transcript.hasMeaningfulSpeech)
        XCTAssertFalse(result.clips.isEmpty)
        for clip in result.clips {
            let final = try await MediaProbe().probe(fileURL: clip.finalURL, displayName: "Final")
            print("QA_E2E_CLIP \(clip.proposal.title) | \(clip.proposal.range.start.microseconds / 1_000_000)s–\(clip.proposal.range.end.microseconds / 1_000_000)s | \(final.asset.width)x\(final.asset.height) | cues=\(clip.spec.captionTrack?.cues.count ?? 0) | \(clip.finalURL.path)")
            XCTAssertEqual(final.asset.width, 1080)
            XCTAssertEqual(final.asset.height, 1920)
            XCTAssertTrue(final.hasAudio)
            XCTAssertGreaterThan(clip.spec.captionTrack?.cues.count ?? 0, 0)
        }
    }
}
