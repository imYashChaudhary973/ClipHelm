import Foundation
import AppKit
import SwiftUI
import XCTest
import ClipHelmCore
import ClipHelmSources
import ClipHelmAnalysis
import ClipHelmProcessing
@testable import ClipHelmApp

@MainActor
final class AppStateTests: XCTestCase {
    func testProjectRestoresWithoutPersistingRemoteURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-Test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        var draft = ProjectDraft()
        draft.title = "Interview Highlights"
        draft.sourceKind = .directURL
        draft.remoteURL = "https://media.example.com/video.mp4?token=private-value"
        draft.preset = .horizontal
        draft.lengths = [.seconds30to60, .minutes1to2]

        let media = try MediaAsset(id: AssetID(), displayName: "media.example.com",
                                   duration: MediaTime(microseconds: 12_000_000), width: 1920, height: 1080)
        let saved = try ProjectStore(rootURL: root).save(draft: draft, mediaAsset: media)
        let restored = ProjectStore(rootURL: root)
        XCTAssertEqual(restored.projects.count, 1)
        XCTAssertEqual(restored.projects.first?.id, saved.id)
        XCTAssertEqual(restored.projects.first?.sourceLabel, "media.example.com")
        XCTAssertEqual(restored.projects.first?.outputFormat, .horizontal)
        XCTAssertEqual(restored.projects.first?.mediaAsset, media)

