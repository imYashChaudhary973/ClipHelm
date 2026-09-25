import SwiftUI
import ClipHelmSecurity
import ClipHelmOpenRouter

@MainActor
final class OpenRouterSettingsModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    private let vault: OpenRouterSecretVault
    private let gateway: any OpenRouterGateway

    init(vault: OpenRouterSecretVault = OpenRouterSecretVault()) {
        self.vault = vault
        gateway = LiveOpenRouterGateway(secrets: vault)
    }

    func refresh() async {
        let vault = self.vault
        do {
            connected = try await Task.detached { try vault.hasKey() }.value
        } catch {
            message = "The macOS Keychain is unavailable. Try again after unlocking this Mac."
        }
    }

    func save(_ key: String) async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        let vault = self.vault
        do {
            try await Task.detached { try vault.save(key) }.value
            connected = true
            message = "API key saved to macOS Keychain."
        } catch {
            message = safeMessage(for: error)
        }
    }

    func test() async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await gateway.testConnection()
            message = "Connection verified."
        } catch {
            message = safeMessage(for: error)
        }
    }

    func remove() async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        let vault = self.vault
        do {
            try await Task.detached { try vault.remove() }.value
            connected = false
            message = "API key removed from macOS Keychain."
        } catch {
            message = safeMessage(for: error)
        }
    }

    private func safeMessage(for error: Error) -> String {
        if let known = error as? OpenRouterSecretError { return known.localizedDescription }
        if let known = error as? OpenRouterGatewayError { return known.localizedDescription }
        return "The operation could not be completed. Try again."
    }
}

struct OpenRouterSettingsView: View {
    @StateObject private var model = OpenRouterSettingsModel()
    @State private var showingKeySheet = false
    @State private var showingRemoveConfirmation = false
    @State private var replacing = false
    @State private var keyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                StatusBadge(text: model.connected ? "Connected" : "Not connected",
                            tone: model.connected ? .success : .neutral)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if model.connected {
                    Button("Test") { Task { await model.test() } }
                    Button("Replace…") { presentKeySheet(replacing: true) }
                    Button("Remove…", role: .destructive) { showingRemoveConfirmation = true }
                } else {
                    Button("Add API Key…") { presentKeySheet(replacing: false) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .disabled(model.isBusy)
            if let message = model.message {
                StatusMessage(text: message, tone: .info)
            }
            Text("Your API key is stored only in macOS Keychain. Test checks the key without running a model.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task { await model.refresh() }
        .sheet(isPresented: $showingKeySheet, onDismiss: { keyInput = "" }) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(replacing ? "Replace API Key" : "Add API Key")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                SecureField("OpenRouter API key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("OpenRouter API key")
                Text("ClipHelm saves this key in macOS Keychain. It is not added to projects or preferences.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showingKeySheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let key = keyInput
                        keyInput = ""
                        showingKeySheet = false
                        Task { await model.save(key) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyInput.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Space.lg)
            .frame(width: 440)
        }
        .confirmationDialog("Remove OpenRouter API key?", isPresented: $showingRemoveConfirmation) {
            Button("Remove API Key", role: .destructive) { Task { await model.remove() } }
        } message: {
            Text("ClipHelm will no longer be connected until you add a key again.")
        }
    }

    private func presentKeySheet(replacing: Bool) {
        self.replacing = replacing
        keyInput = ""
        showingKeySheet = true
    }
}
