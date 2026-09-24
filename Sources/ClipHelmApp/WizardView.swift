import SwiftUI
import UniformTypeIdentifiers
import ClipHelmCore

struct WizardView: View {
    @Binding var draft: ProjectDraft
    @Binding var step: WizardStep
    let onSave: () -> Void
    @State private var showsImporter = false

    private let framingModes: [FramingMode] = [.smartAuto, .fullFrame, .classicFullFrame, .blurred]
    private let captionStyles: [CaptionStyle] = [.pop, .spotlight, .impact, .glowBox,
                                                  .editorial, .highPunch, .neonHeadline, .paper]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("STEP \(step.rawValue + 1) OF \(WizardStep.allCases.count)")
                    .font(.caption.weight(.semibold)).tracking(1.8).foregroundStyle(.secondary)
                Text(step.title).font(.system(size: 36, weight: .semibold))
                HStack(spacing: 5) {
                    ForEach(WizardStep.allCases) { item in
                        Capsule().fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.18))
                            .frame(height: 4)
                    }
                }
                stepContent.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 275, alignment: .topLeading)
                Divider()
                HStack {
                    Button("Back") { if let previous = WizardStep(rawValue: step.rawValue - 1) { step = previous } }
                        .disabled(step == .source).keyboardShortcut("[", modifiers: .command)
                    Spacer()
                    if step == .process {
                        Button("Save Draft Project", action: onSave)
                            .buttonStyle(.borderedProminent).disabled(draft.sourceLabel == nil)
                    } else {
                        Button("Continue") { if let next = WizardStep(rawValue: step.rawValue + 1) { step = next } }
                            .buttonStyle(.borderedProminent)
                            .disabled(step == .source && draft.sourceLabel == nil)
                            .keyboardShortcut("]", modifiers: .command)
                    }
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 760, alignment: .leading).padding(42)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $showsImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie]) { result in
            if case .success(let url) = result { draft.sourceName = url.lastPathComponent }
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .source:
            VStack(alignment: .leading, spacing: 16) {
                Picker("Source", selection: $draft.sourceKind) {
                    ForEach(SourceKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }.pickerStyle(.segmented)
                if draft.sourceKind == .local {
                    Button("Choose Video…") { showsImporter = true }
                    Text(draft.sourceName.isEmpty ? "MP4, MKV, or MOV" : draft.sourceName)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("https://…", text: $draft.remoteURL).textFieldStyle(.roundedBorder)
                    Text("Use media you own or have permission to process.").foregroundStyle(.secondary)
                }
            }
        case .format:
            Picker("Output format", selection: $draft.preset) {
                ForEach(CanvasPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }.pickerStyle(.radioGroup)
        case .framing:
            Picker("Framing mode", selection: $draft.framingMode) {
                ForEach(framingModes, id: \.self) { mode in Text(mode.label).tag(mode) }
            }.pickerStyle(.radioGroup)
        case .length:
            VStack(alignment: .leading) {
                Text("No selection means unrestricted length.").foregroundStyle(.secondary)
                ForEach(ClipLength.allCases, id: \.self) { length in
                    Toggle(length.label, isOn: Binding(
                        get: { draft.lengths.contains(length) },
                        set: { if $0 { draft.lengths.insert(length) } else { draft.lengths.remove(length) } }))
                }
            }
        case .captions:
            VStack(alignment: .leading) {
                Toggle("Create captions when speech is present", isOn: $draft.captionsEnabled)
                if draft.captionsEnabled {
                    Picker("Style", selection: $draft.captionStyle) {
                        ForEach(captionStyles, id: \.self) { style in Text(style.label).tag(style) }
                    }
                }
            }
        case .review:
            VStack(alignment: .leading, spacing: 12) {
                TextField("Project name", text: $draft.title).textFieldStyle(.roundedBorder)
                LabeledContent("Source", value: draft.sourceLabel ?? "No source selected")
                LabeledContent("Format", value: draft.preset.rawValue)
                LabeledContent("Framing", value: draft.framingMode.label)
                LabeledContent("Captions", value: draft.captionsEnabled ? draft.captionStyle.label : "Off")
            }
        case .process:
            VStack(alignment: .leading, spacing: 12) {
                Label("Ready to save as a draft", systemImage: "checkmark.circle")
                Text("Processing arrives in a later phase.").foregroundStyle(.secondary)
            }
        }
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
