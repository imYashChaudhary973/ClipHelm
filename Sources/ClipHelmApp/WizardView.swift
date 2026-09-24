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
                        Button("Save Draft Project") { onSave(prepared) }
                            .buttonStyle(.borderedProminent)
                            .disabled(prepared == nil)
                    } else {
                        Button("Continue") {
                            if let next = WizardStep(rawValue: step.rawValue + 1) { step = next }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(step == .source && prepared == nil)
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
        case .format: "Choose where the final clips will be seen."
        case .framing: "Decide how source footage fits the output canvas."
        case .length: "Choose one or more ranges, or leave them open."
        case .captions: "Choose a starting style for speech captions."
        case .review: "Check the direction before saving a project draft."
        case .process: "Your draft is ready. Processing is coming in a later phase."
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .source: sourceContent
        case .format: formatContent
        case .framing: framingContent
        case .length: lengthContent
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
            Text(draft.preset == .vertical
                 ? "A tall canvas for vertical feeds and stories."
                 : "A wide canvas for landscape viewing.")
                .foregroundStyle(.secondary)
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

    private var lengthContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip lengths").font(.headline)
            Text("Select any combination. No selection means unrestricted length.")
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

    private var captionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Create captions when speech is present", isOn: $draft.captionsEnabled)
            if draft.captionsEnabled {
                Picker("Style", selection: $draft.captionStyle) {
                    ForEach(captionStyles, id: \.self) { style in Text(style.label).tag(style) }
                }
                .frame(maxWidth: 340)
            }
            Text("Captions will stay off when no meaningful speech is found. Word animation and blur-in are planned for processing.")
                .foregroundStyle(.secondary)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Project name", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            Divider()
            LabeledContent("Source", value: prepared?.asset.displayName ?? "No source selected")
            if let asset = prepared?.asset {
                LabeledContent("Source media", value: "\(asset.width) × \(asset.height) · \(Int(asset.duration.microseconds / 1_000_000)) seconds")
            }
            LabeledContent("Format", value: draft.preset.rawValue)
            LabeledContent("Framing", value: draft.framingMode.label)
            LabeledContent("Length", value: draft.lengths.isEmpty
                           ? "Unrestricted"
                           : ClipLength.allCases.filter { draft.lengths.contains($0) }.map(\.label).joined(separator: ", "))
            LabeledContent("Captions", value: draft.captionsEnabled ? draft.captionStyle.label : "Off")
        }
    }

    private var processContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to save as a draft", systemImage: "checkmark.circle")
                .font(.title3.weight(.medium))
            Text("Saving opens the project workspace with source playback. Clip processing and export are not active yet.")
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
