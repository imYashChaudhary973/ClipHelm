import Foundation
import SwiftUI
import ClipHelmCore

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case local = "Local video"
    case directURL = "Direct video URL"
    case youtube = "YouTube URL"

    var id: String { rawValue }
}

enum CanvasPreset: String, Codable, CaseIterable, Identifiable {
    case vertical = "9:16 Vertical"
    case horizontal = "16:9 Horizontal"

    var id: String { rawValue }
    var format: OutputFormat { self == .vertical ? .vertical : .horizontal }
}

struct ProjectDraft: Codable, Equatable {
    var title = "Untitled Clip Project"
    var sourceKind: SourceKind = .local
    var sourceName = ""
    var remoteURL = ""
    var preset: CanvasPreset = .vertical
    var framingMode: FramingMode = .smartAuto
    var lengths: Set<ClipLength> = []
    var captionsEnabled = true
    var captionStyle: CaptionStyle = .pop

    init() { }

    // Source names and URLs are intentionally omitted: access must be re-granted after relaunch.
    private enum CodingKeys: String, CodingKey {
        case title, sourceKind, preset, framingMode, lengths, captionsEnabled, captionStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind)
        preset = try c.decode(CanvasPreset.self, forKey: .preset)
        framingMode = try c.decode(FramingMode.self, forKey: .framingMode)
        lengths = try c.decode(Set<ClipLength>.self, forKey: .lengths)
        captionsEnabled = try c.decode(Bool.self, forKey: .captionsEnabled)
        captionStyle = try c.decode(CaptionStyle.self, forKey: .captionStyle)
    }

    var sourceLabel: String? {
        switch sourceKind {
        case .local:
            return sourceName.isEmpty ? nil : sourceName
        case .directURL, .youtube:
            guard let url = URLComponents(string: remoteURL),
                  url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            if sourceKind == .youtube,
               !["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) {
                return nil
            }
            return host
        }
    }
}

struct ProjectRecord: Codable, Identifiable {
    static let currentVersion = 1

    let schemaVersion: Int
    let id: ProjectID
    let title: String
    let createdAt: Date
    let sourceKind: SourceKind
    let sourceLabel: String
    let outputFormat: OutputFormat
    let framingMode: FramingMode
    let selectedLengths: [ClipLength]
    var captionStyle: CaptionStyle?
    let mediaAsset: MediaAsset?
    var transcript: Transcript?

    init(draft: ProjectDraft, mediaAsset: MediaAsset? = nil,
         id: ProjectID = ProjectID(), createdAt: Date = .now) throws {
        guard let sourceLabel = draft.sourceLabel,
              !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.title.count <= 200, sourceLabel.count <= 255 else {
            throw ModelError.invalid("ProjectDraft")
        }
        schemaVersion = Self.currentVersion
        self.id = id
        title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        sourceKind = draft.sourceKind
        self.sourceLabel = sourceLabel
        outputFormat = draft.preset.format
        framingMode = draft.framingMode
        selectedLengths = ClipLength.allCases.filter { draft.lengths.contains($0) }
        captionStyle = draft.captionsEnabled ? draft.captionStyle : nil
        self.mediaAsset = mediaAsset
        transcript = nil
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var loadError: String?
    private let rootURL: URL?

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appending(path: "ClipHelm/Projects", directoryHint: .isDirectory)
        }
        load()
    }

    private func load() {
        guard let rootURL else {
            loadError = "Projects are unavailable on this Mac."
            return
        }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        do {
            let packages = try FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "cliphelm" }
            var loaded: [ProjectRecord] = []
            for package in packages {
                do {
                    let manifest = package.appending(path: "project.json")
                    let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard (1...25_000_000).contains(size) else {
                        throw ModelError.invalid("Project manifest size")
                    }
                    let data = try Data(contentsOf: manifest)
                    let record = try JSONDecoder().decode(ProjectRecord.self, from: data)
                    guard record.schemaVersion == ProjectRecord.currentVersion,
                          package.deletingPathExtension().lastPathComponent == record.id.rawValue.uuidString,
                          !record.title.isEmpty, record.title.count <= 200,
                          !record.sourceLabel.isEmpty, record.sourceLabel.count <= 255,
                          record.transcript.map({ transcript in
                              guard let asset = record.mediaAsset else { return false }
                              return transcript.assetID == asset.id &&
                                  transcript.words.allSatisfy { $0.range.end <= asset.duration }
                          }) ?? true else {
                        throw ModelError.invalid("ProjectRecord")
                    }
                    loaded.append(record)
                } catch {
                    loadError = "Some projects could not be opened. Their files were left untouched."
                }
            }
            projects = loaded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            loadError = "Projects could not be loaded. Their files were left untouched."
        }
    }

    func save(draft: ProjectDraft, mediaAsset: MediaAsset? = nil) throws -> ProjectRecord {
        guard let rootURL else { throw ModelError.invalid("Project location") }
        let record = try ProjectRecord(draft: draft, mediaAsset: mediaAsset)
        let package = rootURL.appending(path: "\(record.id.rawValue.uuidString).cliphelm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: package.path)
        let data = try JSONEncoder().encode(record)
        try data.write(to: package.appending(path: "project.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: package.appending(path: "project.json").path)
        projects.insert(record, at: 0)
        return record
    }

    func saveTranscript(_ transcript: Transcript, for projectID: ProjectID) throws {
        guard let rootURL, let index = projects.firstIndex(where: { $0.id == projectID }),
              let asset = projects[index].mediaAsset, transcript.assetID == asset.id,
              transcript.words.allSatisfy({ $0.range.end <= asset.duration }) else {
            throw ModelError.invalid("Transcript project mismatch")
        }
        var updated = projects[index]
        updated.transcript = transcript
        if !transcript.hasMeaningfulSpeech { updated.captionStyle = nil }
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 25_000_000 else { throw ModelError.invalid("Transcript too large") }
        let manifest = rootURL.appending(path: "\(projectID.rawValue.uuidString).cliphelm/project.json")
        try data.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        projects[index] = updated
    }
}
