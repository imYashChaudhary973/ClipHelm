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
    @State private var autoProcessProjects: Set<ProjectID> = []

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
            SidebarView(navigation: navigation, projects: store.projects)
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
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(spacing: DS.Space.sm) {
                        AppLogo(size: 48)
                        Eyebrow("ClipHelm")
                    }
                    Text("A better cut starts\nwith the right moment.")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Paste a YouTube link for captioned clips in one step, or set up a project to shape every detail.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 600, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    QuickClipView(ingestor: sourceIngestor, onReady: startQuickProject)
                    HStack(spacing: DS.Space.sm) {
                        Text("Have a local file, or want to choose format, framing, and captions?")
                            .foregroundStyle(.secondary)
                        Button("New Clip Project…") {
                            navigation.startProject()
                        }
                        .help("Choose a local file or customize format, framing, length, and captions (⌘N)")
                    }
                    .font(.callout)
                }

                UniformGrid(minimumWidth: 200) {
                    howItWorks
                }

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack {
                        Text("Recent Projects").font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if !store.projects.isEmpty {
                            Button("View All") { navigation.route = .recent }
                                .buttonStyle(.link)
                        }
                    }
                    if store.projects.isEmpty {
                        StatusMessage(text: "Your projects will appear here after you create one.", tone: .neutral)
                            .padding(.vertical, DS.Space.xs)
                    } else {
                        projectList(Array(store.projects.prefix(3)))
                    }
                }
            }
            .readableColumn(DS.Width.form + 80, padding: DS.Space.xxl)
        }
    }

    @ViewBuilder
    private var howItWorks: some View {
        howItWorksStep(1, "Choose a source", "A local video or a YouTube link you may process.", "film")
        howItWorksStep(2, "Set the direction", "Format, framing, length, sound, and captions.", "slider.horizontal.3")
        howItWorksStep(3, "Review the clips", "Play, trim, reframe, and export what you keep.", "rectangle.stack.badge.play")
    }

    private func howItWorksStep(_ number: Int, _ title: String, _ detail: String,
                                _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(DS.accent)
                .frame(height: 28, alignment: .leading)
                .accessibilityHidden(true)
            Text("\(number). \(title)").font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Projects Yet")
                    } icon: {
                        AppLogo(size: 64)
                    }
                } description: {
                    Text("Start a new clip project to create a workspace.")
                } actions: {
                    Button("New Clip Project") {
                        navigation.startProject()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        PageHeader(title: "Recent Projects",
                                   subtitle: "\(store.projects.count) \(store.projects.count == 1 ? "project" : "projects") saved on this Mac")
                        projectList(store.projects)
                    }
                    .readableColumn(DS.Width.form + 80, padding: DS.Space.xl)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let loadError = store.loadError {
                StatusMessage(text: loadError, tone: .warning)
                    .padding(DS.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    private func projectList(_ projects: [ProjectRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                if index > 0 { Divider().padding(.leading, 64) }
                projectRow(project)
            }
        }
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.hairline)
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        ProjectRow(project: project) { navigation.openProject(project.id.rawValue) }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                PageHeader(title: "Settings")
                settingsGroup("General", systemImage: "gearshape") {
                    LabeledContent("Appearance", value: "Follows macOS")
                    Divider()
                    LabeledContent("Project storage", value: "Application Support / ClipHelm / Projects")
                    Text("Project drafts and source metadata are saved on this Mac. Source access must be granted again after relaunch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settingsGroup("OpenRouter", systemImage: "key") {
                    OpenRouterSettingsView()
                }
                settingsGroup("YouTube Downloader", systemImage: "arrow.down.circle") {
                    YouTubeToolSettingsView()
                }
                settingsGroup("About", systemImage: "info.circle") {
                    HStack(spacing: DS.Space.md) {
                        AppLogo(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ClipHelm").font(.title3.weight(.semibold))
                            Text(Self.versionLabel).foregroundStyle(.secondary)
                        }
                    }
                }
                settingsGroup("Keyboard Shortcuts", systemImage: "keyboard") {
                    shortcut("New project", "⌘N")
                    shortcut("Home / Recent Projects", "⌘1 / ⌘2")
                    shortcut("Settings", "⌘,")
                    shortcut("Toggle inspector", "⌘I")
                    shortcut("Previous / next setup step", "⌘[ / ⌘]")
                }
            }
            .readableColumn(DS.Width.form, padding: DS.Space.xl)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, systemImage: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.Space.sm) { content() }
                .surfaceCard()
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func workspace(_ project: ProjectRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                PageHeader(eyebrow: project.sourceLabel, title: project.title) {
                    StatusBadge(text: project.clips.isEmpty ? "Draft" : "\(project.clips.count) clips saved",
                                tone: project.clips.isEmpty ? .neutral : .success)
                }
                if !project.clips.isEmpty {
                    results(project)
                }
                WorkspacePlaybackView(project: project, source: sessionSources[project.id],
                    analysisCacheDirectory: try? store.analysisCacheDirectory(for: project.id),
                    exportsDirectory: try? store.exportsDirectory(for: project.id),
                    ingestor: sourceIngestor,
                    autoProcess: autoProcessProjects.contains(project.id),
                    didStartAutoProcess: { autoProcessProjects.remove(project.id) },
                    saveTranscript: { try store.saveTranscript($0, for: project.id) },
                    saveProcessingResult: { try store.saveProcessingResult($0, for: project.id) },
                    reattachSource: { try await reattachSource($0, to: project) },
                    reattachRemote: { try await reattachRemote($0, authorized: $1,
                        to: project, progress: $2) })
                if project.clips.isEmpty {
                    results(project)
                }
            }
            .readableColumn(DS.Width.content, padding: DS.Space.lg)
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

    /// Creates a project from the saved clip preferences and starts processing it in the workspace.
    private func startQuickProject(_ source: PreparedSource, link: String) {
        var quick = draft
        quick.sourceKind = .youtube
        quick.remoteURL = link
        quick.sourceName = ""
        quick.title = source.title ?? "YouTube Clips"
        quick.captionsEnabled = quick.captionsEnabled && source.hasAudio
        do {
            let project = try store.save(draft: quick, mediaAsset: source.asset)
            sessionSources[project.id] = source
            autoProcessProjects.insert(project.id)
            navigation.openProject(project.id.rawValue)
        } catch {
            errorMessage = "The project could not be created. Check available disk space and try again."
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

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    private static func durationLabel(_ duration: MediaTime) -> String {
        let seconds = duration.microseconds / 1_000_000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct ProjectRow: View {
    let project: ProjectRecord
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: project.outputFormat.height > project.outputFormat.width
                      ? "rectangle.portrait" : "rectangle")
                    .font(.title3)
                    .foregroundStyle(DS.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.accent.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title).font(.headline).lineLimit(1)
                    Text("\(project.sourceLabel) · \(project.clips.isEmpty ? "Draft" : "\(project.clips.count) clips")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Space.xs)
                Text(project.createdAt, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.sm)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(project.title)
        .accessibilityLabel("Open \(project.title)")
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
