import Foundation
import Combine
import ClipHelmCore
import ClipHelmSources
import ClipHelmSecurity
import ClipHelmOpenRouter
import ClipHelmTranscription
import ClipHelmProcessing

/// The steps a clip job shows, in order.
enum PipelinePhase: Int, CaseIterable, Identifiable, Comparable {
    case download, transcribe, analyze, findMoments, frame, render

    var id: Int { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .download: "Download video"
        case .transcribe: "Transcribe speech"
        case .analyze: "Analyze scenes"
        case .findMoments: "Find the best moments"
        case .frame: "Frame and edit clips"
        case .render: "Render clips with captions"
        }
    }

    var systemImage: String {
        switch self {
        case .download: "arrow.down.circle"
        case .transcribe: "waveform"
        case .analyze: "film"
        case .findMoments: "sparkles"
        case .frame: "crop"
        case .render: "captions.bubble"
        }
    }

    init?(_ stage: ProcessingStage) {
        switch stage {
        case .preparing, .complete: return nil
        case .transcribing: self = .transcribe
        case .analyzing: self = .analyze
        case .findingMoments: self = .findMoments
        case .checkingShots, .buildingClips: self = .frame
        case .renderingPreviews, .renderingFinals: self = .render
        }
    }
}

enum PhaseState: Equatable {
    case pending
    case running(fraction: Double?, detail: String?)
    case done(detail: String?)
    case failed
}

/// Downloads or validates one source. It outlives the screen that started it, so a video
/// keeps downloading while its options are chosen and after its project is created.
@MainActor
final class SourcePreparation: ObservableObject {
    enum Status: Equatable {
        case installingTool
        case downloading(Double?)
        case validating
        case ready
        case failed(String)
    }

    let descriptor: SourceDescriptor
    @Published private(set) var status: Status
    @Published private(set) var prepared: PreparedSource?
    private var task: Task<PreparedSource, Error>?

    init(descriptor: SourceDescriptor, ingestor: SourceIngestor) {
        self.descriptor = descriptor
        status = .downloading(nil)
        start(ingestor)
    }

    var isFinished: Bool {
        if case .ready = status { return true }
        return false
    }

    var failure: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private func receive(_ update: SourceProgress) {
        guard !isFinished, failure == nil else { return }
        switch update.stage {
        case .validating: status = .validating
        case .checking, .downloading: status = .downloading(update.fraction)
        }
    }

    private func start(_ ingestor: SourceIngestor) {
        let descriptor = self.descriptor
        let report: @Sendable (SourceProgress) -> Void = { [weak self] update in
            Task { @MainActor in self?.receive(update) }
        }
        task = Task { [weak self] in
            do {
                if descriptor.kind == .youtube, YouTubeToolManager.shared.installedExecutable() == nil {
                    self?.status = .installingTool
                    _ = try await YouTubeToolManager.shared.install()
                }
                self?.status = .downloading(nil)
                let result = try await ingestor.prepare(descriptor, progress: report)
                self?.prepared = result
                self?.status = .ready
                return result
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "The video could not be prepared. Try again."
                self?.status = error is CancellationError ? .failed("Download cancelled.") : .failed(message)
                throw error
            }
        }
    }

    func value() async throws -> PreparedSource {
        guard let task else { throw CancellationError() }
        return try await task.value
    }

    func cancel() { task?.cancel() }
}

/// One project's run from source to rendered clips.
@MainActor
final class ClipJob: ObservableObject {
    let projectID: ProjectID
    @Published private(set) var phases: [PipelinePhase: PhaseState] = [:]
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    var source: SourcePreparation?
    fileprivate var task: Task<Void, Never>?

    init(projectID: ProjectID) { self.projectID = projectID }

    func state(of phase: PipelinePhase) -> PhaseState { phases[phase] ?? .pending }

    var currentPhase: PipelinePhase? {
        PipelinePhase.allCases.first { if case .running = state(of: $0) { true } else { false } }
    }

