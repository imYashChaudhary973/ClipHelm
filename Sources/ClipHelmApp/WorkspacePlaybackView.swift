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
import ClipHelmCaptions
import ClipHelmProcessing
import UniformTypeIdentifiers

@MainActor
private final class WorkspacePlaybackController: ObservableObject {
    let engine = PlaybackEngine()
    @Published var preparingProxy = false
    @Published var proxyFraction: Double?
    @Published var transcribing = false
    @Published var transcriptProgress: TranscriptProgress?
    @Published var transcript: Transcript?
    @Published var captionProgram: CaptionProgram?
    @Published var analyzing = false
    @Published var analysisProgress: AnalysisProgress?
    @Published var analysis: AnalysisResult?
    @Published var momentModels: [OpenRouterModel] = []
    @Published var selectedMomentModelID = ""
    @Published var visionModels: [OpenRouterModel] = []
    @Published var selectedVisionModelID = ""
    @Published var loadingMomentModels = false
    @Published var discoveringMoments = false
    @Published var momentProgress: MomentDiscoveryProgress?
    @Published var moments: MomentDiscoveryResult?
    @Published var models: [OpenRouterModel] = []
    @Published var selectedModelID = ""
    @Published var loadingModels = false
    @Published var message: String?
    @Published var processing = false
    @Published var processingProgress: ProcessingProgress?

    private let gateway = LiveOpenRouterGateway(secrets: OpenRouterSecretVault())
    private lazy var registry = OpenRouterModelRegistry(gateway: gateway)
    private var proxyJob: Task<Void, Never>?
    private var transcriptJob: Task<Void, Never>?
    private var analysisJob: Task<Void, Never>?
    private var momentJob: Task<Void, Never>?
    private var catalogJob: Task<Void, Never>?
    private var processingJob: Task<Void, Never>?
    private var captionJob: Task<Void, Never>?
    private var transcriptionRunID = UUID()
    private var analysisRunID = UUID()
    private var momentRunID = UUID()
    private var captionRunID = UUID()
    private var processingRunID = UUID()

