import SwiftUI
import ClipHelmCore

struct AppShell: View {
    @ObservedObject var navigation: NavigationState
    @StateObject private var store: ProjectStore
    @State private var draft = ProjectDraft()
    @State private var errorMessage = ""
    @State private var showsError = false

    init(navigation: NavigationState, store: ProjectStore = ProjectStore()) {
        self.navigation = navigation
        _store = StateObject(wrappedValue: store)
    }

    private var selectedProject: ProjectRecord? {
        store.projects.first { $0.id.rawValue == navigation.selectedProjectID }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { navigation.route == .workspace && navigation.inspectorVisible },
                set: { navigation.inspectorVisible = $0 })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.route) {
                Section {
                    Label("Home", systemImage: "house").tag(AppRoute.home)
                    Label("Recent Projects", systemImage: "clock.arrow.circlepath").tag(AppRoute.recent)
                    Label("New Clip Project", systemImage: "plus.square.on.square").tag(AppRoute.newProject)
                }
                Section { Label("Settings", systemImage: "gearshape").tag(AppRoute.settings) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            Group {
                switch navigation.route {
                case .home: home
                case .recent: recent
                case .newProject: WizardView(draft: $draft, step: $navigation.step, onSave: saveDraft)
                case .settings: settings
                case .workspace:
                    if let selectedProject { workspace(selectedProject) }
                    else { ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if navigation.route == .workspace {
                        Button { navigation.inspectorVisible.toggle() } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help("Show or hide the inspector (⌘I)")
                    } else {
                        Button { navigation.startProject() } label: {
                            Label("New Clip Project", systemImage: "plus")
                        }
                        .help("New Clip Project (⌘N)")
                    }
                }
            }
        }
        .inspector(isPresented: inspectorBinding) {
            if let selectedProject { inspector(selectedProject) }
        }
        .alert("Could not save project", isPresented: $showsError) {
            Button("OK", role: .cancel) { }
        } message: { Text(errorMessage) }
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: "draftPreferences"),
               let restored = try? JSONDecoder().decode(ProjectDraft.self, from: data) { draft = restored }
            if navigation.route == .workspace && selectedProject == nil { navigation.route = .recent }
        }
        .onChange(of: draft) { _, value in
            if let data = try? JSONEncoder().encode(value) {
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
                Text("CLIPHELM").font(.caption.weight(.semibold)).tracking(2.5).foregroundStyle(.secondary)
                Text("A better cut starts\nwith the right moment.")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                Text("Set the source and edit direction, then save a project draft.")
                    .font(.title3).foregroundStyle(.secondary)
                Button("New Clip Project") { navigation.startProject() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Divider().padding(.vertical, 18)
                Text("Recent Projects").font(.title2.weight(.semibold))
                ForEach(store.projects.prefix(3)) { project in projectRow(project) }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(48).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recent: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView("No Projects Yet", systemImage: "film.stack",
                    description: Text("Start a new clip project to create a workspace."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RECENT PROJECTS").font(.caption.weight(.semibold)).tracking(1.6)
                        ForEach(store.projects) { project in projectRow(project) }
                    }
                    .frame(maxWidth: 800, alignment: .leading)
                    .padding(40).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        Button { navigation.openProject(project.id.rawValue) } label: {
            HStack(spacing: 16) {
                Image(systemName: "film.stack").font(.title2).frame(width: 36)
                VStack(alignment: .leading) {
                    Text(project.title).font(.headline)
                    Text("\(project.sourceLabel) · Draft project")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(project.createdAt, style: .date).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Settings").font(.largeTitle.weight(.semibold))
                LabeledContent("Appearance", value: "Follows macOS")
                Divider()
                LabeledContent("Project storage", value: "Application Support / ClipHelm / Projects")
                OpenRouterSettingsView()
                Divider()
                Text("Keyboard Shortcuts").font(.headline)
                LabeledContent("New project", value: "⌘N")
                LabeledContent("Home / Recent", value: "⌘1 / ⌘2")
                LabeledContent("Inspector", value: "⌘I")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(40).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func workspace(_ project: ProjectRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(project.title).font(.title2.weight(.semibold))
                Text("Draft workspace").foregroundStyle(.secondary)
                Divider()
                Text("Timeline").font(.headline)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    .frame(height: 68)
                    .overlay { Text("Clips will appear here after processing").foregroundStyle(.secondary) }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inspector(_ project: ProjectRecord) -> some View {
        Form {
            Section("Project") {
                LabeledContent("Status", value: "Draft")
                LabeledContent("Source", value: project.sourceLabel)
                LabeledContent("Type", value: project.sourceKind.rawValue)
            }
            Section("Output") {
                LabeledContent("Canvas", value: "\(project.outputFormat.width) × \(project.outputFormat.height)")
                LabeledContent("Framing", value: project.framingMode.label)
                LabeledContent("Captions", value: project.captionStyle?.label ?? "Off")
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
    }

    private func saveDraft() {
        do {
            let project = try store.save(draft: draft)
            draft = ProjectDraft()
            navigation.openProject(project.id.rawValue)
        } catch {
            errorMessage = "Check the source and project name, then try again."
            showsError = true
        }
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
        case .classicFullFrame: "Keep the complete original frame, adding bars if needed."
        case .blurred: "Keep the full frame over a soft, blurred background."
        }
    }
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