    /// Overall completion, counting each phase equally.
    var overallFraction: Double {
        let values = PipelinePhase.allCases.map { phase -> Double in
            switch state(of: phase) {
            case .done: 1
            case .running(let fraction, _): fraction ?? 0
            case .pending, .failed: 0
            }
        }
        return values.reduce(0, +) / Double(values.count)
    }

    func begin() {
        phases = [:]
        running = true
        finished = false
        failed = false
        message = nil
    }

    func set(_ phase: PipelinePhase, _ state: PhaseState) {
        for earlier in PipelinePhase.allCases where earlier < phase {
            if case .done = self.state(of: earlier) { continue }
            phases[earlier] = .done(detail: nil)
        }
        phases[phase] = state
    }

    func apply(_ progress: ProcessingProgress) {
        if progress.stage == .complete {
            for phase in PipelinePhase.allCases where phase != .download {
                if case .done = state(of: phase) { continue }
                phases[phase] = .done(detail: nil)
            }
            return
        }
        guard let phase = PipelinePhase(progress.stage) else { return }
        var fraction = progress.fraction
        if progress.stage == .renderingPreviews { fraction *= 0.3 }
        if progress.stage == .renderingFinals { fraction = 0.3 + 0.7 * fraction }
        if phase == .transcribe, progress.detail == "Using saved transcript" {
            set(phase, .done(detail: "Using saved transcript"))
            return
        }
        set(phase, .running(fraction: fraction, detail: progress.detail))
    }

    func finish(clipCount: Int, explanation: String?) {
        for phase in PipelinePhase.allCases {
            if case .done = state(of: phase) { continue }
            phases[phase] = .done(detail: nil)
        }
        phases[.render] = .done(detail: "\(clipCount) \(clipCount == 1 ? "clip" : "clips") ready")
        running = false
        finished = true
        message = explanation
    }

    func fail(_ text: String) {
        if let current = currentPhase { phases[current] = .failed }
        running = false
        failed = true
        message = text
    }

    func stopped() {
        if let current = currentPhase { phases[current] = .pending }
        running = false
        message = "Stopped. Press Start to run again."
    }
}

/// App-wide owner of downloads and clip jobs, so work continues when the user changes screens.
@MainActor
final class ClipPipeline: ObservableObject {
    static let onDeviceTranscription = "on-device"

    let ingestor = SourceIngestor()
    @Published private(set) var draftSource: SourcePreparation?
    @Published private(set) var sources: [ProjectID: PreparedSource] = [:]
    @Published private(set) var transcriptionModels: [OpenRouterModel] = []
    @Published private(set) var momentModels: [OpenRouterModel] = []
    @Published private(set) var recommendedTranscriptionModelID: String?
    @Published private(set) var recommendedMomentModelID: String?
    @Published private(set) var catalogMessage: String?
    @Published private(set) var loadingCatalog = false
    private var jobs: [ProjectID: ClipJob] = [:]
    private var draftObservation: AnyCancellable?
    private let gateway = LiveOpenRouterGateway(secrets: OpenRouterSecretVault())
    private lazy var registry = OpenRouterModelRegistry(gateway: gateway)

    // MARK: Sources

    func prepareDraftSource(_ descriptor: SourceDescriptor) {
        if let current = draftSource, current.descriptor == descriptor, current.failure == nil { return }
        draftSource?.cancel()
        let preparation = SourcePreparation(descriptor: descriptor, ingestor: ingestor)
        // The wizard observes the pipeline, so it redraws as the download advances.
        draftObservation = preparation.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        draftSource = preparation
    }

    func clearDraftSource() {
        draftSource?.cancel()
        draftObservation = nil
        draftSource = nil
    }

    /// Hands the wizard's download to a newly created project.
    func adoptDraftSource(for projectID: ProjectID) {
        guard let preparation = draftSource else { return }
        draftObservation = nil
        draftSource = nil
        let job = job(for: projectID)
        job.source = preparation
        if let prepared = preparation.prepared { sources[projectID] = prepared }
    }

    func setSource(_ source: PreparedSource, for projectID: ProjectID) {
        sources[projectID] = source
    }