    func start(project: ProjectRecord, source: PreparedSource?) {
        stop()
        transcript = project.transcript
        analysis = nil
        moments = nil
        guard let source else { return }
        do { try engine.load(sourceURL: source.fileURL) }
        catch { message = "This source is no longer available. Choose it again in a new draft."; return }
        prepareCaptions(transcript: project.transcript, configuration: project.configuration,
                        asset: source.asset)
        preloadMomentModels()
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

    func transcribe(source: PreparedSource, configuration: ClipConfiguration,
                    useOpenRouter: Bool,
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
                    backend = try await OnDeviceSpeech.backend()
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
                prepareCaptions(transcript: result, configuration: configuration,
                                asset: source.asset)
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
                try await refreshMomentModels()
                if momentModels.isEmpty { message = "No structured text models are available for this key." }
            } catch is CancellationError {
            } catch let error as OpenRouterGatewayError {
                message = error.localizedDescription
            } catch {
                message = "Could not load OpenRouter models. Check the key in Settings."
            }
            loadingMomentModels = false
        }
    }

    /// Loads the catalog and selects the saved choice, or a fast current default, for each task.
    private func refreshMomentModels() async throws {
        _ = try await registry.refresh()
        try Task.checkCancellation()
        momentModels = await registry.models(supporting: OpenRouterTask.clipDiscovery.requiredCapabilities)
        visionModels = await registry.models(supporting: OpenRouterTask.visionAnalysis.requiredCapabilities)
        if !momentModels.contains(where: { $0.id == selectedMomentModelID }) {
            selectedMomentModelID = (await registry.preferredModel(for: .clipDiscovery))?.id ?? ""
        }
        if !visionModels.contains(where: { $0.id == selectedVisionModelID }) {
            selectedVisionModelID = (await registry.preferredModel(for: .visionAnalysis))?.id ?? ""
        }
    }

    /// Fills the model pickers without interrupting the user when no key is stored yet.
    private func preloadMomentModels() {
        guard momentModels.isEmpty, !loadingMomentModels else { return }
        loadingMomentModels = true
        catalogJob = Task { [weak self] in
            guard let self else { return }
            let vault = OpenRouterSecretVault()
            if (try? await Task.detached { try vault.hasKey() }.value) == true {
                try? await refreshMomentModels()
            }
            loadingMomentModels = false
        }
    }

    /// Chooses models and processes immediately; used after a quick YouTube import.
    func autoProcess(project: ProjectRecord, source: PreparedSource, ingestor: SourceIngestor,
                     cacheDirectory: URL, outputDirectory: URL,
                     save: @escaping @MainActor (ProcessingResult) throws -> Void) {
        catalogJob?.cancel()
        processing = true
        processingProgress = ProcessingProgress(stage: .preparing, fraction: 0, detail: "Choosing OpenRouter models")
        message = nil
        catalogJob = Task { [weak self] in
            guard let self else { return }
            do {
                if momentModels.isEmpty { try await refreshMomentModels() }
                try Task.checkCancellation()
                processing = false
                process(project: project, source: source, ingestor: ingestor,
                        cacheDirectory: cacheDirectory, outputDirectory: outputDirectory, save: save)
            } catch is CancellationError {
                processing = false
            } catch let error as LocalizedError {
                processing = false
                message = error.errorDescription ?? "Could not load OpenRouter models. Check the key in Settings."
            } catch {
                processing = false
                message = "Could not load OpenRouter models. Check the key in Settings."
            }
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

    func process(project: ProjectRecord, source: PreparedSource, ingestor: SourceIngestor,
                 cacheDirectory: URL, outputDirectory: URL,
                 save: @escaping @MainActor (ProcessingResult) throws -> Void) {
        processingJob?.cancel()
        let runID = UUID()
        processingRunID = runID
        processing = true
        processingProgress = nil
        message = nil
        processingJob = Task { [weak self] in
            guard let self else { return }
            do {
                let needsModel = project.transcript?.hasMeaningfulSpeech ?? source.hasAudio
                let modelID: String?
                if needsModel {
                    guard let model = momentModels.first(where: { $0.id == selectedMomentModelID }) else {
                        throw MomentEngineError.modelRequired
                    }
                    try await registry.selectModel(id: model.id, for: .clipDiscovery)
                    modelID = model.id
                } else { modelID = nil }
                if project.configuration.smartEdit.useVisionForTrickyShots {
                    guard let vision = visionModels.first(where: { $0.id == selectedVisionModelID }) else {
                        throw OpenRouterModelRegistryError.modelUnavailable
                    }
                    try await registry.selectModel(id: vision.id, for: .visionAnalysis)
                }
                processingProgress = ProcessingProgress(stage: .preparing, fraction: 0,
                    detail: "Preparing on-device speech recognition")
                let speech = try await OnDeviceSpeech.backend()
                let result = try await ProcessingCoordinator(ingestor: ingestor).run(
                    prepared: source, expectedAsset: project.mediaAsset,
                    configuration: project.configuration, cachedTranscript: project.transcript,
                    cacheDirectory: cacheDirectory, outputDirectory: outputDirectory,
                    backend: speech, modelID: modelID,
                    gateway: gateway, registry: registry) { [weak self] update in
                    Task { @MainActor [weak self] in
                        if self?.processingRunID == runID { self?.processingProgress = update }
                    }
                }
                try Task.checkCancellation()
                guard processingRunID == runID else { return }
                try save(result)
                transcript = result.transcript
                analysis = result.analysis
                prepareCaptions(transcript: result.transcript, configuration: project.configuration,
                                asset: source.asset)
                message = result.explanation ?? "Created \(result.clips.count) clips."
            } catch is CancellationError {
            } catch let error as LocalizedError {
                if processingRunID == runID { message = error.errorDescription ?? "Processing stopped. Try again." }
            } catch {
                if processingRunID == runID { message = "Processing stopped. Check the source and destination, then try again." }
            }
            if processingRunID == runID { processing = false }
        }
    }

    func cancelProcessing() {
        processingRunID = UUID()
        processingJob?.cancel()
        processing = false
    }

    private func prepareCaptions(transcript: Transcript?, configuration: ClipConfiguration,
                                 asset: MediaAsset) {
        captionJob?.cancel()
        captionProgram = nil
        let runID = UUID()
        captionRunID = runID
        guard transcript?.assetID == asset.id else { return }
        captionJob = Task.detached(priority: .utility) { [weak self] in
            let program: CaptionProgram?
            do {
                let full = try MediaTimeRange(start: MediaTime(microseconds: 0), end: asset.duration)
                let segments = [EditSegment(sourceRange: full)]
                let track = try CaptionTrackBuilder().build(transcript: transcript,
                    segments: segments, configuration: configuration)
                program = try CaptionProgram(track: track, style: track == nil ? nil : configuration.captionStyle,
                    segments: segments, format: configuration.outputFormat)
            } catch { return }
            await MainActor.run { [weak self] in
                guard self?.captionRunID == runID else { return }
                self?.captionProgram = program
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
        cancelProcessing()
        proxyJob?.cancel()
        transcriptJob?.cancel()
        analysisJob?.cancel()
        momentJob?.cancel()
        transcriptionRunID = UUID()
        analysisRunID = UUID()
        momentRunID = UUID()
        catalogJob?.cancel()
        captionJob?.cancel()
        proxyJob = nil
        transcriptJob = nil
        analysisJob = nil
        momentJob = nil
        catalogJob = nil
        captionJob = nil
        captionRunID = UUID()
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
        captionProgram = nil
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
    let exportsDirectory: URL?
    let ingestor: SourceIngestor
    var autoProcess = false
    var didStartAutoProcess: @MainActor () -> Void = { }
    let saveTranscript: @MainActor (Transcript) throws -> Void
    let saveProcessingResult: @MainActor (ProcessingResult) throws -> Void
    let reattachSource: @MainActor (URL) async throws -> Void
    let reattachRemote: @MainActor (String, Bool, @escaping @Sendable (SourceProgress) -> Void) async throws -> Void
    @StateObject private var controller = WorkspacePlaybackController()
    @State private var useOpenRouter = false
    @State private var search = ""
    @State private var showingSourcePicker = false
    @State private var reattaching = false
    @State private var remoteLink = ""
    @State private var authorizedRemote = false
    @State private var reattachProgress: SourceProgress?
    @State private var reattachTask: Task<Void, Never>?

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
            if controller.processing {
                processingBanner
            } else if let message = controller.message, project.clips.isEmpty {
                Label(message, systemImage: "info.circle")
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let source {
                    VideoPlayer(player: controller.engine.player)
                    if let program = controller.captionProgram {
                        CaptionPreviewView(program: program, engine: controller.engine,
                                           asset: source.asset)
                    }
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
            if source == nil && project.sourceKind == .directURL &&
                !SourceImportPolicy.directURLImportEnabled {
                Text(SourceIngestError.directURLDisabled.localizedDescription)
                    .foregroundStyle(.secondary)
            }
            if source == nil && (project.sourceKind == .youtube ||
                (project.sourceKind == .directURL && SourceImportPolicy.directURLImportEnabled)) {
                TextField("Original video URL", text: $remoteLink)
                    .textFieldStyle(.roundedBorder)
                Toggle("I own this video or have permission to process it", isOn: $authorizedRemote)
                Button(reattaching ? "Preparing…" : "Prepare Original Video") {
                    reattaching = true
                    reattachProgress = nil
                    reattachTask = Task { @MainActor in
                        do {
                            try await reattachRemote(remoteLink, authorizedRemote) { update in
                                Task { @MainActor in reattachProgress = update }
                            }
                        } catch is CancellationError {
                            return
                        }
                        catch let error as SourceIngestError {
                            controller.message = error.localizedDescription
                        } catch {
                            controller.message = "That video does not match this project. Check the link and try again."
                        }
                        reattaching = false
                    }
                }
                .disabled(reattaching || !authorizedRemote || remoteLink.isEmpty)
                if reattaching {
                    HStack {
                        if let fraction = reattachProgress?.fraction {
                            ProgressView(value: fraction).frame(width: 180)
                        } else { ProgressView().controlSize(.small) }
                        Text(reattachProgress?.stage == .downloading ? "Downloading…" : "Checking source…")
                            .foregroundStyle(.secondary)
                        Button("Cancel") {
                            reattachTask?.cancel()
                            reattaching = false
                        }
                    }
                }
                Text("Re-enter the public source link after relaunch. ClipHelm does not store remote URLs.")
                    .font(.callout).foregroundStyle(.secondary)
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
                        controller.transcribe(source: source, configuration: project.configuration,
                                              useOpenRouter: useOpenRouter,
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

            Divider()
            HStack {
                Text("Process clips").font(.title3.weight(.semibold))
                Spacer()
                if source?.hasAudio == true || project.configuration.smartEdit.useVisionForTrickyShots {
                    Button(controller.loadingMomentModels ? "Loading…" : "Load Models") {
                        controller.loadMomentModels()
                    }
                    .disabled(controller.loadingMomentModels || controller.processing)
                }
            }
            if let source, let analysisCacheDirectory, let exportsDirectory {
                let needsModel = project.transcript?.hasMeaningfulSpeech ?? source.hasAudio
                if needsModel {
                    if !controller.momentModels.isEmpty {
                        Picker("Moment model", selection: $controller.selectedMomentModelID) {
                            ForEach(controller.momentModels) { model in Text(model.name).tag(model.id) }
                        }
                    } else {
                        Text("Load a structured text model for spoken moments.")
                            .foregroundStyle(.secondary)
                    }
                }
                if project.configuration.smartEdit.useVisionForTrickyShots {
                    if !controller.visionModels.isEmpty {
                        Picker("Vision model", selection: $controller.selectedVisionModelID) {
                            ForEach(controller.visionModels) { model in Text(model.name).tag(model.id) }
                        }
                    } else {
                        Text("Load a structured vision model for uncertain shots.")
                            .foregroundStyle(.secondary)
                    }
                }
                if controller.processing {
                    HStack {
                        ProgressView(value: controller.processingProgress?.fraction ?? 0)
                            .frame(width: 180)
                        Text(controller.processingProgress?.stage.rawValue ?? "Preparing")
                            .foregroundStyle(.secondary)
                        Button("Cancel") { controller.cancelProcessing() }
                    }
                    if let detail = controller.processingProgress?.detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Process Clips") {
                        controller.process(project: project, source: source, ingestor: ingestor,
                            cacheDirectory: analysisCacheDirectory, outputDirectory: exportsDirectory,
                            save: saveProcessingResult)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((needsModel && controller.selectedMomentModelID.isEmpty) ||
                              (project.configuration.smartEdit.useVisionForTrickyShots &&
                               controller.selectedVisionModelID.isEmpty))
                    Text("Processing uses on-device speech recognition and local analysis. OpenRouter evaluates selected transcript windows and, if enabled, uncertain shots. It uses API credits.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Locate the original video to process clips.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .task(id: source?.fileURL) {
            controller.start(project: project, source: source)
            if autoProcess, let source, let analysisCacheDirectory, let exportsDirectory {
                didStartAutoProcess()
                controller.autoProcess(project: project, source: source, ingestor: ingestor,
                    cacheDirectory: analysisCacheDirectory, outputDirectory: exportsDirectory,
                    save: saveProcessingResult)
            }
        }
        .onDisappear { reattachTask?.cancel(); controller.stop() }
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

    private var processingBanner: some View {
        let stages = ProcessingStage.allCases.filter { $0 != .complete }
        let current = controller.processingProgress?.stage ?? .preparing
        let index = stages.firstIndex(of: current) ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Making clips · step \(index + 1) of \(stages.count): \(current.rawValue)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { controller.cancelProcessing() }
            }
            ProgressView(value: (Double(index) + (controller.processingProgress?.fraction ?? 0)) / Double(stages.count))
            if let detail = controller.processingProgress?.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Text("Your clips appear here when rendering finishes.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
