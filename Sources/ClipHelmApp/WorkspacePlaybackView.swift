import SwiftUI
import AVKit
import ClipHelmCore
import ClipHelmMedia
import ClipHelmSources
import ClipHelmSecurity
import ClipHelmOpenRouter
import ClipHelmTranscription
import ClipHelmAnalysis
import UniformTypeIdentifiers

@MainActor
private final class WorkspacePlaybackController: ObservableObject {
    let engine = PlaybackEngine()
    @Published var preparingProxy = false
    @Published var proxyFraction: Double?
    @Published var transcribing = false
    @Published var transcriptProgress: TranscriptProgress?
    @Published var transcript: Transcript?
    @Published var analyzing = false
    @Published var analysisProgress: AnalysisProgress?
    @Published var analysis: AnalysisResult?
    @Published var models: [OpenRouterModel] = []
    @Published var selectedModelID = ""
    @Published var loadingModels = false
    @Published var message: String?

    private let gateway = LiveOpenRouterGateway(secrets: OpenRouterSecretVault())
    private lazy var registry = OpenRouterModelRegistry(gateway: gateway)
    private var proxyJob: Task<Void, Never>?
    private var transcriptJob: Task<Void, Never>?
    private var analysisJob: Task<Void, Never>?
    private var catalogJob: Task<Void, Never>?
    private var transcriptionRunID = UUID()
    private var analysisRunID = UUID()

    func start(project: ProjectRecord, source: PreparedSource?) {
        stop()
        transcript = project.transcript
        analysis = nil
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
                // The original stays playable.
            } catch {
                message = "Preview uses the original; a smaller editing copy could not be made."
            }
            preparingProxy = false
        }
    }

    func loadModels() {
        catalogJob?.cancel()
        loadingModels = true
        message = nil
        catalogJob = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await registry.refresh()
                try Task.checkCancellation()
                models = await registry.models(supporting: [.transcription])
                selectedModelID = (await registry.selectedModel(for: .transcription))?.id
                    ?? models.first?.id ?? ""
                if models.isEmpty { message = "No transcription models are available for this key." }
            } catch is CancellationError {
            } catch {
                message = "Could not load OpenRouter models. Check the key in Settings."
            }
            loadingModels = false
        }
    }

    func transcribe(source: PreparedSource, useOpenRouter: Bool,
                    save: @escaping @MainActor (Transcript) throws -> Void) {
        transcriptJob?.cancel()
        let runID = UUID()
        transcriptionRunID = runID
        transcribing = true
        transcriptProgress = nil
        message = nil
        transcriptJob = Task { [weak self] in
            guard let self else { return }
            do {
                let backend: any TranscriptionBackend
                if useOpenRouter {
                    guard let model = models.first(where: { $0.id == selectedModelID }) else {
                        throw OpenRouterModelRegistryError.modelUnavailable
                    }
                    try await registry.selectModel(id: model.id, for: .transcription)
                    backend = try OpenRouterTranscriptionBackend(gateway: gateway, model: model)
                } else {
                    backend = AppleSpeechBackend()
                }
                let result = try await TranscriptEngine().transcribe(
                    sourceURL: source.fileURL, asset: source.asset, backend: backend) { [weak self] update in
                    Task { @MainActor [weak self] in
                        if self?.transcriptionRunID == runID { self?.transcriptProgress = update }
                    }
                }
                try Task.checkCancellation()
                guard transcriptionRunID == runID else { return }
                try save(result)
                transcript = result
                if !result.hasMeaningfulSpeech {
                    message = "No speech detected. Captions are off for this project."
                }
            } catch is CancellationError {
            } catch let error as TranscriptEngineError {
                if transcriptionRunID == runID { message = error.localizedDescription }
            } catch let error as OpenRouterGatewayError {
                if transcriptionRunID == runID { message = error.localizedDescription }
            } catch {
                if transcriptionRunID == runID {
                    message = "Transcription could not finish. Try another method or source."
                }
            }
            if transcriptionRunID == runID { transcribing = false }
        }
    }

    func analyze(source: PreparedSource, cacheDirectory: URL) {
        analysisJob?.cancel()
        let runID = UUID()
        analysisRunID = runID
        analyzing = true
        analysisProgress = nil
        message = nil
        analysisJob = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AnalysisEngine().analyze(sourceURL: source.fileURL,
                    asset: source.asset, cacheDirectory: cacheDirectory) { [weak self] update in
                    Task { @MainActor [weak self] in
                        if self?.analysisRunID == runID { self?.analysisProgress = update }
                    }
                }
                try Task.checkCancellation()
                if analysisRunID == runID { analysis = result }
            } catch is CancellationError {
            } catch {
                if analysisRunID == runID {
                    message = "Local analysis could not finish. Check the source and try again."
                }
            }
            if analysisRunID == runID { analyzing = false }
        }
    }

    func seek(to time: MediaTime) {
        Task {
            do {
                try await engine.seek(sourceTime: time)
                engine.play()
            } catch {
                message = "Could not seek to that word."
            }
        }
    }

    func cancelProxy() { proxyJob?.cancel(); preparingProxy = false }
    func cancelTranscription() {
        transcriptionRunID = UUID()
        transcriptJob?.cancel()
        transcribing = false
    }

    func cancelAnalysis() {
        analysisRunID = UUID()
        analysisJob?.cancel()
        analyzing = false
    }

    func stop() {
        proxyJob?.cancel()
        transcriptJob?.cancel()
        analysisJob?.cancel()
        transcriptionRunID = UUID()
        analysisRunID = UUID()
        catalogJob?.cancel()
        proxyJob = nil
        transcriptJob = nil
        analysisJob = nil
        catalogJob = nil
        preparingProxy = false
        transcribing = false
        analyzing = false
        loadingModels = false
        proxyFraction = nil
        transcriptProgress = nil
        analysisProgress = nil
        analysis = nil
        message = nil
        engine.unload()
    }
}