    func job(for projectID: ProjectID) -> ClipJob {
        if let existing = jobs[projectID] { return existing }
        let created = ClipJob(projectID: projectID)
        jobs[projectID] = created
        return created
    }

    // MARK: Models

    func hasOpenRouterKey() async -> Bool {
        let vault = OpenRouterSecretVault()
        return (try? await Task.detached { try vault.hasKey() }.value) ?? false
    }

    /// Loads the choices the wizard's model step offers.
    func loadCatalog() async {
        guard !loadingCatalog else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        guard await hasOpenRouterKey() else {
            catalogMessage = "Add an OpenRouter API key on Home or in Settings to use OpenRouter models."
            return
        }
        do {
            try await registry.refresh()
            transcriptionModels = await registry.wordTimedTranscriptionModels()
            momentModels = await registry.models(supporting: OpenRouterTask.clipDiscovery.requiredCapabilities)
            recommendedTranscriptionModelID = (await registry.recommendedModel(for: .transcription))?.id
            recommendedMomentModelID = (await registry.preferredModel(for: .clipDiscovery))?.id
            catalogMessage = nil
        } catch let error as LocalizedError {
            catalogMessage = error.errorDescription
        } catch {
            catalogMessage = "Could not load OpenRouter models. Check the key in Settings."
        }
    }

    /// The transcription model a draft or project will use; nil means on this Mac.
    func resolvedTranscriptionModelID(_ choice: String?) -> String? {
        if choice == Self.onDeviceTranscription { return nil }
        return choice ?? recommendedTranscriptionModelID
    }

    // MARK: Jobs

    func start(_ project: ProjectRecord, store: ProjectStore) {
        let job = job(for: project.id)
        guard !job.running else { return }
        job.begin()
        let cacheDirectory = try? store.analysisCacheDirectory(for: project.id)
        let outputDirectory = try? store.exportsDirectory(for: project.id)
        job.task = Task { [weak self, weak store] in
            guard let self, let store, let cacheDirectory, let outputDirectory else { return }
            do {
                let source = try await self.acquireSource(for: project, job: job)
                if project.mediaAsset == nil { try store.attachMediaAsset(source.asset, to: project.id) }
                guard let current = store.projects.first(where: { $0.id == project.id }) else {
                    throw ModelError.invalid("Project removed")
                }
                try Task.checkCancellation()
                let transcript = try await self.transcribe(current, source: source, job: job, store: store)
                let modelID = try await self.momentModel(for: current, transcript: transcript, job: job)
                let result = try await ProcessingCoordinator(ingestor: self.ingestor).run(
                    prepared: source, expectedAsset: current.mediaAsset ?? source.asset,
                    configuration: current.configuration, cachedTranscript: transcript,
                    cacheDirectory: cacheDirectory, outputDirectory: outputDirectory,
                    backend: UnusedTranscriptionBackend(), modelID: modelID,
                    gateway: self.gateway, registry: self.registry) { update in
                    Task { @MainActor in if job.running { job.apply(update) } }
                }
                try Task.checkCancellation()
                try store.saveProcessingResult(result, for: project.id)
                job.finish(clipCount: result.clips.count, explanation: result.explanation)
            } catch is CancellationError {
                job.stopped()
            } catch let error as LocalizedError {
                job.fail(error.errorDescription ?? "Processing stopped. Try again.")
            } catch {
                job.fail("Processing stopped. Check the source and try again.")
            }
        }
    }

    func cancel(_ projectID: ProjectID) {
        jobs[projectID]?.task?.cancel()
    }

