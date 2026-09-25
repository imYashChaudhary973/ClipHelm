import SwiftUI
import ClipHelmCore
import ClipHelmSources
import ClipHelmProcessing

struct AppShell: View {
    @ObservedObject var navigation: NavigationState
    @StateObject private var store: ProjectStore
    @State private var draft = ProjectDraft()
    @State private var errorMessage = ""
    @State private var showsError = false
    @State private var sourceIngestor = SourceIngestor()
    @State private var sessionSources: [ProjectID: PreparedSource] = [:]

    init(navigation: NavigationState, store: ProjectStore = ProjectStore()) {
        self.navigation = navigation
        _store = StateObject(wrappedValue: store)
    }

    private var selectedProject: ProjectRecord? {
        store.projects.first { $0.id.rawValue == navigation.selectedProjectID }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { navigation.route == .workspace && navigation.inspectorVisible },
            set: { navigation.inspectorVisible = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.route) {
                Section {
                    Label("Home", systemImage: "house").tag(AppRoute.home)
                    Label("Recent Projects", systemImage: "clock.arrow.circlepath").tag(AppRoute.recent)
                    Label("New Clip Project", systemImage: "plus.square.on.square").tag(AppRoute.newProject)
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(AppRoute.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            Group {
                switch navigation.route {
                case .home: home
                case .recent: recent
                case .newProject:
                    WizardView(draft: $draft, step: $navigation.step,
                               ingestor: sourceIngestor, onSave: saveDraft)
                case .settings: settings
                case .workspace:
                    if let selectedProject {
                        workspace(selectedProject)
                    } else {
                        ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark",
                                               description: Text("Choose a project from Recent Projects."))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if navigation.route == .workspace {
                        Button {
                            navigation.inspectorVisible.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help("Show or hide the inspector (⌘I)")
                    } else {
                        Button {
                            navigation.startProject()
                        } label: {
                            Label("New Clip Project", systemImage: "plus")
                        }
                        .help("New Clip Project (⌘N)")
                    }
                }
            }
        }
        .inspector(isPresented: inspectorBinding) {
            if let selectedProject {
                inspector(selectedProject)
            }
        }
        .alert("Could not save project", isPresented: $showsError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: "draftPreferences"),
               let restored = try? JSONDecoder().decode(ProjectDraft.self, from: data) {
                draft = restored
            }
            if navigation.route == .workspace && selectedProject == nil {
                navigation.route = .recent
            }
        }
        .onChange(of: draft) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "draftPreferences")
            }
        }
    }

    private var title: String {
        switch navigation.route {
        case .home: "Home"
        case .recent: "Recent Projects"
        case .newProject: "New Clip Project"
        case .settings: "Settings"
        case .workspace: selectedProject?.title ?? "Project Workspace"
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("CLIPHELM")
                    .font(.caption.weight(.semibold))
                    .tracking(2.5)
                    .foregroundStyle(.secondary)
                Text("A better cut starts\nwith the right moment.")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .tracking(-1.5)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Set the source and the edit direction. ClipHelm will bring the best moments into a workspace you can review.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
                Button("New Clip Project") {
                    navigation.startProject()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)

                Divider().padding(.vertical, 18)
                HStack {
                    Text("Recent Projects").font(.title2.weight(.semibold))
                    Spacer()
                    Button("View All") { navigation.route = .recent }
                        .buttonStyle(.link)
                }
                if store.projects.isEmpty {
                    Text("Your projects will appear here after you save a draft.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                } else {
                    ForEach(store.projects.prefix(3)) { project in
                        projectRow(project)
                    }
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recent: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects Yet", systemImage: "film.stack")
                } description: {
                    Text("Start a new clip project to create a workspace.")
                } actions: {
                    Button("New Clip Project") {
                        navigation.startProject()
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RECENT PROJECTS")
                            .font(.caption.weight(.semibold))
                            .tracking(1.6)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 16)
                        ForEach(store.projects) { project in
                            projectRow(project)
                        }
                    }
                    .frame(maxWidth: 800, alignment: .leading)
                    .padding(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overlay(alignment: .top) {
            if let loadError = store.loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(12)
            }
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        Button {
            navigation.openProject(project.id.rawValue)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "film.stack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.headline)
                    Text("\(project.sourceLabel) · \(project.clips.isEmpty ? "Draft project" : "\(project.clips.count) clips")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(project.createdAt, style: .date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(project.title)")
        .overlay(alignment: .bottom) { Divider() }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Settings")
                    .font(.largeTitle.weight(.semibold))
                LabeledContent("Appearance", value: "Follows macOS")
                Divider()
                LabeledContent("Project storage", value: "Application Support / ClipHelm / Projects")
                Text("Project drafts and source metadata are saved on this Mac. Source access must be granted again after relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                OpenRouterSettingsView()
                Divider()
                Text("Keyboard Shortcuts").font(.headline)
                LabeledContent("New project", value: "⌘N")
                LabeledContent("Home / Recent", value: "⌘1 / ⌘2")
                LabeledContent("Inspector", value: "⌘I")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func workspace(_ project: ProjectRecord) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.title2.weight(.semibold))
                    Text(project.clips.isEmpty ? "Project workspace" : "\(project.clips.count) clips saved")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Saved", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            if !project.clips.isEmpty {
                results(project)
                Divider()
            }
            WorkspacePlaybackView(project: project, source: sessionSources[project.id],
                analysisCacheDirectory: try? store.analysisCacheDirectory(for: project.id),
                exportsDirectory: try? store.exportsDirectory(for: project.id),
                ingestor: sourceIngestor,
                saveTranscript: { try store.saveTranscript($0, for: project.id) },
                saveProcessingResult: { try store.saveProcessingResult($0, for: project.id) },
                reattachSource: { try await reattachSource($0, to: project) },
                reattachRemote: { try await reattachRemote($0, authorized: $1,
                    to: project, progress: $2) })
            if project.clips.isEmpty {
                Divider()
                results(project)
            }
        }
        .padding(24)
        }
    }

    private func results(_ project: ProjectRecord) -> some View {
        ClipResultsView(project: project, source: sessionSources[project.id],
            exportsDirectory: try? store.exportsDirectory(for: project.id),
            cacheDirectory: try? store.analysisCacheDirectory(for: project.id),
            saveClip: { try store.updateClip($0, for: project.id) },
            deleteClip: { try store.deleteClip($0, from: project.id) })
    }

    private func inspector(_ project: ProjectRecord) -> some View {
        Form {
            Section("Project") {
                LabeledContent("Status", value: project.clips.isEmpty ? "Draft" : "\(project.clips.count) clips saved")
                LabeledContent("Source", value: project.sourceLabel)
                LabeledContent("Type", value: project.sourceKind.rawValue)
                if let asset = project.mediaAsset {
                    LabeledContent("Source size", value: "\(asset.width) × \(asset.height)")
                    LabeledContent("Duration", value: Self.durationLabel(asset.duration))
                }
            }
            Section("Output") {
                LabeledContent("Canvas", value: "\(project.outputFormat.width) × \(project.outputFormat.height)")
                LabeledContent("Framing", value: project.framingMode.label)
                LabeledContent("Pacing", value: project.configuration.pacingMode.label)
                LabeledContent("Number", value: project.configuration.requestedClipCount.map { "Up to \($0)" } ?? "AI decides")
                LabeledContent("Sound", value: project.configuration.soundMode == .normalize ? "Normalize" : "Original")
                LabeledContent("Captions", value: project.captionStyle?.label ?? "Off")
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
    }

    private func saveDraft(source: PreparedSource?) {
        do {
            let project = try store.save(draft: draft, mediaAsset: source?.asset)
            if let source { sessionSources[project.id] = source }
            draft = ProjectDraft()
            navigation.openProject(project.id.rawValue)
        } catch {
            errorMessage = "Check the source and project name, then try again."
            showsError = true
        }
    }

    private func reattachSource(_ url: URL, to project: ProjectRecord) async throws {
        guard project.sourceKind == .local, let original = project.mediaAsset,
              url.lastPathComponent == project.sourceLabel else {
            throw SourceIngestError.invalidMedia
        }
        let prepared = try await sourceIngestor.prepare(SourceDescriptor(localFile: url))
        guard prepared.asset.duration == original.duration,
              prepared.asset.width == original.width,
              prepared.asset.height == original.height else {
            throw SourceIngestError.invalidMedia
        }
        sessionSources[project.id] = PreparedSource(descriptor: prepared.descriptor,
            fileURL: prepared.fileURL, asset: original, hasAudio: prepared.hasAudio)
    }

    private func reattachRemote(_ rawURL: String, authorized: Bool,
                                to project: ProjectRecord,
                                progress: @escaping @Sendable (SourceProgress) -> Void) async throws {
        guard project.sourceKind != .local, let original = project.mediaAsset else {
            throw SourceIngestError.invalidMedia
        }
        let descriptor = try SourceDescriptor(remoteURL: rawURL,
            youtube: project.sourceKind == .youtube, authorized: authorized)
        guard URLComponents(string: rawURL)?.host?.lowercased() == project.sourceLabel else {
            throw SourceIngestError.invalidMedia
        }
        let prepared = try await sourceIngestor.prepare(descriptor, progress: progress)
        try Task.checkCancellation()
        guard prepared.asset.duration == original.duration,
              prepared.asset.width == original.width,
              prepared.asset.height == original.height else {
            throw SourceIngestError.invalidMedia
        }
        sessionSources[project.id] = PreparedSource(descriptor: descriptor,
            fileURL: prepared.fileURL, asset: original, hasAudio: prepared.hasAudio)
    }

    private static func durationLabel(_ duration: MediaTime) -> String {
        let seconds = duration.microseconds / 1_000_000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

extension FramingMode {
    var label: String {
        switch self {
        case .smartAuto: "Smart Auto Frame"
        case .fullFrame: "Full Frame"
        case .classicFullFrame: "Classic Full Frame"
        case .blurred: "Blurred"
        }
    }

    var description: String {
        switch self {
        case .smartAuto: "Follow the subject and important on-screen content."
        case .fullFrame: "Fill the canvas while keeping important content in view."
        case .classicFullFrame: "Keep the complete original frame, adding bars when needed."
        case .blurred: "Keep the full frame over a soft, blurred background."
        }
    }
}

extension PacingMode {
    var label: String { rawValue.capitalized }
}

extension CaptionStyle {
    var label: String {
        switch self {
        case .pop: "Pop"
        case .spotlight: "Spotlight"
        case .impact: "Impact"
        case .glowBox: "Glow Box"
        case .editorial: "Editorial"
        case .highPunch: "High Punch"
        case .neonHeadline: "Neon Headline"
        case .paper: "Paper"
        }
    }
}