struct WorkspacePlaybackView: View {
    let project: ProjectRecord
    let source: PreparedSource?
    let analysisCacheDirectory: URL?
    let saveTranscript: @MainActor (Transcript) throws -> Void
    let reattachSource: @MainActor (URL) async throws -> Void
    @StateObject private var controller = WorkspacePlaybackController()
    @State private var useOpenRouter = false
    @State private var search = ""
    @State private var showingSourcePicker = false
    @State private var reattaching = false

    private var matchingSegments: [TranscriptSegment] {
        guard let transcript = controller.transcript else { return [] }
        guard !search.isEmpty else { return transcript.segments }
        return transcript.segments.filter {
            $0.text.localizedStandardContains(search) ||
            ($0.speakerID?.localizedStandardContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if source != nil {
                    VideoPlayer(player: controller.engine.player)
                } else {
                    ContentUnavailableView("Source access needed", systemImage: "play.rectangle",
                        description: Text("Locate the original video to play and seek in this project."))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)

            if source == nil && project.sourceKind == .local {
                Button(reattaching ? "Locating…" : "Locate Original Video") {
                    showingSourcePicker = true
                }
                .disabled(reattaching)
            }

            if controller.preparingProxy {
                HStack {
                    if let fraction = controller.proxyFraction {
                        ProgressView(value: fraction).frame(width: 180)
                    } else { ProgressView().controlSize(.small) }
                    Text("Preparing editing proxy").foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancelProxy() }
                }
            }

            Divider()
            HStack {
                Text("Local analysis").font(.title3.weight(.semibold))
                Spacer()
                if let source, let analysisCacheDirectory, !controller.analyzing {
                    Button(controller.analysis == nil ? "Analyze on This Mac" : "Analyze Again") {
                        controller.analyze(source: source, cacheDirectory: analysisCacheDirectory)
                    }
                }
            }
            if controller.analyzing {
                HStack {
                    ProgressView(value: controller.analysisProgress?.fraction ?? 0)
                        .frame(width: 180)
                    Text(analysisStage).foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancelAnalysis() }
                }
            } else if let analysis = controller.analysis {
                Text("\(analysis.scenes.count) scenes · \(analysis.subjectTracks.count) subject tracks · \(analysis.signals.filter { $0.kind == .pause }.count) possible pauses")
                    .foregroundStyle(.secondary)
                ForEach(Array(analysis.classifications.prefix(6).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(Self.timeLabel(item.range.start)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Text(item.kind.label)
                        Text("· \(item.confidence < 0.45 ? "low" : "moderate") confidence")
                            .foregroundStyle(.secondary)
                    }
                }
                if analysis.classifications.count > 6 {
                    Text("\(analysis.classifications.count - 6) more analyzed intervals")
                        .foregroundStyle(.secondary)
                }
                Text("Labels are local estimates. Review uncertain shots before editing.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Detect scenes, motion, subjects, audio activity, and possible content types locally.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Transcript").font(.title3.weight(.semibold))
                Spacer()
                if source != nil && !controller.transcribing {
                    Picker("Method", selection: $useOpenRouter) {
                        Text("On this Mac").tag(false)
                        Text("OpenRouter").tag(true)
                    }
                    .frame(width: 190)
                    if useOpenRouter {
                        Button("Load Models") { controller.loadModels() }
                            .disabled(controller.loadingModels)
                    }
                }
            }
            if useOpenRouter && source != nil && !controller.models.isEmpty && !controller.transcribing {
                Picker("Model", selection: $controller.selectedModelID) {
                    ForEach(controller.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                Text("OpenRouter transcription sends short audio excerpts and uses API credits.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let source {
                if controller.transcribing {
                    HStack {
                        if let fraction = controller.transcriptProgress?.fraction {
                            ProgressView(value: fraction).frame(width: 180)
                        } else { ProgressView().controlSize(.small) }
                        Text("Transcribing…").foregroundStyle(.secondary)
                        Button("Cancel") { controller.cancelTranscription() }
                    }
                } else {
                    Button(useOpenRouter ? "Transcribe with OpenRouter (uses credits)" : "Transcribe on This Mac") {
                        controller.transcribe(source: source, useOpenRouter: useOpenRouter,
                                              save: saveTranscript)
                    }
                    .disabled(useOpenRouter && controller.selectedModelID.isEmpty)
                }
            }
            if let message = controller.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let transcript = controller.transcript {
                if transcript.segments.isEmpty {
                    Text("No speech found in this video.").foregroundStyle(.secondary)
                } else {
                    TextField("Search transcript", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search transcript")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matchingSegments.enumerated()), id: \.offset) { _, segment in
                                Button { controller.seek(to: segment.range.start) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(Self.timeLabel(segment.range.start))
                                            .monospacedDigit().foregroundStyle(.secondary)
                                            .frame(width: 52, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 2) {
                                            if let speaker = segment.speakerID {
                                                Text(speaker).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text(segment.text).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(source == nil)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 210)
                }
            } else {
                Text("Transcribe to search speech and jump to a moment.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .task(id: source?.fileURL) { controller.start(project: project, source: source) }
        .onDisappear { controller.stop() }
        .fileImporter(isPresented: $showingSourcePicker,
            allowedContentTypes: [.movie, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie]) { result in
            guard case .success(let url) = result else { return }
            reattaching = true
            Task { @MainActor in
                do { try await reattachSource(url) }
                catch { controller.message = "That file does not match this project's original video." }
                reattaching = false
            }
        }
    }

    private static func timeLabel(_ time: MediaTime) -> String {
        let seconds = time.microseconds / 1_000_000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private var analysisStage: String {
        switch controller.analysisProgress?.stage {
        case .video: "Checking frames…"
        case .audio: "Checking audio…"
        case .classifying: "Classifying intervals…"
        case .caching: "Saving analysis cache…"
        case nil: "Preparing analysis…"
        }
    }
}

private extension ContentKind {
    var label: String {
        switch self {
        case .talkingHead: "Possible talking head"
        case .conversation: "Possible conversation"
        case .screenShare: "Possible screen share"
        case .presentation: "Possible presentation"
        case .demo: "Possible demo"
        case .gameplay: "Possible gameplay"
        case .unknown: "Unknown content"
        }
    }
}
