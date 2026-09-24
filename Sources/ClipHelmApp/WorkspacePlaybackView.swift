import SwiftUI
import AVKit
import ClipHelmCore
import ClipHelmMedia
import ClipHelmSources

@MainActor
private final class WorkspacePlaybackController: ObservableObject {
    let engine = PlaybackEngine()
    @Published var preparingProxy = false
    @Published var proxyFraction: Double?
    @Published var message: String?
    private var proxyJob: Task<Void, Never>?

    func start(project: ProjectRecord, source: PreparedSource?) {
        stop()
        guard let source else { return }
        do { try engine.load(sourceURL: source.fileURL) }
        catch { message = "This source is no longer available. Choose it again in a new draft."; return }
        proxyJob = Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await MediaProbe().probe(fileURL: source.fileURL,
                    displayName: source.asset.displayName, id: source.asset.id)
                guard ProxyEngine().shouldCreateProxy(for: metadata) else { return }
                preparingProxy = true
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "ClipHelm-proxy-\(project.id.rawValue.uuidString)")
                let proxy = try await ProxyEngine().createIfUseful(sourceURL: source.fileURL,
                    metadata: metadata, outputDirectory: directory) { [weak self] update in
                    Task { @MainActor [weak self] in self?.proxyFraction = update.fraction }
                }
                try Task.checkCancellation()
                if let proxy {
                    let position = try? engine.currentSourceTime()
                    let playing = engine.player.rate > 0
                    try engine.load(sourceURL: source.fileURL, proxyURL: proxy.fileURL,
                                    timeMap: proxy.timeMap)
                    if let position { try await engine.seek(sourceTime: position) }
                    if playing { engine.play() }
                }
            } catch is CancellationError {
            } catch {
                message = "Preview uses the original; a smaller editing copy could not be made."
            }
            preparingProxy = false
        }
    }

    func cancelProxy() { proxyJob?.cancel(); preparingProxy = false }
    func stop() { proxyJob?.cancel(); preparingProxy = false; proxyFraction = nil; engine.unload() }
}

struct WorkspacePlaybackView: View {
    let project: ProjectRecord
    let source: PreparedSource?
    @StateObject private var controller = WorkspacePlaybackController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if source != nil {
                    VideoPlayer(player: controller.engine.player)
                } else {
                    ContentUnavailableView("Source access needed", systemImage: "play.rectangle",
                        description: Text("Create a new draft with this source to play it in this session."))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            if controller.preparingProxy {
                HStack {
                    if let fraction = controller.proxyFraction {
                        ProgressView(value: fraction).frame(width: 180)
                    } else { ProgressView().controlSize(.small) }
                    Text("Preparing editing proxy").foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancelProxy() }
                }
            }
            if let message = controller.message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .task(id: project.id) { controller.start(project: project, source: source) }
        .onDisappear { controller.stop() }
    }
}
