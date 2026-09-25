import Foundation
import XCTest
import ClipHelmCore
import ClipHelmSources
@testable import ClipHelmApp

/// Opt-in live run of the app's own pipeline: a project created while its YouTube video
/// downloads, then Start. Uses the Keychain key and OpenRouter credits.
@MainActor
final class ClipPipelineLiveTests: XCTestCase {
    func testOptInStartTurnsADownloadingProjectIntoSavedClips() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["CLIPHELM_QA_PIPELINE_YOUTUBE_URL"] else {
            throw XCTSkip("Set CLIPHELM_QA_PIPELINE_YOUTUBE_URL to an authorized link; uses OpenRouter credits")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-pipeline-\(UUID().uuidString)")
        defer { if environment["CLIPHELM_QA_KEEP_OUTPUT"] == nil { try? FileManager.default.removeItem(at: root) } }
        let store = ProjectStore(rootURL: root)
        let pipeline = ClipPipeline()

        var draft = ProjectDraft()
        draft.title = "Pipeline QA"
        draft.sourceKind = .youtube
        draft.remoteURL = link
        draft.captionStyle = .pop
        draft.transcriptionModelID = environment["CLIPHELM_QA_TRANSCRIPTION_MODEL"]
        draft.momentModelID = environment["CLIPHELM_QA_MODEL"]
        pipeline.prepareDraftSource(try SourceDescriptor(remoteURL: link, youtube: true, authorized: true))
        // Create the project immediately, as the wizard allows while the download runs.
        let project = try store.save(draft: draft, mediaAsset: pipeline.draftSource?.prepared?.asset)
        pipeline.adoptDraftSource(for: project.id)
        let job = pipeline.job(for: project.id)
        let started = Date()
        pipeline.start(project, store: store)
        var seen: [PipelinePhase] = []
        while job.running {
            if let phase = job.currentPhase, seen.last != phase {
                seen.append(phase)
                print("QA_PIPELINE_PHASE \(phase.title) at \(Int(Date().timeIntervalSince(started)))s")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("QA_PIPELINE_SECONDS=\(Date().timeIntervalSince(started))")
        print("QA_PIPELINE_MESSAGE=\(job.message ?? "none")")
        XCTAssertTrue(job.finished, job.message ?? "Pipeline did not finish")
        XCTAssertEqual(seen.first, .download)
        let saved = try XCTUnwrap(store.projects.first { $0.id == project.id })
        XCTAssertNotNil(saved.mediaAsset)
        XCTAssertTrue(saved.transcript?.hasMeaningfulSpeech == true)
        XCTAssertFalse(saved.clips.isEmpty)
        let exports = try store.exportsDirectory(for: project.id)
        for clip in saved.clips {
            let seconds = Double(clip.spec.segments.reduce(0) { $0 + $1.sourceRange.durationMicroseconds }) / 1_000_000
            print("QA_PIPELINE_CLIP \(clip.title) | \(Int(seconds))s | viral=\(Int(((clip.viralPotential ?? 0) * 100).rounded()))% | \(exports.appending(path: clip.finalFileName).path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: exports.appending(path: clip.finalFileName).path))
            XCTAssertLessThanOrEqual(seconds, 121)
            XCTAssertNotNil(clip.spec.captionTrack)
        }
    }
}
