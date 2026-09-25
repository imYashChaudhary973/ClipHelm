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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let framingModes: [FramingMode] = [.smartAuto, .fullFrame, .classicFullFrame, .blurred]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    PageHeader(eyebrow: "Step \(step.rawValue + 1) of \(WizardStep.allCases.count)",
                               title: step.title, subtitle: subtitle)
                    stepRail
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
                .readableColumn(DS.Width.form, padding: DS.Space.xl)
                .animation(reduceMotion ? nil : DS.Motion.standard, value: step)
            }
            Divider()
            footer
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.sm)
                .background(.bar)
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

    // MARK: Chrome

    /// Segmented progress. Completed steps are buttons so earlier choices are one click away.
    private var stepRail: some View {
        HStack(spacing: DS.Space.xxs) {
            ForEach(WizardStep.allCases) { item in
                let done = item.rawValue < step.rawValue
                let current = item == step
                Button {
                    step = item
                } label: {
                    Capsule()
                        .fill(done || current ? DS.accent : Color.secondary.opacity(0.18))
                        .opacity(done ? 0.55 : 1)
                        .frame(height: current ? 6 : 4)
                        .frame(maxWidth: .infinity, minHeight: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!done)
                .help(item.title)
                .accessibilityLabel("Step \(item.rawValue + 1): \(item.title)")
                .accessibilityValue(done ? "Completed" : current ? "Current step" : "Not started")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.sm) {
            Button {
                if let previous = WizardStep(rawValue: step.rawValue - 1) { step = previous }
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(step == .source)
            .keyboardShortcut("[", modifiers: .command)
            Spacer()
            if let blocker {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if step == .process {
                Button("Create Project") { onSave(prepared) }
                    .buttonStyle(.borderedProminent)
                    .disabled(prepared == nil)
            } else {
                Button("Continue") {
                    if let next = WizardStep(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocker != nil)
                .keyboardShortcut("]", modifiers: .command)
                .help(nextStepHint)
            }
        }
        .controlSize(.large)
    }

    /// Why the forward action is unavailable, shown next to it.
    private var blocker: String? {
        switch step {
        case .source where prepared == nil:
            preparing ? "Preparing video…" : "Choose a video to continue."
        case .number where draft.countMode != .aiDecides && !(1...1_000).contains(draft.requestedClipCount):
            "Enter a target from 1 to 1,000."
        case .review where !validTitle:
            "Name the project to continue."
        case .process where prepared == nil:
            "Choose a source video first."
        default:
            nil
        }
    }

    private var nextStepHint: String {
        WizardStep(rawValue: step.rawValue + 1).map { "Next: \($0.title) (⌘])" } ?? ""
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

    // MARK: Steps

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Picker("Source", selection: $draft.sourceKind) {
                ForEach(SourceKind.availableCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)
            .onChange(of: draft.sourceKind) { _, _ in resetSource() }

            if let asset = prepared?.asset {
                readyCard(asset)
            } else if draft.sourceKind == .local {
                dropZone
            } else {
                remoteForm
            }
            if preparing {
                TaskProgressRow(label: progressLabel, fraction: sourceProgress?.fraction,
                                onCancel: resetSource)
                    .surfaceCard()
            }
            if let sourceError {
                StatusMessage(text: sourceError, tone: .error)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "film.stack")
                .font(.system(size: 36))
                .foregroundStyle(dropTargeted ? DS.accent : Color.secondary)
                .accessibilityHidden(true)
            Text(dropTargeted ? "Release to prepare video" : "Drop a video file here")
                .font(.headline)
            Text("MP4, MKV, or MOV. The original file is never changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Video…") { showsImporter = true }
                .controlSize(.large)
                .disabled(preparing)
                .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(dropTargeted ? DS.accent.opacity(0.08) : DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(dropTargeted ? DS.accent : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 4]))
        }
        .animation(reduceMotion ? nil : DS.Motion.quick, value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: \.isFileURL) else { return false }
            prepareLocal(file)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var remoteForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Video link").font(.headline)
            TextField("https://…", text: $draft.remoteURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(draft.sourceKind.rawValue)
                .onChange(of: draft.remoteURL) { _, _ in resetSource() }
                .onSubmit { if canPrepareRemote { prepareRemote() } }
            Toggle("I own this video or have permission to process it", isOn: $authorizedRemote)
                .onChange(of: authorizedRemote) { _, _ in resetSource() }
            Button("Prepare Source") { prepareRemote() }
                .disabled(!canPrepareRemote)
            Divider()
            StatusMessage(text: draft.sourceKind == .youtube
                          ? "Use a YouTube link for media you own or may process."
                          : "Use an HTTPS direct video link you are authorized to process.",
                          tone: .info)
            StatusMessage(text: "Public links only. Private, protected, and sign-in-only media are not imported.",
                          tone: .neutral)
        }
        .surfaceCard()
    }

    private var canPrepareRemote: Bool {
        !preparing && !draft.remoteURL.isEmpty && authorizedRemote
    }

    private func readyCard(_ asset: MediaAsset) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready: \(asset.displayName)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(mediaSummary(asset))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.xs)
            Button(draft.sourceKind == .local ? "Replace…" : "Use Another Link") {
                if draft.sourceKind == .local { showsImporter = true } else { resetSource() }
            }
        }
        .surfaceCard(highlighted: true)
        .accessibilityElement(children: .contain)
    }

    private func mediaSummary(_ asset: MediaAsset) -> String {
        var parts = ["\(asset.width) × \(asset.height)",
                     "\(Int(asset.duration.microseconds / 1_000_000)) seconds"]
        if prepared?.hasAudio == false { parts.append("No audio track") }
        return parts.joined(separator: " · ")
    }

    private var formatContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            OptionCardGrid(options: CanvasPreset.allCases, selection: $draft.preset,
                title: { $0.rawValue },
                detail: { $0 == .vertical
                    ? "A tall canvas for vertical feeds and stories."
                    : "A wide canvas for landscape viewing." },
                systemImage: { $0 == .vertical ? "rectangle.portrait" : "rectangle" })
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Export resolution").font(.headline)
                Picker("Export resolution", selection: $draft.resolution) {
                    ForEach(RenderResolution.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
                if draft.resolution == .uhd4k {
                    StatusMessage(text: "4K takes more time and disk space; the source should be 4K for full detail.",
                                  tone: .info)
                }
            }
        }
    }

    private var framingContent: some View {
        OptionCardGrid(options: framingModes, selection: $draft.framingMode,
            minimumWidth: 260,
            title: { $0.label },
            detail: { $0.description },
            systemImage: { $0.symbol })
    }

    private var smartEditingContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ToggleRow(title: "Cut dead air", detail: "Remove silent stretches between moments.",
                          systemImage: "scissors", isOn: $draft.smartEdit.cutDeadAir)
                Divider()
                ToggleRow(title: "Trim long pauses", detail: "Shorten long gaps between sentences.",
                          systemImage: "pause", isOn: $draft.smartEdit.trimLongPauses)
                Divider()
                ToggleRow(title: "Filter filler words",
                          detail: "Cut “um”, “uh”, and similar fillers when word timing allows.",
                          systemImage: "text.badge.minus", isOn: $draft.smartEdit.cleanFillers)
                Divider()
                ToggleRow(title: "Keep demos",
                          detail: "Protect screen demos and slides from cuts and keep them readable.",
                          systemImage: "display", isOn: $draft.smartEdit.keepDemos)
                Divider()
                ToggleRow(title: "Check tricky shots with AI Vision",
                          detail: "Used only for uncertain shots. Sends frames to OpenRouter and uses API credits.",
                          systemImage: "eye", isOn: $draft.smartEdit.useVisionForTrickyShots)
            }
            .surfaceCard()
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Pacing").font(.headline)
                OptionCardGrid(options: PacingMode.allCases, selection: $draft.pacingMode,
                    minimumWidth: 240, title: { $0.label }, detail: { $0.detail })
            }
            StatusMessage(text: "These choices guide later editing; no edits run during setup.", tone: .neutral)
        }
    }

    private var lengthContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            UniformGrid(minimumWidth: 190) {
                ForEach(ClipLength.allCases, id: \.self) { length in
                    let selected = draft.lengths.contains(length)
                    OptionCard(title: length.label, isSelected: selected, multiple: true) {
                        if selected { draft.lengths.remove(length) } else { draft.lengths.insert(length) }
                    }
                }
            }
            HStack {
                StatusMessage(text: draft.lengths.isEmpty
                              ? "Nothing selected means Any Length."
                              : "\(draft.lengths.count) of \(ClipLength.allCases.count) ranges selected.",
                              tone: .neutral)
                Spacer()
                if !draft.lengths.isEmpty {
                    Button("Clear Selection") { draft.lengths.removeAll() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var numberContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            OptionCardGrid(options: ClipCountMode.allCases, selection: $draft.countMode,
                minimumWidth: 180,
                title: { $0.rawValue },
                detail: { mode in
                    switch mode {
                    case .aiDecides: "Keep every moment that meets the quality bar."
                    case .fixed: "Pick a common target: 1, 3, 5, or 10."
                    case .custom: "Enter any target from 1 to 1,000."
                    }
                },
                systemImage: { mode in
                    switch mode {
                    case .aiDecides: "sparkles"
                    case .fixed: "number"
                    case .custom: "keyboard"
                    }
                })
            .onChange(of: draft.countMode) { _, mode in
                if mode == .fixed && ![1, 3, 5, 10].contains(draft.requestedClipCount) {
                    draft.requestedClipCount = 3
                }
            }
            if draft.countMode == .fixed {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Target").font(.headline)
                    Picker("Target", selection: $draft.requestedClipCount) {
                        ForEach([1, 3, 5, 10], id: \.self) { count in
                            Text("\(count) \(count == 1 ? "clip" : "clips")").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                }
            } else if draft.countMode == .custom {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Target").font(.headline)
                    HStack {
                        TextField("Target", value: $draft.requestedClipCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("clips").foregroundStyle(.secondary)
                    }
                    if !(1...1_000).contains(draft.requestedClipCount) {
                        StatusMessage(text: "Enter a number from 1 to 1,000.", tone: .error)
                    }
                }
            }
            StatusMessage(text: "ClipHelm may return fewer clips if the source has fewer strong moments.",
                          tone: .info)
        }
    }

    private var soundContent: some View {
        OptionCardGrid(options: [SoundMode.source, .normalize], selection: $draft.soundMode,
            title: { $0 == .normalize ? "Normalize" : "Original" },
            detail: { $0 == .normalize
                ? "Aim for more consistent loudness across clips."
                : "Keep the source audio level." },
            systemImage: { $0 == .normalize ? "waveform" : "speaker.wave.2" })
    }

    private var captionContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            ToggleRow(title: "Create captions when speech is present",
                      detail: prepared?.hasAudio == false
                        ? "This source has no audio track, so captions started off."
                        : "Captions turn off if transcription finds no meaningful speech.",
                      systemImage: "captions.bubble", isOn: $draft.captionsEnabled)
                .surfaceCard()
            if draft.captionsEnabled {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text("Style").font(.headline)
                    UniformGrid(minimumWidth: 150) {
                        ForEach(CaptionStyle.pickerOrder, id: \.self) { style in
                            CaptionStyleCard(style: style, isSelected: draft.captionStyle == style) {
                                draft.captionStyle = style
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Effects").font(.headline)
                    HStack(spacing: DS.Space.lg) {
                        Toggle("Word-by-word animation", isOn: $draft.captionWordByWord)
                        Toggle("Blur-in", isOn: $draft.captionBlurIn)
                    }
                }
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Project name").font(.headline)
                TextField("Project name", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .labelsHidden()
                    .accessibilityLabel("Project name")
                if !validTitle {
                    StatusMessage(text: "Enter a project name of up to 200 characters.", tone: .error)
                }
            }
            VStack(spacing: 0) {
                reviewRow("Source", prepared.map { "\($0.asset.displayName) · \(mediaSummary($0.asset))" }
                          ?? "No source selected", edit: .source)
                reviewRow("Format", "\(draft.preset.rawValue) · \(draft.resolution.rawValue)", edit: .format)
                reviewRow("Framing", draft.framingMode.label, edit: .framing)
                reviewRow("Pacing", draft.pacingMode.label, edit: .smartEditing)
                reviewRow("Smart editing", smartEditSummary, edit: .smartEditing)
                reviewRow("Length", draft.lengths.isEmpty
                          ? "Any Length"
                          : ClipLength.allCases.filter { draft.lengths.contains($0) }.map(\.label).joined(separator: ", "),
                          edit: .length)
                reviewRow("Number", draft.countMode == .aiDecides
                          ? "AI decides" : "Up to \(draft.requestedClipCount)", edit: .number)
                reviewRow("Sound", draft.soundMode == .normalize ? "Normalize" : "Original", edit: .sound)
                reviewRow("Captions", draft.captionsEnabled
                          ? "\(draft.captionStyle.label)\(draft.captionWordByWord ? " · Word-by-word" : "")\(draft.captionBlurIn ? " · Blur-in" : "")"
                          : "Off", edit: .captions, last: true)
            }
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).strokeBorder(DS.hairline)
            }
        }
    }

    private func reviewRow(_ title: String, _ value: String, edit target: WizardStep,
                           last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Edit") { step = target }
                    .buttonStyle(.link)
                    .accessibilityLabel("Edit \(title)")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            if !last { Divider().padding(.leading, DS.Space.md) }
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
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if prepared != nil {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(draft.sourceKind == .local ? "Source ready" : "Download complete")
                            .font(.title3.weight(.semibold))
                        Text("Create the project to start transcription and clip generation.")
                            .foregroundStyle(.secondary)
                    }
                }
                .surfaceCard(padding: DS.Space.lg, highlighted: true)
            } else {
                HStack {
                    StatusMessage(text: "No source is prepared. Choose a video before creating the project.",
                                  tone: .warning)
                    Spacer()
                    Button("Go to Source") { step = .source }
                }
                .surfaceCard()
            }
            StatusMessage(text: "The original media stays untouched. ClipHelm saves source metadata, but source access must be granted again after relaunch.",
                          tone: .info)
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

extension FramingMode {
    var symbol: String {
        switch self {
        case .smartAuto: "viewfinder"
        case .fullFrame: "arrow.up.left.and.arrow.down.right"
        case .classicFullFrame: "rectangle.inset.filled"
        case .blurred: "camera.filters"
        }
    }
}
