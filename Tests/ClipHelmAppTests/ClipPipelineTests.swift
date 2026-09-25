import Foundation
import XCTest
import ClipHelmCore
import ClipHelmProcessing
@testable import ClipHelmApp

@MainActor
final class ClipPipelineTests: XCTestCase {
    func testPhasesAdvanceInOrderAndRenderSpansPreviewsAndFinals() {
        let job = ClipJob(projectID: ProjectID())
        job.begin()
        job.set(.download, .done(detail: "Downloaded"))
        job.apply(ProcessingProgress(stage: .transcribing, fraction: 0.5))
        XCTAssertEqual(job.currentPhase, .transcribe)
        XCTAssertEqual(job.state(of: .transcribe), .running(fraction: 0.5, detail: nil))

        job.apply(ProcessingProgress(stage: .findingMoments, fraction: 0.25, detail: nil))
        XCTAssertEqual(job.state(of: .transcribe), .done(detail: nil))
        XCTAssertEqual(job.state(of: .analyze), .done(detail: nil))
        XCTAssertEqual(job.currentPhase, .findMoments)

        job.apply(ProcessingProgress(stage: .renderingPreviews, fraction: 1))
        XCTAssertEqual(job.state(of: .render), .running(fraction: 0.3, detail: nil))
        job.apply(ProcessingProgress(stage: .renderingFinals, fraction: 0.5, detail: "Final clip 2 of 3"))
        guard case .running(let fraction?, let detail) = job.state(of: .render) else {
            return XCTFail("Render should be running")
        }
        XCTAssertEqual(fraction, 0.65, accuracy: 1e-9)
        XCTAssertEqual(detail, "Final clip 2 of 3")
        XCTAssertEqual(job.state(of: .frame), .done(detail: nil))

        job.finish(clipCount: 3, explanation: nil)
        XCTAssertTrue(job.finished)
        XCTAssertFalse(job.running)
        XCTAssertEqual(job.overallFraction, 1)
        XCTAssertEqual(job.state(of: .render), .done(detail: "3 clips ready"))
    }

    func testFailureMarksTheRunningPhaseAndKeepsTheMessage() {
        let job = ClipJob(projectID: ProjectID())
        job.begin()
        job.apply(ProcessingProgress(stage: .analyzing, fraction: 0.4))
        job.fail("OpenRouter credits are insufficient.")
        XCTAssertEqual(job.state(of: .analyze), .failed)
        XCTAssertTrue(job.failed)
        XCTAssertEqual(job.message, "OpenRouter credits are insufficient.")
        job.begin()
        XCTAssertFalse(job.failed)
        XCTAssertNil(job.message)
        XCTAssertEqual(job.state(of: .analyze), .pending)
    }

    func testSavedTranscriptSkipsTheTranscribePhase() {
        let job = ClipJob(projectID: ProjectID())
        job.begin()
        job.apply(ProcessingProgress(stage: .transcribing, fraction: 1, detail: "Using saved transcript"))
        XCTAssertEqual(job.state(of: .transcribe), .done(detail: "Using saved transcript"))
    }

    func testTranscriptionChoiceResolvesOnDeviceAndRecommendedDefaults() {
        let pipeline = ClipPipeline()
        XCTAssertNil(pipeline.resolvedTranscriptionModelID(ClipPipeline.onDeviceTranscription))
        XCTAssertEqual(pipeline.resolvedTranscriptionModelID("deepgram/nova-3"), "deepgram/nova-3")
        // With no catalog loaded there is no recommendation, so the default is on-device.
        XCTAssertNil(pipeline.resolvedTranscriptionModelID(nil))
    }

    func testModelChoicesPersistAndOlderDraftsStillDecode() throws {
        var draft = ProjectDraft()
        draft.transcriptionModelID = "nvidia/parakeet-tdt-0.6b-v3"
        draft.momentModelID = "z-ai/glm-5.3-flash"
        let decoded = try JSONDecoder().decode(ProjectDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.transcriptionModelID, "nvidia/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(decoded.momentModelID, "z-ai/glm-5.3-flash")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectDraft()))
            as? [String: Any])
        legacy.removeValue(forKey: "transcriptionModelID")
        legacy.removeValue(forKey: "momentModelID")
        let old = try JSONDecoder().decode(ProjectDraft.self,
                                           from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.transcriptionModelID)
        XCTAssertNil(old.momentModelID)

        draft.sourceKind = .youtube
        draft.remoteURL = "https://www.youtube.com/watch?v=abcdefghijk"
        let record = try ProjectRecord(draft: draft)
        let restored = try JSONDecoder().decode(ProjectRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.transcriptionModelID, "nvidia/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(restored.momentModelID, "z-ai/glm-5.3-flash")
        XCTAssertNil(restored.mediaAsset)
    }

    func testAttachingMediaToAProjectCreatedDuringDownload() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        var draft = ProjectDraft()
        draft.sourceKind = .youtube
        draft.remoteURL = "https://www.youtube.com/watch?v=abcdefghijk"
        let project = try store.save(draft: draft)
        let asset = try MediaAsset(id: AssetID(), displayName: "youtube.com",
            duration: MediaTime(microseconds: 60_000_000), width: 1920, height: 1080)
        try store.attachMediaAsset(asset, to: project.id)
        XCTAssertEqual(store.projects.first?.mediaAsset, asset)
        // Attaching the same asset again is harmless; a different one is refused.
        try store.attachMediaAsset(asset, to: project.id)
        let other = try MediaAsset(id: AssetID(), displayName: "youtube.com",
            duration: MediaTime(microseconds: 30_000_000), width: 1280, height: 720)
        XCTAssertThrowsError(try store.attachMediaAsset(other, to: project.id))
        let reloaded = ProjectStore(rootURL: root)
        XCTAssertEqual(reloaded.projects.first?.mediaAsset, asset)
    }
}