        let file = root.appending(path: "\(saved.id.rawValue.uuidString).cliphelm/project.json")
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("private-value"))
        XCTAssertFalse(json.contains("video.mp4"))
    }

    func testCompletedClipsPersistAndRejectOutsideOutputPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-Exports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ProjectDraft()
        draft.sourceName = "source.mov"
        let asset = try MediaAsset(id: AssetID(), displayName: "source.mov",
            duration: MediaTime(microseconds: 12_000_000), width: 1920, height: 1080)
        let store = ProjectStore(rootURL: root)
        let project = try store.save(draft: draft, mediaAsset: asset)
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let source = PreparedSource(descriptor: try SourceDescriptor(localFile: URL(fileURLWithPath: "/tmp/source.mov")),
            fileURL: URL(fileURLWithPath: "/tmp/source.mov"), asset: asset, hasAudio: false)
        let proposal = try ClipProposal(assetID: asset.id, range: range,
            title: "Good moment", rationale: "Test", confidence: 0.8)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let analysis = try AnalysisResult(asset: asset,
            scenes: [Scene(assetID: asset.id, range: range)], signals: [],
            detections: [], subjectTracks: [],
            classifications: [ContentClassification(range: range, kind: .unknown, confidence: 0.1)])
        let directory = try store.exportsDirectory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = directory.appending(path: "preview.mp4")
        let final = directory.appending(path: "final.mp4")
        try Data([0]).write(to: preview)
        try Data([0]).write(to: final)
        let transcript = try Transcript(assetID: asset.id, segments: [])
        let good = ProcessingResult(source: source, transcript: transcript, analysis: analysis,
            clips: [ProcessedClip(proposal: proposal, spec: spec,
                                  previewURL: preview, finalURL: final)], explanation: nil)
        let outside = root.appending(path: "outside.mp4")
        try Data([0]).write(to: outside)
        let bad = ProcessingResult(source: source, transcript: transcript, analysis: analysis,
            clips: [ProcessedClip(proposal: proposal, spec: spec,
                                  previewURL: outside, finalURL: final)], explanation: nil)
        XCTAssertThrowsError(try store.saveProcessingResult(bad, for: project.id))
        XCTAssertTrue(store.projects[0].clips.isEmpty)
        try store.saveProcessingResult(good, for: project.id)
        let restored = try XCTUnwrap(ProjectStore(rootURL: root).projects.first)
        XCTAssertEqual(restored.clips.count, 1)
        XCTAssertEqual(restored.clips[0].spec, spec)
        XCTAssertEqual(restored.clips[0].title, "Good moment")
        XCTAssertFalse(restored.configuration.captionStyle != nil)

        var renamed = restored.clips[0]
        renamed.title = "Better title"
        try store.updateClip(renamed, for: project.id)
        XCTAssertEqual(ProjectStore(rootURL: root).projects[0].clips[0].title, "Better title")

        let newPreview = directory.appending(path: "new-preview.mp4")
        let newFinal = directory.appending(path: "new-final.mp4")
        try Data([1]).write(to: newPreview)
        try Data([2]).write(to: newFinal)
        renamed.previewFileName = newPreview.lastPathComponent
        renamed.finalFileName = newFinal.lastPathComponent
        try store.updateClip(renamed, for: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(ProjectStore(rootURL: root).projects[0].clips[0].finalFileName, "new-final.mp4")

        try store.deleteClip(spec.clipID, from: project.id)
        XCTAssertTrue(ProjectStore(rootURL: root).projects[0].clips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPreview.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFinal.path))
    }

    func testVersionThreeClipTitleMigratesFromProposal() throws {
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0),
                                       end: MediaTime(microseconds: 1_000_000))
        let asset = try MediaAsset(id: AssetID(), displayName: "source.mp4",
                                   duration: range.end, width: 1920, height: 1080)
        let proposal = try ClipProposal(assetID: asset.id, range: range,
            title: "Original title", rationale: "Test", confidence: 0.8)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .horizontal,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let clip = ProjectClipRecord(ProcessedClip(proposal: proposal, spec: spec,
            previewURL: URL(fileURLWithPath: "/tmp/preview.mp4"),
            finalURL: URL(fileURLWithPath: "/tmp/final.mp4")))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        json.removeValue(forKey: "title")
        json.removeValue(forKey: "trimRange")
        let migrated = try JSONDecoder().decode(ProjectClipRecord.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.title, proposal.title)
        try migrated.validate(for: asset)
    }

    func testEveryGuidedChoicePersistsAsConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-Configuration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ProjectDraft()
        draft.sourceName = "lesson.mov"
        draft.preset = .horizontal
        draft.resolution = .uhd4k
        draft.framingMode = .blurred
        draft.smartEdit = SmartEditOptions(useVisionForTrickyShots: true, cutDeadAir: false,
                                           trimLongPauses: true, cleanFillers: true, keepDemos: false)
        draft.pacingMode = .fast
        draft.lengths = [.minutes2to5, .seconds10to30]
        draft.countMode = .custom
        draft.requestedClipCount = 7
        draft.soundMode = .normalize
        draft.captionStyle = .neonHeadline
        draft.captionWordByWord = true
        draft.captionBlurIn = true

        let saved = try ProjectStore(rootURL: root).save(draft: draft)
        let restored = try XCTUnwrap(ProjectStore(rootURL: root).projects.first)
        XCTAssertEqual(restored.configuration, saved.configuration)
        XCTAssertEqual(restored.configuration.outputFormat.width, 3840)
        XCTAssertEqual(restored.configuration.outputFormat.height, 2160)
        XCTAssertEqual(restored.configuration.outputFormat, try draft.configuration.outputFormat)
        XCTAssertEqual(restored.configuration.selectedLengths, [.seconds10to30, .minutes2to5])
        XCTAssertEqual(restored.configuration.requestedClipCount, 7)
        XCTAssertEqual(restored.configuration.soundMode, .normalize)
        XCTAssertTrue(restored.configuration.smartEdit.useVisionForTrickyShots)
        XCTAssertTrue(restored.configuration.captionWordByWord)
        XCTAssertTrue(restored.configuration.captionBlurIn)
        let manifest = root.appending(path: "\(saved.id.rawValue.uuidString).cliphelm/project.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertNotNil(json["configuration"])
        XCTAssertNil(json["outputFormat"])
    }

    func testVersionOneProjectOpensWithConfigurationDefaults() throws {
        var draft = ProjectDraft()
        draft.sourceName = "old.mov"
        let record = try ProjectRecord(draft: draft)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["schemaVersion"] = 1
        json["outputFormat"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OutputFormat.vertical))
        json["framingMode"] = FramingMode.smartAuto.rawValue
        json["selectedLengths"] = [ClipLength.minutes1to2.rawValue]
        json["captionStyle"] = CaptionStyle.pop.rawValue
        json.removeValue(forKey: "configuration")
        let restored = try JSONDecoder().decode(ProjectRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.schemaVersion, ProjectRecord.currentVersion)
        XCTAssertEqual(restored.configuration.selectedLengths, [.minutes1to2])
        XCTAssertNil(restored.configuration.requestedClipCount)
        XCTAssertEqual(restored.configuration.soundMode, .source)
    }

    func testNavigationRestores() throws {
        let suite = "ClipHelm-Test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let selectedID = UUID()
        let first = NavigationState(defaults: defaults)
        first.openProject(selectedID)
        first.inspectorVisible = false

        let restored = NavigationState(defaults: defaults)
        XCTAssertEqual(restored.route, .workspace)
        XCTAssertEqual(restored.selectedProjectID, selectedID)
        XCTAssertFalse(restored.inspectorVisible)
    }

    func testDraftRestoresPreferencesWithoutSourceAccess() throws {
        var draft = ProjectDraft()
        draft.title = "A long interview"
        draft.sourceKind = .youtube
        draft.remoteURL = "https://youtube.com/watch?v=private"
        draft.sourceName = "private.mov"
        draft.preset = .horizontal
        draft.lengths = [.minutes2to5]
        draft.pacingMode = .tight
        draft.countMode = .custom
        draft.requestedClipCount = 12
        draft.soundMode = .normalize
        draft.captionBlurIn = true

        let data = try JSONEncoder().encode(draft)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("private"))
        let restored = try JSONDecoder().decode(ProjectDraft.self, from: data)
        XCTAssertEqual(restored.title, "A long interview")
        XCTAssertEqual(restored.preset, .horizontal)
        XCTAssertEqual(restored.lengths, [.minutes2to5])
        XCTAssertEqual(restored.pacingMode, .tight)
        XCTAssertEqual(restored.countMode, .custom)
        XCTAssertEqual(restored.requestedClipCount, 12)
        XCTAssertEqual(restored.soundMode, .normalize)
        XCTAssertTrue(restored.captionBlurIn)
        XCTAssertNil(restored.sourceLabel)
    }

    func testShellLaysOutAtCompactAndWideSizes() throws {
        let suite = "ClipHelm-Layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-Layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let navigation = NavigationState(defaults: defaults)
        let store = ProjectStore(rootURL: root)
        let shell = AppShell(navigation: navigation, store: store)
        let hosting = NSHostingView(rootView: shell)
        for size in [NSSize(width: 780, height: 560), NSSize(width: 1440, height: 900)] {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(hosting.fittingSize.width.isFinite)
            XCTAssertTrue(hosting.fittingSize.height.isFinite)
        }
        navigation.startProject()
        for step in WizardStep.allCases {
            navigation.step = step
            for size in [NSSize(width: 780, height: 560), NSSize(width: 1440, height: 900)] {
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                XCTAssertTrue(hosting.fittingSize.width.isFinite, "\(step.title) at \(size)")
                XCTAssertTrue(hosting.fittingSize.height.isFinite, "\(step.title) at \(size)")
            }
        }

        var draft = ProjectDraft()
        draft.sourceName = "layout.mp4"
        let asset = try MediaAsset(id: AssetID(), displayName: "layout.mp4",
            duration: MediaTime(microseconds: 1_000_000), width: 64, height: 64)
        let project = try store.save(draft: draft, mediaAsset: asset)
        let word = try TranscriptWord(text: "Hello",
            range: MediaTimeRange(start: MediaTime(microseconds: 100_000),
                                  end: MediaTime(microseconds: 300_000)))
        try store.saveTranscript(try Transcript(assetID: asset.id, words: [word]), for: project.id)
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
        let proposal = try ClipProposal(assetID: asset.id, range: range,
            title: "A useful moment", rationale: "Layout test", confidence: 0.8)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let directory = try store.exportsDirectory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        let preview = directory.appending(path: "layout-preview.mp4")
        let final = directory.appending(path: "layout.mp4")
        try FileManager.default.copyItem(at: fixture, to: preview)
        try FileManager.default.copyItem(at: fixture, to: final)
        let source = PreparedSource(descriptor: try SourceDescriptor(localFile: fixture),
            fileURL: fixture, asset: asset, hasAudio: false)
        let analysis = try AnalysisResult(asset: asset,
            scenes: [Scene(assetID: asset.id, range: range)], signals: [],
            detections: [], subjectTracks: [],
            classifications: [ContentClassification(range: range, kind: .unknown, confidence: 0.1)])
        try store.saveProcessingResult(ProcessingResult(source: source,
            transcript: try Transcript(assetID: asset.id, words: [word]), analysis: analysis,
            clips: [ProcessedClip(proposal: proposal, spec: spec,
                                  previewURL: preview, finalURL: final)], explanation: nil), for: project.id)
        navigation.openProject(project.id.rawValue)
        for size in [NSSize(width: 780, height: 560), NSSize(width: 1440, height: 900)] {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(hosting.fittingSize.width.isFinite)
            XCTAssertTrue(hosting.fittingSize.height.isFinite)
        }
    }

    func testSilentTranscriptPersistsAndTurnsCaptionsOff() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-Transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ProjectDraft()
        draft.sourceName = "quiet.mp4"
        let asset = try MediaAsset(id: AssetID(), displayName: "quiet.mp4",
            duration: MediaTime(microseconds: 1_000_000), width: 64, height: 64)
        let store = ProjectStore(rootURL: root)
        let project = try store.save(draft: draft, mediaAsset: asset)
        XCTAssertEqual(project.captionStyle, .pop)
        let empty = try Transcript(assetID: asset.id, segments: [])
        try store.saveTranscript(empty, for: project.id)
        let restored = try XCTUnwrap(ProjectStore(rootURL: root).projects.first)
        XCTAssertNil(restored.captionStyle)
        XCTAssertFalse(restored.configuration.captionWordByWord)
        XCTAssertFalse(restored.configuration.captionBlurIn)
        XCTAssertEqual(restored.transcript, empty)
        let manifest = root.appending(path: "\(project.id.rawValue.uuidString).cliphelm/project.json")
        let mode = try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}
