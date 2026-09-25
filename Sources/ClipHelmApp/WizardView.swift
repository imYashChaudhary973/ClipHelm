import SwiftUI
import UniformTypeIdentifiers
import ClipHelmCore
import ClipHelmSources

struct WizardView: View {
    @Binding var draft: ProjectDraft
    @Binding var step: WizardStep
    let ingestor: SourceIngestor
    let onSave: (PreparedSource?) -> Void

    @State private var showsImporter = false
    @State private var sourceError: String?
    @State private var prepared: PreparedSource?
    @State private var sourceProgress: SourceProgress?
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationID = UUID()
    @State private var preparing = false
    @State private var authorizedRemote = false
    @State private var dropTargeted = false

    private let framingModes: [FramingMode] = [.smartAuto, .fullFrame, .classicFullFrame, .blurred]
    private let captionStyles: [CaptionStyle] = [
        .pop, .spotlight, .impact, .glowBox, .editorial, .highPunch, .neonHeadline, .paper,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("STEP \(step.rawValue + 1) OF \(WizardStep.allCases.count)")
                        .font(.caption.weight(.semibold))
                        .tracking(1.8)
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .font(.system(size: 36, weight: .semibold))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(WizardStep.allCases) { item in
                        Capsule()
                            .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.18))
                            .frame(height: 4)
                            .accessibilityLabel("Step \(item.rawValue + 1): \(item.title)")
                    }
                }
                .accessibilityElement(children: .contain)

                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 275, alignment: .topLeading)

                Divider()
                HStack {
                    Button("Back") {
                        if let previous = WizardStep(rawValue: step.rawValue - 1) { step = previous }
                    }
                    .disabled(step == .source)
                    .keyboardShortcut("[", modifiers: .command)
                    Spacer()
                    if step == .process {
                        Button("Create Project") { onSave(prepared) }
                            .buttonStyle(.borderedProminent)
                            .disabled(prepared == nil)
                    } else {
                        Button("Continue") {
                            if let next = WizardStep(rawValue: step.rawValue + 1) { step = next }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled((step == .source && prepared == nil) ||
                                  (step == .review && !validTitle) ||
                                  (step == .number && draft.countMode != .aiDecides &&
                                   !(1...1_000).contains(draft.requestedClipCount)))
                        .keyboardShortcut("]", modifiers: .command)
                    }
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(42)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { preparationTask?.cancel() }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie]
        ) { result in
            switch result {
            case .success(let url):
                prepareLocal(url)
            case .failure:
                sourceError = "The file could not be selected. Try again."
            }
        }
    }

    private var subtitle: String {
        switch step {
        case .source: "Choose the video you have permission to process."
        case .format: "Choose the shape of the final clips."
        case .framing: "Decide how source footage fits the output canvas."
        case .smartEditing: "Choose which cleanup tools ClipHelm may use."
        case .length: "Choose one or more ranges, or leave them open."
        case .number: "Let quality determine the count, or set a target."
        case .sound: "Choose how clip audio should be handled."
        case .captions: "Choose a starting style for speech captions."
        case .review: "Check the direction before saving a project draft."
        case .process: "Create the project, then process clips in its workspace."
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .source: sourceContent
        case .format: formatContent
        case .framing: framingContent
        case .smartEditing: smartEditingContent
        case .length: lengthContent
        case .number: numberContent
        case .sound: soundContent
        case .captions: captionContent
        case .review: reviewContent
        case .process: processContent
        }
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Source", selection: $draft.sourceKind) {
                ForEach(SourceKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draft.sourceKind) { _, _ in resetSource() }

            if draft.sourceKind == .local {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Choose Video…") { showsImporter = true }
                    Label(dropTargeted ? "Release to prepare video" : "Or drop a video file here",
                          systemImage: "square.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5])))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let file = urls.first(where: \.isFileURL) else { return false }
                            prepareLocal(file)
                            return true
                        } isTargeted: { dropTargeted = $0 }
                }
                Text("MP4, MKV, or MOV. The original file is never changed.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextField("https://…", text: $draft.remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(draft.sourceKind.rawValue)
                    .onChange(of: draft.remoteURL) { _, _ in resetSource() }
                Toggle("I own this video or have permission to process it", isOn: $authorizedRemote)
                    .onChange(of: authorizedRemote) { _, _ in resetSource() }
                Button("Prepare Source") { prepareRemote() }
                    .disabled(preparing || draft.remoteURL.isEmpty || !authorizedRemote)
                Text(draft.sourceKind == .youtube
                     ? "Use a YouTube link for media you own or may process."
                     : "Use an HTTPS direct video link you are authorized to process.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Public links only. Private, protected, and sign-in-only media are not imported.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if preparing {
                HStack(spacing: 12) {
                    if let fraction = sourceProgress?.fraction {
                        ProgressView(value: fraction).frame(width: 170)
                    } else { ProgressView().controlSize(.small) }
                    Text(progressLabel).foregroundStyle(.secondary)
                    Button("Cancel") { resetSource() }
                }
            }
            if let asset = prepared?.asset {
                Label("Ready: \(asset.displayName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(asset.width) × \(asset.height) · \(Int(asset.duration.microseconds / 1_000_000)) seconds")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let sourceError {
                Text(sourceError).foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var formatContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Output format", selection: $draft.preset) {
                ForEach(CanvasPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }
            .pickerStyle(.radioGroup)
            Picker("Export resolution", selection: $draft.resolution) {
                ForEach(RenderResolution.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .frame(maxWidth: 220)
            Text(draft.preset == .vertical
                 ? "A tall canvas for vertical feeds and stories."
                 : "A wide canvas for landscape viewing.")
                .foregroundStyle(.secondary)
            if draft.resolution == .uhd4k {
                Text("4K takes more time and disk space; the source should be 4K for full detail.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var framingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Framing mode", selection: $draft.framingMode) {
                ForEach(framingModes, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Text(draft.framingMode.description)
                .foregroundStyle(.secondary)
        }
    }

    private var smartEditingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Check tricky shots with AI Vision", isOn: $draft.smartEdit.useVisionForTrickyShots)
            Toggle("Cut dead air", isOn: $draft.smartEdit.cutDeadAir)
            Toggle("Trim long pauses", isOn: $draft.smartEdit.trimLongPauses)
            Toggle("Filter filler words", isOn: $draft.smartEdit.cleanFillers)
            Toggle("Keep demos", isOn: $draft.smartEdit.keepDemos)
            Divider()
            Picker("Pacing", selection: $draft.pacingMode) {
                ForEach(PacingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .frame(maxWidth: 320)
            Text("AI Vision is used only for uncertain shots. These choices will guide later editing; no edits run during setup.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var lengthContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip lengths").font(.headline)
            Text("Select any combination. Nothing selected means Any Length.")
                .foregroundStyle(.secondary)
            ForEach(ClipLength.allCases, id: \.self) { length in
                Toggle(length.label, isOn: Binding(
                    get: { draft.lengths.contains(length) },
                    set: { selected in
                        if selected { draft.lengths.insert(length) }
                        else { draft.lengths.remove(length) }
                    }
                ))
            }
        }
    }

    private var numberContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Number of clips", selection: $draft.countMode) {
                ForEach(ClipCountMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: draft.countMode) { _, mode in
                if mode == .fixed && ![1, 3, 5, 10].contains(draft.requestedClipCount) {
                    draft.requestedClipCount = 3
                }
            }
            if draft.countMode == .fixed {
                Picker("Target", selection: $draft.requestedClipCount) {
                    ForEach([1, 3, 5, 10], id: \.self) { count in
                        Text("\(count) clips").tag(count)
                    }
                }
                .frame(maxWidth: 250)
            } else if draft.countMode == .custom {
                TextField("Target", value: $draft.requestedClipCount, format: .number)
                    .frame(maxWidth: 120)
                if !(1...1_000).contains(draft.requestedClipCount) {
                    Text("Enter a number from 1 to 1,000.")
                        .foregroundStyle(.red)
                }
            }
            Text("ClipHelm may return fewer clips if the source has fewer strong moments.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var soundContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Sound", selection: $draft.soundMode) {
                Text("Original").tag(SoundMode.source)
                Text("Normalize").tag(SoundMode.normalize)
            }
            .pickerStyle(.radioGroup)
            Text(draft.soundMode == .normalize
                 ? "Aim for more consistent loudness across clips."
                 : "Keep the source audio level.")
                .foregroundStyle(.secondary)
        }
    }

    private var captionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Create captions when speech is present", isOn: $draft.captionsEnabled)
            if draft.captionsEnabled {
                Picker("Style", selection: $draft.captionStyle) {
                    ForEach(captionStyles, id: \.self) { style in Text(style.label).tag(style) }
                }
                .frame(maxWidth: 340)
                Toggle("Word-by-word animation", isOn: $draft.captionWordByWord)
                Toggle("Blur-in", isOn: $draft.captionBlurIn)
            }
            Text(prepared?.hasAudio == false
                 ? "This source has no audio track, so captions started off."
                 : "Captions turn off if transcription finds no meaningful speech.")
                .foregroundStyle(.secondary)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Project name", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            if !validTitle {
                Text("Enter a project name of up to 200 characters.")
                    .foregroundStyle(.red)
            }
            Divider()
            LabeledContent("Source", value: prepared?.asset.displayName ?? "No source selected")
            if let asset = prepared?.asset {
                LabeledContent("Source media", value: "\(asset.width) × \(asset.height) · \(Int(asset.duration.microseconds / 1_000_000)) seconds")
            }
            LabeledContent("Format", value: "\(draft.preset.rawValue) · \(draft.resolution.rawValue)")
            LabeledContent("Framing", value: draft.framingMode.label)
            LabeledContent("Pacing", value: draft.pacingMode.label)
            LabeledContent("Smart editing", value: smartEditSummary)
            LabeledContent("Length", value: draft.lengths.isEmpty
                           ? "Any Length"
                           : ClipLength.allCases.filter { draft.lengths.contains($0) }.map(\.label).joined(separator: ", "))
            LabeledContent("Number", value: draft.countMode == .aiDecides
                           ? "AI decides" : "Up to \(draft.requestedClipCount)")
            LabeledContent("Sound", value: draft.soundMode == .normalize ? "Normalize" : "Original")
            LabeledContent("Captions", value: draft.captionsEnabled
                           ? "\(draft.captionStyle.label)\(draft.captionWordByWord ? " · Word-by-word" : "")\(draft.captionBlurIn ? " · Blur-in" : "")"
                           : "Off")
        }
    }

    private var validTitle: Bool {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 200
    }

    private var smartEditSummary: String {
        let options = draft.smartEdit
        let enabled = [
            (options.useVisionForTrickyShots, "AI Vision"),
            (options.cutDeadAir, "Dead air"),
            (options.trimLongPauses, "Long pauses"),
            (options.cleanFillers, "Filler words"),
            (options.keepDemos, "Keep demos"),
        ].filter(\.0).map(\.1)
        return enabled.isEmpty ? "Off" : enabled.joined(separator: ", ")
    }

    private var processContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to create project", systemImage: "checkmark.circle")
                .font(.title3.weight(.medium))
            Text("Save the project, then process clips from its workspace.")
                .foregroundStyle(.secondary)
            Text("The original media stays untouched. ClipHelm saves source metadata, but source access must be granted again after relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var progressLabel: String {
        switch sourceProgress?.stage {
        case .checking: "Checking source…"
        case .downloading: "Downloading…"
        case .validating: "Validating video…"
        case nil: "Preparing…"
        }
    }

    private func resetSource() {
        preparationTask?.cancel()
        preparationID = UUID()
        preparing = false
        prepared = nil
        sourceProgress = nil
        sourceError = nil
        draft.sourceName = ""
    }

    private func prepareLocal(_ url: URL) {
        resetSource()
        do { startPreparation(try SourceDescriptor(localFile: url)) }
        catch { sourceError = safeSourceError(error) }
    }

    private func prepareRemote() {
        resetSource()
        do {
            startPreparation(try SourceDescriptor(remoteURL: draft.remoteURL,
                                                  youtube: draft.sourceKind == .youtube,
                                                  authorized: authorizedRemote))
        } catch { sourceError = safeSourceError(error) }
    }

    private func startPreparation(_ descriptor: SourceDescriptor) {
        let id = UUID()
        preparationID = id
        preparing = true
        let ingestor = self.ingestor
        preparationTask = Task {
            do {
                let result = try await ingestor.prepare(descriptor) { update in
                    Task { @MainActor in
                        if preparationID == id { sourceProgress = update }
                    }
                }
                guard preparationID == id else { return }
                prepared = result
                if descriptor.kind == .local { draft.sourceName = result.asset.displayName }
                draft.captionsEnabled = result.hasAudio
                preparing = false
            } catch {
                guard preparationID == id else { return }
                preparing = false
                if !(error is CancellationError) { sourceError = safeSourceError(error) }
            }
        }
    }

    private func safeSourceError(_ error: Error) -> String {
        (error as? SourceIngestError)?.localizedDescription ?? "The video could not be prepared. Try again."
    }
}

extension ClipLength {
    var label: String {
        switch self {
        case .seconds10to30: "10–30 seconds"
        case .seconds30to60: "30–60 seconds"
        case .minutes1to2: "1–2 minutes"
        case .minutes2to5: "2–5 minutes"
        case .minutes5to10: "5–10 minutes"
        case .minutes10to15: "10–15 minutes"
        case .minutes15to30: "15–30 minutes"
        }
    }
}
