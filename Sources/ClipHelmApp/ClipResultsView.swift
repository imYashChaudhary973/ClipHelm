import AppKit
import AVFoundation
import AVKit
import SwiftUI
import ClipHelmCore
import ClipHelmSources
import ClipHelmRendering

private struct ReviewSelection: Identifiable {
    let clipID: ClipID
    let autoplay: Bool
    var id: UUID { clipID.rawValue }
}

struct ClipResultsView: View {
    let project: ProjectRecord
    let source: PreparedSource?
    let exportsDirectory: URL?
    let cacheDirectory: URL?
    let saveClip: @MainActor (ProjectClipRecord) throws -> Void
    let deleteClip: @MainActor (ClipID) throws -> Void

    @State private var selected: Set<ClipID> = []
    @State private var reviewing: ReviewSelection?
    @State private var deleting: ClipID?
    @State private var exportJob: Task<Void, Never>?
    @State private var exporting = false
    @State private var exportFraction = 0.0
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Generated clips").font(.title3.weight(.semibold))
                Text("\(project.clips.count)").foregroundStyle(.secondary)
                Spacer()
                if !project.clips.isEmpty {
                    Button("Select All") { selected = Set(project.clips.map(\.id)) }
                        .disabled(exporting)
                    Button("Export Selected (\(selected.count))") {
                        chooseExportFolder(for: project.clips.filter { selected.contains($0.id) })
                    }
                    .disabled(selected.isEmpty || exporting || exportsDirectory == nil)
                }
            }
            if project.clips.isEmpty {
                ContentUnavailableView("No clips yet", systemImage: "film.stack",
                    description: Text("Process this project to see its clips here."))
                    .frame(minHeight: 120)
            } else if let exportsDirectory {
                LazyVStack(spacing: 0) {
                    ForEach(project.clips) { clip in
                        resultRow(clip, directory: exportsDirectory)
                        Divider()
                    }
                }
            }
            if exporting {
                HStack {
                    ProgressView(value: exportFraction).frame(width: 180)
                    Text("Exporting clips…").foregroundStyle(.secondary)
                    Button("Cancel") { exportJob?.cancel() }
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $reviewing) { selection in
            if let clip = project.clips.first(where: { $0.id == selection.clipID }),
               let exportsDirectory {
                ClipReviewView(clip: clip, project: project, source: source,
                    exportsDirectory: exportsDirectory, cacheDirectory: cacheDirectory,
                    autoplay: selection.autoplay, saveClip: saveClip,
                    exportClip: { chooseExportFolder(for: [$0]) },
                    deleteClip: { id in
                        try deleteClip(id)
                        selected.remove(id)
                        reviewing = nil
                    })
            }
        }
        .confirmationDialog("Delete this clip from the project?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete Clip", role: .destructive) {
                guard let id = deleting else { return }
                do {
                    try deleteClip(id)
                    selected.remove(id)
                } catch { message = "The clip could not be removed. Try again." }
                deleting = nil
            }
        } message: {
            Text("Its generated project files will be removed. Files already exported elsewhere stay untouched.")
        }
        .onDisappear { exportJob?.cancel() }
    }

    private func resultRow(_ clip: ProjectClipRecord, directory: URL) -> some View {
        let preview = directory.appending(path: clip.previewFileName)
        let final = directory.appending(path: clip.finalFileName)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("Select \(clip.title)", isOn: Binding(
                    get: { selected.contains(clip.id) },
                    set: { if $0 { selected.insert(clip.id) } else { selected.remove(clip.id) } }
                ))
                .labelsHidden()
                .disabled(exporting)
                ResultThumbnail(url: preview)
                    .frame(width: 106, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title).font(.headline).lineLimit(2)
                    Text("\(ClipTimeLabel.duration(clip.spec)) · Source \(ClipTimeLabel.source(clip.spec)) · \(ClipTimeLabel.aspect(clip.spec.outputFormat))")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Play") { reviewing = ReviewSelection(clipID: clip.id, autoplay: true) }
                    .disabled(!FileManager.default.fileExists(atPath: preview.path))
                Button("Edit") { reviewing = ReviewSelection(clipID: clip.id, autoplay: false) }
                    .disabled(!FileManager.default.fileExists(atPath: preview.path))
                Button("Export") { chooseExportFolder(for: [clip]) }
                    .disabled(exporting || !FileManager.default.fileExists(atPath: final.path))
                Menu {
                    Button("Delete from Project", role: .destructive) { deleting = clip.id }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel("More actions for \(clip.title)")
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func chooseExportFolder(for clips: [ProjectClipRecord]) {
        guard !clips.isEmpty, let exportsDirectory else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Clips"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                let items = clips.map { ClipExportItem(title: $0.title,
                    fileURL: exportsDirectory.appending(path: $0.finalFileName)) }
                exporting = true
                exportFraction = 0
                message = nil
                exportJob = Task { @MainActor in
                    do {
                        let files = try await ClipExporter().export(items,
                            from: exportsDirectory, to: destination) { fraction in
                            Task { @MainActor in exportFraction = fraction }
                        }
                        message = "Exported \(files.count) \(files.count == 1 ? "clip" : "clips")."
                    } catch is CancellationError {
                        message = "Export cancelled. No new files were kept."
                    } catch let error as LocalizedError {
                        message = error.errorDescription ?? "Export failed. Check the destination and try again."
                    } catch {
                        message = "Export failed. Check the destination and try again."
                    }
                    exporting = false
                }
            }
        }
    }
}

