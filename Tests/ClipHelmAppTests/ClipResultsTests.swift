import Foundation
import XCTest
import ClipHelmCore
import ClipHelmSources
import ClipHelmProcessing
@testable import ClipHelmApp

final class ClipResultsTests: XCTestCase {
    func testBatchExportRejectsInsufficientDiskSpaceWithoutPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-full-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "ProjectExports")
        let destination = root.appending(path: "Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let clip = source.appending(path: "clip.mp4")
        try Data("video".utf8).write(to: clip)
        let exporter = ClipExporter(availableBytes: { _ in 0 })
        do {
            _ = try await exporter.export([ClipExportItem(title: "Clip", fileURL: clip)],
                                          from: source, to: destination)
            XCTFail("Export must reject a full destination")
        } catch let error as ClipExportError {
            guard case .insufficientDiskSpace = error else { XCTFail("Wrong error: \(error)"); return }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testBatchExportSanitizesNamesAvoidsOverwriteAndRollsBackOnError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "ProjectExports")
        let destination = root.appending(path: "Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let first = source.appending(path: "first.mp4")
        let second = source.appending(path: "second.mp4")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let existing = destination.appending(path: "My-Clip.mp4")
        try Data("existing".utf8).write(to: existing)
        let items = [ClipExportItem(title: "My/Clip", fileURL: first),
                     ClipExportItem(title: "My:Clip", fileURL: second)]
        let exported = try await ClipExporter().export(items, from: source, to: destination)
        XCTAssertEqual(exported.map(\.lastPathComponent), ["My-Clip-2.mp4", "My-Clip-3.mp4"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: exported[0]), Data("first".utf8))

        let outside = root.appending(path: "outside.mp4")
        try Data("outside".utf8).write(to: outside)
        let before = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        do {
            _ = try await ClipExporter().export([items[0], ClipExportItem(title: "Outside", fileURL: outside)],
                                                from: source, to: destination)
            XCTFail("Export should reject a file outside the project")
        } catch is ClipExportError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), before)
        let link = source.appending(path: "linked.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try await ClipExporter().export([ClipExportItem(title: "Linked", fileURL: link)],
                                                from: source, to: destination)
            XCTFail("Export should reject a symlink outside the project")
        } catch is ClipExportError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), before)
    }

    func testRevisionKeepsClipIDAndAppliesTrimPacingAndManualFocus() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "mp4"))
        let prepared = try await SourceIngestor().prepare(SourceDescriptor(localFile: file))
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: prepared.asset.duration)
        let proposal = try ClipProposal(assetID: prepared.asset.id, range: range,
            title: "Demo", rationale: "Test", confidence: 0.8)
        let clipID = ClipID()
        let spec = try ClipHelmEditSpec(clipID: clipID, sourceAssetID: prepared.asset.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .balanced,
            soundMode: .mute, captionStyle: nil)
        let clip = ProjectClipRecord(ProcessedClip(proposal: proposal, spec: spec,
            previewURL: URL(fileURLWithPath: "/tmp/preview.mp4"),
            finalURL: URL(fileURLWithPath: "/tmp/final.mp4")))
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-revision-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let trimmed = try MediaTimeRange(start: MediaTime(microseconds: 100_000),
            end: MediaTime(microseconds: min(800_000, range.end.microseconds)))
        let draft = ProjectDraft()
        let options = ClipRevisionOptions(trimRange: trimmed, framing: .fullFrame,
            pacing: .fast, captionStyle: nil, focusX: 1, focusY: 0.5)
        let revised = try await ClipRevisionPlanner().revise(clip, source: prepared,
            transcript: nil, configuration: try draft.configuration,
            cacheDirectory: root, options: options)
        XCTAssertEqual(revised.clipID, clipID)
        XCTAssertEqual(revised.framingMode, .fullFrame)
        XCTAssertEqual(revised.pacingMode, .fast)
        XCTAssertTrue(revised.segments.allSatisfy {
            trimmed.start <= $0.sourceRange.start && $0.sourceRange.end <= trimmed.end
        })
        XCTAssertFalse(revised.cropPaths.isEmpty)
        XCTAssertGreaterThan(revised.cropPaths[0].keyframes[0].rect.x, 0)

        let word = try TranscriptWord(text: "Hello", range: trimmed)
        let transcript = try Transcript(assetID: prepared.asset.id, words: [word])
        var focused = clip
        focused.spec = revised
        focused.trimRange = trimmed
        let captionOptions = ClipRevisionOptions(trimRange: trimmed, framing: .fullFrame,
            pacing: .fast, captionStyle: .pop, focusX: 1, focusY: 0.5)
        let captioned = try await ClipRevisionPlanner().revise(focused, source: prepared,
            transcript: transcript, configuration: try draft.configuration,
            cacheDirectory: root, options: captionOptions)
        XCTAssertEqual(captioned.segments, revised.segments)
        XCTAssertEqual(captioned.cropPaths, revised.cropPaths)
        XCTAssertEqual(captioned.layout, revised.layout)
        XCTAssertEqual(captioned.captionStyle, .pop)
        XCTAssertEqual(captioned.captionTrack?.cues.map(\.text), ["Hello"])
    }
}
