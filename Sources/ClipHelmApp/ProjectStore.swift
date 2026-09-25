import Foundation
import SwiftUI
import ClipHelmCore
import ClipHelmEditing
import ClipHelmProcessing

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

enum RenderResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4k = "4K"
    var id: String { rawValue }
}

enum ClipCountMode: String, Codable, CaseIterable {
    case aiDecides = "AI decides"
    case fixed = "Fixed number"
    case custom = "Custom number"
}

struct ProjectDraft: Codable, Equatable {
    var title = "Untitled Clip Project"
    var sourceKind: SourceKind = .local
    var sourceName = ""
    var remoteURL = ""
    var preset: CanvasPreset = .vertical
    var resolution: RenderResolution = .hd1080
    var framingMode: FramingMode = .smartAuto
    var smartEdit = SmartEditOptions(useVisionForTrickyShots: false, cutDeadAir: true,
                                     trimLongPauses: true, cleanFillers: false, keepDemos: true)
    var pacingMode: PacingMode = .balanced
    var lengths: Set<ClipLength> = []
    var countMode: ClipCountMode = .aiDecides
    var requestedClipCount = 3
    var soundMode: SoundMode = .source
    var captionsEnabled = true
    var captionStyle: CaptionStyle = .pop
    var captionWordByWord = false
    var captionBlurIn = false

    init() { }