private struct ResultThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .black)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityLabel("Video preview")
        .task(id: url) {
            image = nil
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            if let (frame, _) = try? await generator.image(at: .zero) {
                image = NSImage(cgImage: frame, size: .zero)
            }
        }
    }
}

private enum ClipTimeLabel {
    static func clock(_ time: MediaTime) -> String {
        let seconds = time.microseconds / 1_000_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    static func duration(_ spec: ClipHelmEditSpec) -> String {
        let micros = spec.segments.reduce(Int64(0)) { $0 + $1.sourceRange.durationMicroseconds }
        let seconds = micros / 1_000_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    static func source(_ spec: ClipHelmEditSpec) -> String {
        guard let first = spec.segments.first, let last = spec.segments.last else { return "—" }
        return "\(clock(first.sourceRange.start))–\(clock(last.sourceRange.end))"
    }

    static func aspect(_ format: OutputFormat) -> String {
        format.height > format.width ? "9:16" : "16:9"
    }
}

struct ClipReviewView: View {
    let project: ProjectRecord
    let source: PreparedSource?
    let exportsDirectory: URL
    let cacheDirectory: URL?
    let saveClip: @MainActor (ProjectClipRecord) throws -> Void
    let exportClip: @MainActor (ProjectClipRecord) -> Void
    let deleteClip: @MainActor (ClipID) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: ProjectClipRecord
    @State private var player: AVPlayer
    @State private var title: String
    @State private var framing: FramingMode
    @State private var pacing: PacingMode
    @State private var captions: CaptionStyle?
    @State private var trimStart: Double
    @State private var trimEnd: Double
    @State private var focusX: Double
    @State private var focusY: Double
    @State private var busy = false
    @State private var renderStage = ""
    @State private var renderFraction = 0.0
    @State private var job: Task<Void, Never>?
    @State private var message: String?
    @State private var confirmDelete = false
    private let autoplay: Bool

    init(clip: ProjectClipRecord, project: ProjectRecord, source: PreparedSource?,
         exportsDirectory: URL, cacheDirectory: URL?, autoplay: Bool,
         saveClip: @escaping @MainActor (ProjectClipRecord) throws -> Void,
         exportClip: @escaping @MainActor (ProjectClipRecord) -> Void,
         deleteClip: @escaping @MainActor (ClipID) throws -> Void) {
        self.project = project
        self.source = source
        self.exportsDirectory = exportsDirectory
        self.cacheDirectory = cacheDirectory
        self.saveClip = saveClip
        self.exportClip = exportClip
        self.deleteClip = deleteClip
        self.autoplay = autoplay
        _current = State(initialValue: clip)
        _player = State(initialValue: AVPlayer(url: exportsDirectory.appending(path: clip.previewFileName)))
        _title = State(initialValue: clip.title)
        _framing = State(initialValue: clip.spec.framingMode)
        _pacing = State(initialValue: clip.spec.pacingMode)
        _captions = State(initialValue: clip.spec.captionStyle)
        let trim = clip.trimRange ?? clip.proposal.range
        _trimStart = State(initialValue: Double(trim.start.microseconds) / 1_000_000)
        _trimEnd = State(initialValue: Double(trim.end.microseconds) / 1_000_000)
        let rect = clip.spec.cropPaths.first?.keyframes.first?.rect
        _focusX = State(initialValue: rect.map { $0.x + $0.width / 2 } ?? 0.5)
        _focusY = State(initialValue: rect.map { $0.y + $0.height / 2 } ?? 0.5)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Review Clip").font(.title2.weight(.semibold))
                        Text("\(ClipTimeLabel.duration(current.spec)) · Source \(ClipTimeLabel.source(current.spec)) · \(ClipTimeLabel.aspect(current.spec.outputFormat))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                }
                VideoPlayer(player: player)
                    .frame(height: 310)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if source == nil || cacheDirectory == nil {
                    Label("Locate the original video in the workspace to edit framing, pacing, trim, or captions. Rename, playback, and export still work.",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Form {
                    Section("Clip") {
                        TextField("Title", text: $title)
                        LabeledContent("Output", value: "\(current.spec.outputFormat.width) × \(current.spec.outputFormat.height)")
                    }
                    Section("Framing") {
                        Picker("Mode", selection: $framing) {
                            ForEach([FramingMode.smartAuto, .fullFrame, .classicFullFrame, .blurred], id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        if framing == .fullFrame {
                            LabeledContent("Horizontal focus") {
                                Slider(value: $focusX, in: 0...1).frame(width: 220)
                            }
                            LabeledContent("Vertical focus") {
                                Slider(value: $focusY, in: 0...1).frame(width: 220)
                            }
                        }
                        Button("Regenerate Framing") {
                            framing = .smartAuto
                            focusX = 0.5
                            focusY = 0.5
                            saveChanges(forceRender: true)
                        }
                        .disabled(busy || source == nil || cacheDirectory == nil)
                    }
                    .disabled(busy || source == nil || cacheDirectory == nil)
                    Section("Pacing and Trim") {
                        Picker("Pacing", selection: $pacing) {
                            ForEach(PacingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        HStack {
                            Text("In").frame(width: 38, alignment: .leading)
                            TextField("Seconds", value: $trimStart,
                                format: .number.precision(.fractionLength(2)))
                                .frame(width: 95)
                            Text("Out").frame(width: 38, alignment: .leading)
                            TextField("Seconds", value: $trimEnd,
                                format: .number.precision(.fractionLength(2)))
                                .frame(width: 95)
                            Text("seconds in source").foregroundStyle(.secondary)
                        }
                        Text("Available: \(ClipTimeLabel.clock(current.proposal.range.start))–\(ClipTimeLabel.clock(current.proposal.range.end)). Pacing recalculates pause cuts inside the trim.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .disabled(busy || source == nil || cacheDirectory == nil)
                    Section("Captions") {
                        Picker("Style", selection: $captions) {
                            Text("Off").tag(nil as CaptionStyle?)
                            ForEach(Self.styles, id: \.self) { style in
                                Text(style.label).tag(Optional(style))
                            }
                        }
                        .disabled(project.transcript?.hasMeaningfulSpeech != true)
                        if project.transcript?.hasMeaningfulSpeech != true {
                            Text("No meaningful speech was found for captions.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(busy || source == nil || cacheDirectory == nil)
                }
                .formStyle(.grouped)
                if busy {
                    HStack {
                        ProgressView(value: renderFraction).frame(width: 180)
                        Text(renderStage).foregroundStyle(.secondary)
                        Button("Cancel") { job?.cancel() }
                    }
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Save Changes") { saveChanges() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    Button("Export") { exportClip(current) }
                        .disabled(busy || hasUnsavedChanges)
                    Spacer()
                    Button("Delete from Project", role: .destructive) { confirmDelete = true }
                        .disabled(busy)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 540, idealWidth: 700, minHeight: 500, idealHeight: 760)
        .onAppear { if autoplay { player.play() } }
        .onDisappear { player.pause(); job?.cancel() }
        .confirmationDialog("Delete this clip from the project?", isPresented: $confirmDelete) {
            Button("Delete Clip", role: .destructive) {
                do { try deleteClip(current.id) }
                catch { message = "The clip could not be removed. Try again." }
            }
        } message: {
            Text("Its generated project files will be removed. Files already exported elsewhere stay untouched.")
        }
    }

    private static let styles: [CaptionStyle] = [
        .pop, .spotlight, .impact, .glowBox, .editorial, .highPunch, .neonHeadline, .paper
    ]

    private var hasUnsavedChanges: Bool {
        let trim = current.trimRange ?? current.proposal.range
        let firstFocus = current.spec.cropPaths.first?.keyframes.first?.rect
        let savedX = firstFocus.map { $0.x + $0.width / 2 } ?? 0.5
        let savedY = firstFocus.map { $0.y + $0.height / 2 } ?? 0.5
        return title.trimmingCharacters(in: .whitespacesAndNewlines) != current.title ||
            framing != current.spec.framingMode || pacing != current.spec.pacingMode ||
            captions != current.spec.captionStyle ||
            abs(trimStart - Double(trim.start.microseconds) / 1_000_000) > 0.000_01 ||
            abs(trimEnd - Double(trim.end.microseconds) / 1_000_000) > 0.000_01 ||
            (framing == .fullFrame && (abs(focusX - savedX) > 0.000_01 ||
                                        abs(focusY - savedY) > 0.000_01))
    }

    private func saveChanges(forceRender: Bool = false) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty, cleanedTitle.count <= 120,
              !cleanedTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            message = "Use a title between 1 and 120 characters without control characters."
            return
        }
        let lower = Double(current.proposal.range.start.microseconds) / 1_000_000
        let upper = Double(current.proposal.range.end.microseconds) / 1_000_000
        guard trimStart.isFinite, trimEnd.isFinite, trimStart >= lower,
              trimEnd <= upper, trimEnd - trimStart >= 0.5 else {
            message = "Keep trim times inside the available source range, at least half a second apart."
            return
        }
        do {
            let range = try MediaTimeRange(
                start: MediaTime(microseconds: Int64((trimStart * 1_000_000).rounded())),
                end: MediaTime(microseconds: Int64((trimEnd * 1_000_000).rounded())))
            let originalTrim = current.trimRange ?? current.proposal.range
            let currentFocus = current.spec.cropPaths.first?.keyframes.first?.rect
            let savedX = currentFocus.map { $0.x + $0.width / 2 } ?? 0.5
            let savedY = currentFocus.map { $0.y + $0.height / 2 } ?? 0.5
            let needsRender = forceRender || range != originalTrim ||
                framing != current.spec.framingMode || pacing != current.spec.pacingMode ||
                captions != current.spec.captionStyle ||
                (framing == .fullFrame && (abs(focusX - savedX) > 0.000_01 ||
                                            abs(focusY - savedY) > 0.000_01))
            guard needsRender else {
                var renamed = current
                renamed.title = cleanedTitle
                try saveClip(renamed)
                current = renamed
                message = "Clip renamed."
                return
            }
            guard let source, let cacheDirectory else {
                message = "Locate the original source in the workspace before changing this clip."
                return
            }
            busy = true
            renderFraction = 0
            renderStage = "Preparing edit…"
            message = nil
            let options = ClipRevisionOptions(trimRange: range, framing: framing,
                pacing: pacing, captionStyle: captions, focusX: focusX,
                focusY: focusY, forceReframe: forceRender)
            let previous = current
            job = Task { @MainActor in
                let stem = "clip-\(previous.id.rawValue.uuidString)-\(UUID().uuidString)"
                let preview = exportsDirectory.appending(path: stem + "-preview.mp4")
                let final = exportsDirectory.appending(path: stem + ".mp4")
                defer { busy = false }
                do {
                    let spec = try await ClipRevisionPlanner().revise(previous,
                        source: source, transcript: project.transcript,
                        configuration: project.configuration,
                        cacheDirectory: cacheDirectory, options: options)
                    try Task.checkCancellation()
                    renderStage = "Rendering preview…"
                    _ = try await ClipRenderer().render(spec, sourceURL: source.fileURL,
                        asset: source.asset, outputURL: preview, quality: .preview) { update in
                        Task { @MainActor in renderFraction = update.fraction * 0.5 }
                    }
                    renderStage = "Rendering final clip…"
                    _ = try await ClipRenderer().render(spec, sourceURL: source.fileURL,
                        asset: source.asset, outputURL: final) { update in
                        Task { @MainActor in renderFraction = 0.5 + update.fraction * 0.5 }
                    }
                    try Task.checkCancellation()
                    var revised = previous
                    revised.spec = spec
                    revised.previewFileName = preview.lastPathComponent
                    revised.finalFileName = final.lastPathComponent
                    revised.title = cleanedTitle
                    revised.trimRange = range == previous.proposal.range ? nil : range
                    try saveClip(revised)
                    current = revised
                    if let rect = revised.spec.cropPaths.first?.keyframes.first?.rect {
                        focusX = rect.x + rect.width / 2
                        focusY = rect.y + rect.height / 2
                    }
                    player.pause()
                    player.replaceCurrentItem(with: AVPlayerItem(url: preview))
                    renderFraction = 1
                    message = "Changes saved. Preview the new clip before exporting."
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: preview)
                    try? FileManager.default.removeItem(at: final)
                    message = "Edit cancelled. The previous clip is unchanged."
                } catch let error as LocalizedError {
                    try? FileManager.default.removeItem(at: preview)
                    try? FileManager.default.removeItem(at: final)
                    message = error.errorDescription ?? "The edit could not be saved. Try again."
                } catch {
                    try? FileManager.default.removeItem(at: preview)
                    try? FileManager.default.removeItem(at: final)
                    message = "The edit could not be saved. Check the original source and try again."
                }
            }
        } catch {
            message = "The trim range is invalid."
        }
    }
}
