import SwiftUI
import AVKit
import ClipHelmCore
import ClipHelmMedia
import ClipHelmSources
import ClipHelmSecurity
import ClipHelmOpenRouter
import ClipHelmTranscription
import ClipHelmAnalysis
import ClipHelmMoments
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
    @Published var momentModels: [OpenRouterModel] = []
    @Published var selectedMomentModelID = ""
    @Published var loadingMomentModels = false
    @Published var discoveringMoments = false
    @Published var momentProgress: MomentDiscoveryProgress?
    @Published var moments: MomentDiscoveryResult?
    @Published var models: [OpenRouterModel] = []
    @Published var selectedModelID = ""
    @Published var loadingModels = false
    @Published var message: String?

    private let gateway = LiveOpenRouterGateway(secrets: OpenRouterSecretVault())
    private lazy var registry = OpenRouterModelRegistry(gateway: gateway)
    private var proxyJob: Task<Void, Never>?
    private var transcriptJob: Task<Void, Never>?
    private var analysisJob: Task<Void, Never>?
    private var momentJob: Task<Void, Never>?
    private var catalogJob: Task<Void, Never>?
    private var transcriptionRunID = UUID()
    private var analysisRunID = UUID()
    private var momentRunID = UUID()

    func start(project: ProjectRecord, source: PreparedSource?) {
        stop()
        transcript = project.transcript
        analysis = nil
        moments = nil
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
        cancelMoments()
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
                moments = nil
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
        cancelMoments()
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
                if analysisRunID == runID { moments = nil }
            } catch is CancellationError {
            } catch {
                if analysisRunID == runID {
                    message = "Local analysis could not finish. Check the source and try again."
                }
            }
            if analysisRunID == runID { analyzing = false }
        }
    }

    func loadMomentModels() {
        catalogJob?.cancel()
        loadingMomentModels = true
        message = nil
        catalogJob = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await registry.refresh()
                try Task.checkCancellation()
                momentModels = await registry.models(supporting: [.text, .structuredOutput])
                selectedMomentModelID = (await registry.selectedModel(for: .clipDiscovery))?.id
                    ?? momentModels.first?.id ?? ""
                if momentModels.isEmpty { message = "No structured text models are available for this key." }
            } catch is CancellationError {
            } catch {
                message = "Could not load OpenRouter models. Check the key in Settings."
            }
            loadingMomentModels = false
        }
    }

    func discoverMoments(source: PreparedSource, lengths: [ClipLength]) {
        guard let analysis else { return }
        momentJob?.cancel()
        let runID = UUID()
        momentRunID = runID
        discoveringMoments = true
        momentProgress = nil
        moments = nil
        message = nil
        momentJob = Task { [weak self] in
            guard let self else { return }
            do {
                let modelID: String?
                if transcript?.hasMeaningfulSpeech == true {
                    guard let model = momentModels.first(where: { $0.id == selectedMomentModelID }) else {
                        throw MomentEngineError.modelRequired
                    }
                    try await registry.selectModel(id: model.id, for: .clipDiscovery)
                    modelID = model.id
                } else { modelID = nil }
                let result = try await MomentEngine().discover(asset: source.asset,
                    transcript: transcript, analysis: analysis, selectedLengths: lengths,
                    requestedCount: nil, modelID: modelID, gateway: gateway) { [weak self] update in
                    Task { @MainActor [weak self] in
                        if self?.momentRunID == runID { self?.momentProgress = update }
                    }
                }
                try Task.checkCancellation()
                if momentRunID == runID { moments = result }
            } catch is CancellationError {
            } catch let error as LocalizedError {
                if momentRunID == runID { message = error.errorDescription ?? "Moment discovery failed." }
            } catch {
                if momentRunID == runID { message = "Moment discovery failed. Try again." }
            }
            if momentRunID == runID { discoveringMoments = false }
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

    func cancelMoments() {
        momentRunID = UUID()
        momentJob?.cancel()
        discoveringMoments = false
    }

    func stop() {
        proxyJob?.cancel()
        transcriptJob?.cancel()
        analysisJob?.cancel()
        momentJob?.cancel()
        transcriptionRunID = UUID()
        analysisRunID = UUID()
        momentRunID = UUID()
        catalogJob?.cancel()
        proxyJob = nil
        transcriptJob = nil
        analysisJob = nil
        momentJob = nil
        catalogJob = nil
        preparingProxy = false
        transcribing = false
        analyzing = false
        discoveringMoments = false
        loadingMomentModels = false
        loadingModels = false
        proxyFraction = nil
        transcriptProgress = nil
        analysisProgress = nil
        momentProgress = nil
        analysis = nil
        moments = nil
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

            Divider()
            HStack {
                Text("Best moments").font(.title3.weight(.semibold))
                Spacer()
                if controller.transcript?.hasMeaningfulSpeech == true {
                    Button(controller.loadingMomentModels ? "Loading…" : "Load Models") {
                        controller.loadMomentModels()
                    }
                    .disabled(controller.loadingMomentModels || controller.discoveringMoments)
                }
            }
            if controller.transcript?.hasMeaningfulSpeech == true {
                if !controller.momentModels.isEmpty {
                    Picker("Discovery model", selection: $controller.selectedMomentModelID) {
                        ForEach(controller.momentModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Text("Sends only selected transcript excerpts and metadata to OpenRouter. Uses API credits.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Load a structured text model to evaluate spoken moments.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Without a transcript, discovery uses local visual activity and needs manual review.")
                    .foregroundStyle(.secondary)
            }
            if controller.discoveringMoments {
                HStack {
                    ProgressView(value: Double(controller.momentProgress?.completed ?? 0),
                                 total: Double(max(1, controller.momentProgress?.total ?? 1)))
                        .frame(width: 180)
                    Text("Evaluating moments…").foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancelMoments() }
                }
            } else if let source, controller.analysis != nil {
                Button("Find Best Moments") {
                    controller.discoverMoments(source: source, lengths: project.selectedLengths)
                }
                .disabled(controller.transcript?.hasMeaningfulSpeech == true &&
                          controller.selectedMomentModelID.isEmpty)
            } else {
                Text("Run local analysis to find candidate windows.").foregroundStyle(.secondary)
            }
            if let result = controller.moments {
                if let explanation = result.explanation {
                    Text(explanation).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(result.moments, id: \.candidate.id) { moment in
                    Button { controller.seek(to: moment.proposal.range.start) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.timeLabel(moment.proposal.range.start)).monospacedDigit()
                                .frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(moment.proposal.title).fontWeight(.medium)
                                Text(moment.proposal.rationale).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(moment.quality * 100))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
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
