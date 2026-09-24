import Foundation
import AppKit
import SwiftUI
import XCTest
import ClipHelmCore
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

        let data = try JSONEncoder().encode(draft)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("private"))
        let restored = try JSONDecoder().decode(ProjectDraft.self, from: data)
        XCTAssertEqual(restored.title, "A long interview")
        XCTAssertEqual(restored.preset, .horizontal)
        XCTAssertEqual(restored.lengths, [.minutes2to5])
        XCTAssertNil(restored.sourceLabel)
    }

    func testShellLaysOutAtCompactAndWideSizes() throws {
        let suite = "ClipHelm-Layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-Layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = NavigationState(defaults: defaults)
        let shell = AppShell(navigation: navigation, store: ProjectStore(rootURL: root))
        let hosting = NSHostingView(rootView: shell)
        for size in [NSSize(width: 780, height: 560), NSSize(width: 1440, height: 900)] {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(hosting.fittingSize.width.isFinite)
            XCTAssertTrue(hosting.fittingSize.height.isFinite)
        }
        navigation.startProject()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(hosting.fittingSize.width.isFinite)
    }
}
