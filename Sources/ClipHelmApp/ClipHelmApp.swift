import SwiftUI

enum AppRoute: String, Hashable {
    case home, recent, newProject, settings, workspace
}

enum WizardStep: Int, CaseIterable, Identifiable {
    case source, format, framing, smartEditing, length, number, sound, captions, models, review, process

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .source: "Source"
        case .format: "Destination"
        case .framing: "Framing"
        case .smartEditing: "Smart Editing"
        case .length: "Length"
        case .number: "Number of Clips"
        case .sound: "Sound"
        case .captions: "Captions"
        case .models: "AI Models"
        case .review: "Review Settings"
        case .process: "Create"
        }
    }
}

@MainActor
final class NavigationState: ObservableObject {
    private let defaults: UserDefaults
    @Published var route: AppRoute {
        didSet { defaults.set(route.rawValue, forKey: "route") }
    }
    @Published var selectedProjectID: UUID? {
        didSet { defaults.set(selectedProjectID?.uuidString, forKey: "selectedProjectID") }
    }
    @Published var inspectorVisible: Bool {
        didSet { defaults.set(inspectorVisible, forKey: "inspectorVisible") }
    }
    @Published var step: WizardStep = .source

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        route = AppRoute(rawValue: defaults.string(forKey: "route") ?? "") ?? .home
        selectedProjectID = defaults.string(forKey: "selectedProjectID").flatMap(UUID.init(uuidString:))
        inspectorVisible = defaults.object(forKey: "inspectorVisible") as? Bool ?? true
    }

    func openProject(_ id: UUID) {
        selectedProjectID = id
        route = .workspace
    }

    func startProject() {
        step = .source
        route = .newProject
    }
}

@main
struct ClipHelmApp: App {
    @StateObject private var navigation = NavigationState()

    var body: some Scene {
        Window("ClipHelm", id: "main") {
            AppShell(navigation: navigation)
                .frame(minWidth: 780, minHeight: 560)
                .tint(DS.accent)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Clip Project") { navigation.startProject() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Home") { navigation.route = .home }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Recent Projects") { navigation.route = .recent }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Settings") { navigation.route = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Toggle Inspector") { navigation.inspectorVisible.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}
