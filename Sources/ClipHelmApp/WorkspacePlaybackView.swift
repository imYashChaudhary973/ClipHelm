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
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            // A quick YouTube import starts processing on arrival; keep its progress in view.
            if controller.processing { processingBanner }
            player
            if source == nil { sourceAccessCard }
            if controller.preparingProxy {
                TaskProgressRow(label: "Preparing editing proxy", fraction: controller.proxyFraction,
                                onCancel: { controller.cancelProxy() })
                    .surfaceCard()
            }
            if let message = controller.message {
                StatusMessage(text: message, tone: .warning)
                    .surfaceCard(padding: DS.Space.sm)
            }

            processCard

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Explore the source").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Optional. Inspect local analysis, speech, and candidate moments before or after processing.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, DS.Space.xs)
            analysisCard
            transcriptCard
            momentsCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Player and source access

    private var isVerticalSource: Bool {
        guard let asset = source?.asset ?? project.mediaAsset else { return false }
        return asset.height > asset.width
    }

    /// Without a source there is nothing to watch; the source access card explains why.
    @ViewBuilder
    private var player: some View {
        if let source {
            let stage = ZStack {
                DS.videoBackground
                VideoPlayer(player: controller.engine.player)
                if let program = controller.captionProgram {
                    CaptionPreviewView(program: program, engine: controller.engine,
                                       asset: source.asset)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))

            // Tall sources get a fixed stage so they are not shrunk into a wide letterbox.
            if isVerticalSource {
                stage.frame(maxWidth: .infinity).frame(height: 480)
            } else {
                stage.frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
            }
        }
    }

    private var sourceAccessCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: "play.rectangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source access needed").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Locate the original video to play, analyze, and process this project.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if project.sourceKind == .local {
                Button(reattaching ? "Locating…" : "Locate Original Video…") {
                    showingSourcePicker = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(reattaching)
            }
            if project.sourceKind == .directURL && !SourceImportPolicy.directURLImportEnabled {
                Text(SourceIngestError.directURLDisabled.localizedDescription)
                    .foregroundStyle(.secondary)
            }
            if project.sourceKind == .youtube ||
                (project.sourceKind == .directURL && SourceImportPolicy.directURLImportEnabled) {
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
                .buttonStyle(.borderedProminent)
                .disabled(reattaching || !authorizedRemote || remoteLink.isEmpty)
                if reattaching {
                    TaskProgressRow(label: reattachProgress?.stage == .downloading ? "Downloading…" : "Checking source…",
                                    fraction: reattachProgress?.fraction) {
                        reattachTask?.cancel()
                        reattaching = false
                    }
                }
                Text("Re-enter the public source link after relaunch. ClipHelm does not store remote URLs.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .surfaceCard(highlighted: true)
    }

    // MARK: Process (primary)

    private var processStatus: (text: String, tone: StatusTone) {
        if controller.processing { return ("Running", .info) }
        if source == nil { return ("Needs source", .warning) }
        if !project.clips.isEmpty { return ("\(project.clips.count) clips saved", .success) }
        return ("Ready", .neutral)
    }

    private var processCard: some View {
        StageCard(eyebrow: "Recommended", title: "Process clips", systemImage: "scissors",
                  status: processStatus, highlighted: source != nil && !controller.processing) {
            if source?.hasAudio == true || project.configuration.smartEdit.useVisionForTrickyShots {
                Button(controller.loadingMomentModels ? "Loading…" : "Load Models") {
                    controller.loadMomentModels()
                }
                .disabled(controller.loadingMomentModels || controller.processing)
            }
        } content: {
            Text("Finds the strongest moments, frames them, and renders preview and final files.")
                .foregroundStyle(.secondary)
            if let source, let analysisCacheDirectory, let exportsDirectory {
                let needsModel = project.transcript?.hasMeaningfulSpeech ?? source.hasAudio
                if needsModel {
                    if !controller.momentModels.isEmpty {
                        Picker("Moment model", selection: $controller.selectedMomentModelID) {
                            ForEach(controller.momentModels) { model in Text(model.name).tag(model.id) }
                        }
                    } else {
                        StatusMessage(text: "Load a structured text model for spoken moments.", tone: .neutral)
                    }
                }
                if project.configuration.smartEdit.useVisionForTrickyShots {
                    if !controller.visionModels.isEmpty {
                        Picker("Vision model", selection: $controller.selectedVisionModelID) {
                            ForEach(controller.visionModels) { model in Text(model.name).tag(model.id) }
                        }
                    } else {
                        StatusMessage(text: "Load a structured vision model for uncertain shots.", tone: .neutral)
                    }
                }
                if controller.processing {
                    // The banner at the top of the workspace carries progress and Cancel.
                    StatusMessage(text: "Making clips. Progress is shown at the top of this page.", tone: .info)
                } else {
                    HStack(spacing: DS.Space.sm) {
                        Button {
                            controller.process(project: project, source: source, ingestor: ingestor,
                                cacheDirectory: analysisCacheDirectory, outputDirectory: exportsDirectory,
                                save: saveProcessingResult)
                        } label: {
                            Label("Process Clips",
                                  systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled((needsModel && controller.selectedMomentModelID.isEmpty) ||
                                  (project.configuration.smartEdit.useVisionForTrickyShots &&
                                   controller.selectedVisionModelID.isEmpty))
                        if needsModel && controller.selectedMomentModelID.isEmpty {
                            Text("Load models to enable processing.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    StatusMessage(text: "Processing uses on-device speech recognition and local analysis. OpenRouter evaluates selected transcript windows and, if enabled, uncertain shots. It uses API credits.",
                                  tone: .info)
                }
            } else {
                StatusMessage(text: "Locate the original video to process clips.", tone: .neutral)
            }
        }
    }

    // MARK: Explore

    private var analysisStatus: (text: String, tone: StatusTone) {
        if controller.analyzing { return ("Running", .info) }
        if controller.analysis != nil { return ("Done", .success) }
        return ("Not started", .neutral)
    }

    private var analysisCard: some View {
        StageCard(title: "Local analysis", systemImage: "waveform.path.ecg", status: analysisStatus) {
            if let source, let analysisCacheDirectory, !controller.analyzing {
                Button(controller.analysis == nil ? "Analyze on This Mac" : "Analyze Again") {
                    controller.analyze(source: source, cacheDirectory: analysisCacheDirectory)
                }
            }
        } content: {
            if controller.analyzing {
                TaskProgressRow(label: analysisStage, fraction: controller.analysisProgress?.fraction ?? 0) {
                    controller.cancelAnalysis()
                }
            } else if let analysis = controller.analysis {
                HStack(spacing: DS.Space.lg) {
                    metric("\(analysis.scenes.count)", "scenes")
                    metric("\(analysis.subjectTracks.count)", "subject tracks")
                    metric("\(analysis.signals.filter { $0.kind == .pause }.count)", "possible pauses")
                }
                VStack(spacing: 0) {
                    ForEach(Array(analysis.classifications.prefix(6).enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider() }
                        HStack {
                            Text(Self.timeLabel(item.range.start)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(item.kind.label)
                            Spacer()
                            Text("\(item.confidence < 0.45 ? "Low" : "Moderate") confidence")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, DS.Space.xs)
                    }
                }
                if analysis.classifications.count > 6 {
                    Text("\(analysis.classifications.count - 6) more analyzed intervals")
                        .font(.callout).foregroundStyle(.secondary)
                }
                StatusMessage(text: "Labels are local estimates. Review uncertain shots before editing.", tone: .neutral)
            } else {
                Text("Detect scenes, motion, subjects, audio activity, and possible content types locally.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var transcriptStatus: (text: String, tone: StatusTone) {
        if controller.transcribing { return ("Running", .info) }
        if let transcript = controller.transcript {
            return transcript.segments.isEmpty ? ("No speech", .warning) : ("Done", .success)
        }
        return ("Not started", .neutral)
    }

    private var transcriptCard: some View {
        StageCard(title: "Transcript", systemImage: "text.quote", status: transcriptStatus) {
            if source != nil && !controller.transcribing {
                Picker("Method", selection: $useOpenRouter) {
                    Text("On this Mac").tag(false)
                    Text("OpenRouter").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } content: {
            if useOpenRouter && source != nil && !controller.transcribing {
                HStack {
                    if !controller.models.isEmpty {
                        Picker("Model", selection: $controller.selectedModelID) {
                            ForEach(controller.models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                    Button(controller.loadingModels ? "Loading…" : "Load Models") { controller.loadModels() }
                        .disabled(controller.loadingModels)
                }
                StatusMessage(text: "OpenRouter transcription sends short audio excerpts and uses API credits.",
                              tone: .info)
            }
            if let source {
                if controller.transcribing {
                    TaskProgressRow(label: "Transcribing…", fraction: controller.transcriptProgress?.fraction) {
                        controller.cancelTranscription()
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
                                    HStack(alignment: .top, spacing: DS.Space.sm) {
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
                                    .padding(.vertical, DS.Space.xs)
                                    .padding(.horizontal, DS.Space.xs)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(source == nil)
                                .help("Jump to \(Self.timeLabel(segment.range.start))")
                                Divider()
                            }
                            if matchingSegments.isEmpty {
                                Text("No lines match “\(search)”.")
                                    .foregroundStyle(.secondary)
                                    .padding(DS.Space.sm)
                            }
                        }
                    }
                    .frame(height: 240)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .strokeBorder(DS.hairline)
                    }
                }
            } else {
                Text("Transcribe to search speech and jump to a moment.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var momentsStatus: (text: String, tone: StatusTone) {
        if controller.discoveringMoments { return ("Running", .info) }
        if let result = controller.moments {
            return result.moments.isEmpty ? ("None found", .warning) : ("\(result.moments.count) found", .success)
        }
        return ("Not started", .neutral)
    }

    private var momentsCard: some View {
        StageCard(title: "Best moments", systemImage: "sparkles", status: momentsStatus) {
            if controller.transcript?.hasMeaningfulSpeech == true {
                Button(controller.loadingMomentModels ? "Loading…" : "Load Models") {
                    controller.loadMomentModels()
                }
                .disabled(controller.loadingMomentModels || controller.discoveringMoments)
            }
        } content: {
            if controller.transcript?.hasMeaningfulSpeech == true {
                if !controller.momentModels.isEmpty {
                    Picker("Discovery model", selection: $controller.selectedMomentModelID) {
                        ForEach(controller.momentModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    StatusMessage(text: "Sends only selected transcript excerpts and metadata to OpenRouter. Uses API credits.",
                                  tone: .info)
                } else {
                    Text("Load a structured text model to evaluate spoken moments.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Without a transcript, discovery uses local visual activity and needs manual review.")
                    .foregroundStyle(.secondary)
            }
            if controller.discoveringMoments {
                TaskProgressRow(label: "Evaluating moments…",
                                fraction: Double(controller.momentProgress?.completed ?? 0) /
                                    Double(max(1, controller.momentProgress?.total ?? 1))) {
                    controller.cancelMoments()
                }
            } else if let source, controller.analysis != nil {
                Button("Find Best Moments") {
                    controller.discoverMoments(source: source, lengths: project.selectedLengths)
                }
                .disabled(controller.transcript?.hasMeaningfulSpeech == true &&
                          controller.selectedMomentModelID.isEmpty)
            } else {
                StatusMessage(text: "Run local analysis to find candidate windows.", tone: .neutral)
            }
            if let result = controller.moments {
                if let explanation = result.explanation {
                    StatusMessage(text: explanation, tone: .info)
                }
                VStack(spacing: 0) {
                    ForEach(Array(result.moments.enumerated()), id: \.element.candidate.id) { index, moment in
                        if index > 0 { Divider() }
                        Button { controller.seek(to: moment.proposal.range.start) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                                Text(Self.timeLabel(moment.proposal.range.start)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(moment.proposal.title).fontWeight(.medium)
                                    Text(moment.proposal.rationale).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text("\(Int(moment.quality * 100))")
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, DS.Space.xs)
                                    .padding(.vertical, 2)
                                    .background(DS.accent.opacity(0.12), in: Capsule())
                                    .accessibilityLabel("Quality \(Int(moment.quality * 100)) of 100")
                            }
                            .padding(.vertical, DS.Space.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Jump to this moment")
                    }
                }
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
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Making clips").font(.headline)
                    Text("Step \(index + 1) of \(stages.count) · \(current.rawValue)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { controller.cancelProcessing() }
            }
            ProgressView(value: (Double(index) + (controller.processingProgress?.fraction ?? 0)) / Double(stages.count))
                .accessibilityLabel("Making clips")
            if let detail = controller.processingProgress?.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            StatusMessage(text: "Your clips appear here when rendering finishes.", tone: .info)
        }
        .surfaceCard(highlighted: true)
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
