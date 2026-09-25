import SwiftUI
import ClipHelmSecurity
import ClipHelmOpenRouter
import ClipHelmSources

@MainActor
final class QuickClipModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case savingKey
        case installingTool
        case downloading(Double?)
        case preparing
    }

    @Published var link = ""
    @Published var authorized = false
    @Published var keyInput = ""
    @Published private(set) var hasKey = true
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var message: String?

    private let vault = OpenRouterSecretVault()
    private var job: Task<Void, Never>?

    var busy: Bool { stage != .idle }

    func refresh() async {
        let vault = self.vault
        hasKey = (try? await Task.detached { try vault.hasKey() }.value) ?? false
    }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        keyInput = ""
        guard !key.isEmpty else { return }
        stage = .savingKey
        message = nil
        let vault = self.vault
        job = Task {
            do {
                try await Task.detached { try vault.save(key) }.value
                try await LiveOpenRouterGateway(secrets: vault).testConnection()
                hasKey = true
                message = "Key saved and verified."
            } catch let error as OpenRouterSecretError {
                message = error.localizedDescription
            } catch let error as OpenRouterGatewayError {
                hasKey = true
                message = error.localizedDescription
            } catch {
                message = "The key could not be saved. Try again."
            }
            stage = .idle
        }
    }

    /// Validates the link; the download itself starts in the pipeline.
    func descriptor() -> SourceDescriptor? {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let descriptor = try SourceDescriptor(remoteURL: raw, youtube: true, authorized: authorized)
            message = nil
            return descriptor
        } catch let error as SourceIngestError {
            message = error == .unsupportedSource
                ? "Paste a YouTube video link, such as https://www.youtube.com/watch?v=…"
                : error.localizedDescription
        } catch {
            message = "Paste a YouTube video link."
        }
        return nil
    }
}

/// Paste a key and a YouTube link; the download starts while clip options are chosen.
struct QuickClipView: View {
    /// Receives the validated link and its descriptor.
    let onContinue: @MainActor (String, SourceDescriptor) -> Void
    @StateObject private var model = QuickClipModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label {
                Text("Clip a YouTube video").font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(DS.brandGradient)
            }
            .accessibilityAddTraits(.isHeader)
            if !model.hasKey {
                Text("Step 1 · Paste your OpenRouter API key. It is stored only in macOS Keychain.")
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("OpenRouter API key", text: $model.keyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("OpenRouter API key")
                        .onSubmit { model.saveKey() }
                    Button("Save Key") { model.saveKey() }
                        .disabled(model.keyInput.isEmpty || model.busy)
                }
            }
            TextField("https://www.youtube.com/watch?v=…", text: $model.link)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("YouTube link")
                .disabled(model.busy || !model.hasKey)
                .onSubmit(proceed)
            Toggle("I own this video or have permission to process it", isOn: $model.authorized)
                .disabled(model.busy || !model.hasKey)
            HStack(spacing: DS.Space.sm) {
                Button(action: proceed) {
                    Label("Choose Clip Options", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || !model.hasKey || !model.authorized || model.link.isEmpty)
                if model.stage == .savingKey { TaskProgressRow(label: "Checking key…", fraction: nil) }
            }
            if let message = model.message {
                StatusMessage(text: message, tone: .info)
            }
            StatusMessage(text: "The video starts downloading right away while you choose format, captions, and AI models. Then press Start in the project.",
                          tone: .neutral)
        }
        .surfaceCard(padding: DS.Space.lg, highlighted: true)
        .task { await model.refresh() }
    }

    private func proceed() {
        guard let descriptor = model.descriptor() else { return }
        let link = model.link.trimmingCharacters(in: .whitespacesAndNewlines)
        model.link = ""
        model.authorized = false
        onContinue(link, descriptor)
    }
}

@MainActor
final class YouTubeToolSettingsModel: ObservableObject {
    @Published private(set) var status: YouTubeToolStatus?
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    func refresh() async {
        busy = true
        status = await YouTubeToolManager.shared.status()
        busy = false
    }

    func install() async {
        busy = true
        message = nil
        do {
            status = try await YouTubeToolManager.shared.install()
            message = "Installed yt-dlp \(status?.version ?? "")."
        } catch let error as LocalizedError {
            message = error.errorDescription
        } catch {
            message = "The YouTube downloader could not be installed. Try again."
        }
        busy = false
    }
}

struct YouTubeToolSettingsView: View {
    @StateObject private var model = YouTubeToolSettingsModel()

    var body: some View {
        // The Settings group supplies the "YouTube Downloader" heading.
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                if let status = model.status {
                    StatusBadge(text: "yt-dlp \(status.version ?? "")", tone: .success)
                    Text(status.origin == .managed ? "Installed by ClipHelm" : "Installed on this Mac")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !model.busy {
                    StatusBadge(text: "Not installed", tone: .neutral)
                }
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.status?.origin == .managed ? "Update" : "Install") {
                    Task { await model.install() }
                }
                .disabled(model.busy)
            }
            if let message = model.message {
                StatusMessage(text: message, tone: .info)
            }
            Text("ClipHelm downloads the official yt-dlp release from GitHub, checks it against the published SHA-256 checksum, and keeps it in Application Support. Update it if YouTube imports start failing.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.refresh() }
    }
}