    // Source names and URLs are intentionally omitted: access must be re-granted after relaunch.
    private enum CodingKeys: String, CodingKey {
        case title, sourceKind, preset, resolution, framingMode, smartEdit, pacingMode, lengths
        case countMode, requestedClipCount, soundMode, captionsEnabled, captionStyle
        case captionWordByWord, captionBlurIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind)
        preset = try c.decode(CanvasPreset.self, forKey: .preset)
        resolution = try c.decodeIfPresent(RenderResolution.self, forKey: .resolution) ?? .hd1080
        framingMode = try c.decode(FramingMode.self, forKey: .framingMode)
        smartEdit = try c.decodeIfPresent(SmartEditOptions.self, forKey: .smartEdit) ?? smartEdit
        pacingMode = try c.decodeIfPresent(PacingMode.self, forKey: .pacingMode) ?? pacingMode
        lengths = try c.decode(Set<ClipLength>.self, forKey: .lengths)
        countMode = try c.decodeIfPresent(ClipCountMode.self, forKey: .countMode) ?? countMode
        requestedClipCount = try c.decodeIfPresent(Int.self, forKey: .requestedClipCount) ?? requestedClipCount
        soundMode = try c.decodeIfPresent(SoundMode.self, forKey: .soundMode) ?? soundMode
        captionsEnabled = try c.decode(Bool.self, forKey: .captionsEnabled)
        captionStyle = try c.decode(CaptionStyle.self, forKey: .captionStyle)
        captionWordByWord = try c.decodeIfPresent(Bool.self, forKey: .captionWordByWord) ?? false
        captionBlurIn = try c.decodeIfPresent(Bool.self, forKey: .captionBlurIn) ?? false
    }

    var configuration: ClipConfiguration {
        get throws {
            let format = resolution == .hd1080 ? preset.format :
                try OutputFormat(width: preset == .vertical ? 2160 : 3840,
                                 height: preset == .vertical ? 3840 : 2160)
            return try ClipConfiguration(outputFormat: format, framingMode: framingMode,
                                  pacingMode: pacingMode,
                                  selectedLengths: ClipLength.allCases.filter { lengths.contains($0) },
                                  requestedClipCount: countMode == .aiDecides ? nil : requestedClipCount,
                                  soundMode: soundMode, captionStyle: captionsEnabled ? captionStyle : nil,
                                  smartEdit: smartEdit,
                                  captionWordByWord: captionsEnabled && captionWordByWord,
                                  captionBlurIn: captionsEnabled && captionBlurIn)
        }
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

struct ProjectClipRecord: Codable, Identifiable, Sendable {
    let proposal: ClipProposal
    var spec: ClipHelmEditSpec
    var previewFileName: String
    var finalFileName: String
    var title: String
    var trimRange: MediaTimeRange?

    var id: ClipID { spec.clipID }

    init(_ clip: ProcessedClip) {
        proposal = clip.proposal
        spec = clip.spec
        previewFileName = clip.previewURL.lastPathComponent
        finalFileName = clip.finalURL.lastPathComponent
        title = clip.proposal.title
        trimRange = nil
    }

    private enum CodingKeys: String, CodingKey {
        case proposal, spec, previewFileName, finalFileName, title, trimRange
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proposal = try c.decode(ClipProposal.self, forKey: .proposal)
        spec = try c.decode(ClipHelmEditSpec.self, forKey: .spec)
        previewFileName = try c.decode(String.self, forKey: .previewFileName)
        finalFileName = try c.decode(String.self, forKey: .finalFileName)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? proposal.title
        trimRange = try c.decodeIfPresent(MediaTimeRange.self, forKey: .trimRange)
    }

    func validate(for asset: MediaAsset) throws {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 120,
              !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              previewFileName == URL(fileURLWithPath: previewFileName).lastPathComponent,
              finalFileName == URL(fileURLWithPath: finalFileName).lastPathComponent,
              previewFileName != finalFileName,
              previewFileName.hasSuffix(".mp4"), finalFileName.hasSuffix(".mp4") else {
            throw ModelError.invalid("Project clip file name")
        }
        if let trimRange {
            guard proposal.range.start <= trimRange.start, trimRange.end <= proposal.range.end,
                  spec.segments.allSatisfy({ trimRange.start <= $0.sourceRange.start &&
                      $0.sourceRange.end <= trimRange.end }) else {
                throw ModelError.invalid("Project clip trim")
            }
        }
        try EditSpecValidator().validate(spec, for: asset, proposal: proposal)
    }
}

struct ProjectRecord: Codable, Identifiable {
    static let currentVersion = 4

    let schemaVersion: Int
    let id: ProjectID
    let title: String
    let createdAt: Date
    let sourceKind: SourceKind
    let sourceLabel: String
    var configuration: ClipConfiguration
    let mediaAsset: MediaAsset?
    var transcript: Transcript?
    var clips: [ProjectClipRecord]

    var outputFormat: OutputFormat { configuration.outputFormat }
    var framingMode: FramingMode { configuration.framingMode }
    var selectedLengths: [ClipLength] { configuration.selectedLengths }
    var captionStyle: CaptionStyle? { configuration.captionStyle }

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
        configuration = try draft.configuration
        self.mediaAsset = mediaAsset
        transcript = nil
        clips = []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, sourceKind, sourceLabel
        case configuration, mediaAsset, transcript, clips
        case outputFormat, framingMode, selectedLengths, captionStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentVersion).contains(version) else {
            throw ModelError.invalid("ProjectRecord version")
        }
        schemaVersion = Self.currentVersion
        id = try c.decode(ProjectID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind)
        sourceLabel = try c.decode(String.self, forKey: .sourceLabel)
        mediaAsset = try c.decodeIfPresent(MediaAsset.self, forKey: .mediaAsset)
        transcript = try c.decodeIfPresent(Transcript.self, forKey: .transcript)
        clips = try c.decodeIfPresent([ProjectClipRecord].self, forKey: .clips) ?? []
        if version == 1 {
            configuration = try ClipConfiguration(
                outputFormat: c.decode(OutputFormat.self, forKey: .outputFormat),
                framingMode: c.decode(FramingMode.self, forKey: .framingMode),
                pacingMode: .balanced,
                selectedLengths: c.decode([ClipLength].self, forKey: .selectedLengths),
                requestedClipCount: nil, soundMode: .source,
                captionStyle: c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle),
                smartEdit: SmartEditOptions(useVisionForTrickyShots: false, cutDeadAir: true,
                                            trimLongPauses: true, cleanFillers: false, keepDemos: true))
        } else {
            configuration = try c.decode(ClipConfiguration.self, forKey: .configuration)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(sourceKind, forKey: .sourceKind)
        try c.encode(sourceLabel, forKey: .sourceLabel)
        try c.encode(configuration, forKey: .configuration)
        try c.encodeIfPresent(mediaAsset, forKey: .mediaAsset)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encode(clips, forKey: .clips)
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
                          }) ?? true,
                          record.clips.count <= 1_000,
                          Set(record.clips.map(\.id)).count == record.clips.count,
                          Set(record.clips.flatMap { [$0.previewFileName, $0.finalFileName] }).count == record.clips.count * 2,
                          record.clips.allSatisfy({ clip in
                              guard let asset = record.mediaAsset else { return false }
                              return (try? clip.validate(for: asset)) != nil
                          }) else {
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
        if !transcript.hasMeaningfulSpeech {
            updated.configuration = try updated.configuration.disablingCaptions()
        }
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 25_000_000 else { throw ModelError.invalid("Transcript too large") }
        let manifest = rootURL.appending(path: "\(projectID.rawValue.uuidString).cliphelm/project.json")
        try data.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        projects[index] = updated
    }

    func analysisCacheDirectory(for projectID: ProjectID) throws -> URL {
        guard let rootURL, projects.contains(where: { $0.id == projectID }) else {
            throw ModelError.invalid("Analysis project")
        }
        return rootURL.appending(path: "\(projectID.rawValue.uuidString).cliphelm/Cache",
                                 directoryHint: .isDirectory)
    }

    func exportsDirectory(for projectID: ProjectID) throws -> URL {
        guard let rootURL, projects.contains(where: { $0.id == projectID }) else {
            throw ModelError.invalid("Exports project")
        }
        return rootURL.appending(path: "\(projectID.rawValue.uuidString).cliphelm/Exports",
                                 directoryHint: .isDirectory)
    }

    func saveProcessingResult(_ result: ProcessingResult, for projectID: ProjectID) throws {
        guard let rootURL, let index = projects.firstIndex(where: { $0.id == projectID }),
              let asset = projects[index].mediaAsset, asset == result.source.asset,
              result.transcript.assetID == asset.id,
              result.transcript.words.allSatisfy({ $0.range.end <= asset.duration }),
              !result.clips.isEmpty else {
            throw ModelError.invalid("Processing project mismatch")
        }
        let directory = try exportsDirectory(for: projectID).standardizedFileURL
        let records = result.clips.map(ProjectClipRecord.init)
        for (record, clip) in zip(records, result.clips) {
            try record.validate(for: asset)
            guard clip.previewURL.deletingLastPathComponent().standardizedFileURL == directory,
                  clip.finalURL.deletingLastPathComponent().standardizedFileURL == directory,
                  FileManager.default.fileExists(atPath: clip.previewURL.path),
                  FileManager.default.fileExists(atPath: clip.finalURL.path) else {
                throw ModelError.invalid("Processing output missing")
            }
        }
        var updated = projects[index]
        updated.transcript = result.transcript
        if !result.transcript.hasMeaningfulSpeech {
            updated.configuration = try updated.configuration.disablingCaptions()
        }
        updated.clips.append(contentsOf: records)
        guard updated.clips.count <= 1_000,
              Set(updated.clips.map(\.id)).count == updated.clips.count,
              Set(updated.clips.flatMap { [$0.previewFileName, $0.finalFileName] }).count == updated.clips.count * 2 else {
            throw ModelError.invalid("Duplicate or excessive clips")
        }
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 25_000_000 else { throw ModelError.invalid("Project too large") }
        let manifest = rootURL.appending(path: "\(projectID.rawValue.uuidString).cliphelm/project.json")
        try data.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        projects[index] = updated
    }

    func updateClip(_ clip: ProjectClipRecord, for projectID: ProjectID) throws {
        guard let rootURL, let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let asset = projects[projectIndex].mediaAsset,
              let clipIndex = projects[projectIndex].clips.firstIndex(where: { $0.id == clip.id }) else {
            throw ModelError.invalid("Clip project mismatch")
        }
        let previous = projects[projectIndex].clips[clipIndex]
        guard clip.proposal == previous.proposal else { throw ModelError.invalid("Clip proposal changed") }
        try clip.validate(for: asset)
        let directory = try exportsDirectory(for: projectID)
        guard FileManager.default.fileExists(atPath: directory.appending(path: clip.previewFileName).path),
              FileManager.default.fileExists(atPath: directory.appending(path: clip.finalFileName).path) else {
            throw ModelError.invalid("Clip output missing")
        }
        var updated = projects[projectIndex]
        updated.clips[clipIndex] = clip
        guard Set(updated.clips.flatMap { [$0.previewFileName, $0.finalFileName] }).count == updated.clips.count * 2 else {
            throw ModelError.invalid("Duplicate clip output")
        }
        try persist(updated, at: projectIndex, rootURL: rootURL)
        for name in [previous.previewFileName, previous.finalFileName]
        where name != clip.previewFileName && name != clip.finalFileName {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    func deleteClip(_ clipID: ClipID, from projectID: ProjectID) throws {
        guard let rootURL, let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let asset = projects[projectIndex].mediaAsset,
              let clipIndex = projects[projectIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw ModelError.invalid("Clip project mismatch")
        }
        let clip = projects[projectIndex].clips[clipIndex]
        try clip.validate(for: asset)
        var updated = projects[projectIndex]
        updated.clips.remove(at: clipIndex)
        try persist(updated, at: projectIndex, rootURL: rootURL)
        let directory = try exportsDirectory(for: projectID)
        for name in [clip.previewFileName, clip.finalFileName] {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private func persist(_ record: ProjectRecord, at index: Int, rootURL: URL) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 25_000_000 else { throw ModelError.invalid("Project too large") }
        let manifest = rootURL.appending(path: "\(record.id.rawValue.uuidString).cliphelm/project.json")
        try data.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        projects[index] = record
    }
}