    private func acquireSource(for project: ProjectRecord, job: ClipJob) async throws -> PreparedSource {
        if let ready = sources[project.id] {
            job.set(.download, .done(detail: project.sourceKind == .local ? "Video ready" : "Downloaded"))
            return ready
        }
        guard let preparation = job.source else {
            throw ProcessingError.sourceUnavailable
        }
        job.set(.download, .running(fraction: nil, detail: "Starting download"))
        let observer = Task { @MainActor in
            while !Task.isCancelled, job.running {
                switch preparation.status {
                case .installingTool:
                    job.set(.download, .running(fraction: nil, detail: "Installing the YouTube downloader"))
                case .downloading(let fraction):
                    job.set(.download, .running(fraction: fraction, detail: "Downloading video"))
                case .validating:
                    job.set(.download, .running(fraction: 1, detail: "Checking the video"))
                case .ready, .failed: return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { observer.cancel() }
        let source = try await withTaskCancellationHandler {
            try await preparation.value()
        } onCancel: {
            Task { @MainActor in preparation.cancel() }
        }
        sources[project.id] = source
        job.set(.download, .done(detail: "Downloaded"))
        return source
    }

    /// Transcribes with the chosen method and saves the transcript at once, so a later
    /// failure never costs a second transcription.
    private func transcribe(_ project: ProjectRecord, source: PreparedSource, job: ClipJob,
                            store: ProjectStore) async throws -> Transcript {
        if let saved = project.transcript, saved.assetID == source.asset.id {
            job.set(.transcribe, .done(detail: "Using saved transcript"))
            return saved
        }
        job.set(.transcribe, .running(fraction: 0, detail: "Preparing transcription"))
        let backend: any TranscriptionBackend
        let label: String
        if let modelID = try await transcriptionModel(for: project) {
            guard let model = await registry.models(supporting: [.transcription])
                .first(where: { $0.id == modelID }) else {
                throw OpenRouterModelRegistryError.modelUnavailable
            }
            backend = try OpenRouterTranscriptionBackend(gateway: gateway, model: model)
            label = "Transcribing with \(model.name)"
        } else {
            backend = try await OnDeviceSpeech.backend()
            label = "Transcribing on this Mac"
        }
        job.set(.transcribe, .running(fraction: 0, detail: label))
        let transcript = try await TranscriptEngine().transcribe(sourceURL: source.fileURL,
            asset: source.asset, backend: backend) { update in
            Task { @MainActor in
                if job.running { job.set(.transcribe, .running(fraction: update.fraction, detail: label)) }
            }
        }
        try Task.checkCancellation()
        try store.saveTranscript(transcript, for: project.id)
        job.set(.transcribe, .done(detail: "\(transcript.words.count) words"))
        return transcript
    }

    private func transcriptionModel(for project: ProjectRecord) async throws -> String? {
        if project.transcriptionModelID == Self.onDeviceTranscription { return nil }
        guard await hasOpenRouterKey() else { return nil }
        if momentModels.isEmpty && transcriptionModels.isEmpty { try await registry.refresh() }
        if let chosen = project.transcriptionModelID { return chosen }
        return (await registry.recommendedModel(for: .transcription))?.id
    }

    private func momentModel(for project: ProjectRecord, transcript: Transcript,
                             job: ClipJob) async throws -> String? {
        guard transcript.hasMeaningfulSpeech else { return nil }
        guard await hasOpenRouterKey() else { throw OpenRouterSecretError.missingKey }
        _ = try await registry.refresh()
        let model: OpenRouterModel?
        if let chosen = project.momentModelID {
            model = await registry.models(supporting: OpenRouterTask.clipDiscovery.requiredCapabilities)
                .first { $0.id == chosen }
        } else {
            model = await registry.preferredModel(for: .clipDiscovery)
        }
        guard let model else { throw OpenRouterModelRegistryError.modelUnavailable }
        try await registry.selectModel(id: model.id, for: .clipDiscovery)
        if project.configuration.smartEdit.useVisionForTrickyShots,
           let vision = await registry.preferredModel(for: .visionAnalysis) {
            try await registry.selectModel(id: vision.id, for: .visionAnalysis)
        }
        return model.id
    }
}

/// The pipeline transcribes before processing, so the coordinator always receives a transcript.
private struct UnusedTranscriptionBackend: TranscriptionBackend {
    let maximumChunkSeconds = 50
    func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        throw TranscriptEngineError.unavailable
    }
}
