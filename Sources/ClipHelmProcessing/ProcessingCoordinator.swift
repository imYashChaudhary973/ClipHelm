import Foundation
import ClipHelmCore
import ClipHelmSources
import ClipHelmTranscription
import ClipHelmAnalysis
import ClipHelmMoments
import ClipHelmFramingVision
import ClipHelmLayoutVision
import ClipHelmLayouts
import ClipHelmEditing
import ClipHelmRendering
import ClipHelmOpenRouter

public enum ProcessingStage: String, CaseIterable, Sendable {
    case preparing = "Preparing / Downloading"
    case transcribing = "Transcribing"
    case analyzing = "Analyzing"
    case findingMoments = "Finding Moments"
    case checkingShots = "Checking Shots"
    case buildingClips = "Building Clips"
    case renderingPreviews = "Rendering Previews"
    case renderingFinals = "Rendering Finals"
    case complete = "Complete"
}

public struct ProcessingProgress: Sendable {
    public let stage: ProcessingStage
    public let fraction: Double
    public let detail: String?

    public init(stage: ProcessingStage, fraction: Double, detail: String? = nil) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.detail = detail
    }
}

public enum ProcessingError: Error, LocalizedError, Sendable {
    case noMoments(String)
    case sourceMismatch
    case outputDirectory
    case sourceUnavailable

    public var errorDescription: String? {
        switch self {
        case .noMoments(let explanation): explanation
        case .sourceMismatch: "The source does not match this project. Locate the original and try again."
        case .outputDirectory: "Choose a writable destination for generated clips."
        case .sourceUnavailable: "This project's video isn't available in this session. Locate the original or re-enter its link, then press Start."
        }
    }
}

public struct ProcessedClip: Sendable {
    public let proposal: ClipProposal
    public let spec: ClipHelmEditSpec
    public let previewURL: URL
    public let finalURL: URL

    public init(proposal: ClipProposal, spec: ClipHelmEditSpec,
                previewURL: URL, finalURL: URL) {
        self.proposal = proposal
        self.spec = spec
        self.previewURL = previewURL
        self.finalURL = finalURL
    }
}

public struct ProcessingResult: Sendable {
    public let source: PreparedSource
    public let transcript: Transcript
    public let analysis: AnalysisResult
    public let clips: [ProcessedClip]
    public let explanation: String?

    public init(source: PreparedSource, transcript: Transcript, analysis: AnalysisResult,
                clips: [ProcessedClip], explanation: String?) {
        self.source = source
        self.transcript = transcript
        self.analysis = analysis
        self.clips = clips
        self.explanation = explanation
    }
}

/// A resumable orchestration boundary. Analysis and completed clip files are reusable;
/// temporary media remains owned by SourceIngestor and originals are read only.
public struct ProcessingCoordinator: Sendable {
    private let ingestor: SourceIngestor
    private let renderer: ClipRenderer
    private let momentEngine: MomentEngine

    public init(ingestor: SourceIngestor, renderer: ClipRenderer = ClipRenderer(),
                momentEngine: MomentEngine = MomentEngine()) {
        self.ingestor = ingestor
        self.renderer = renderer
        self.momentEngine = momentEngine
    }

    public func run(descriptor: SourceDescriptor, expectedAsset: MediaAsset? = nil,
                    configuration: ClipConfiguration, cachedTranscript: Transcript? = nil,
                    cacheDirectory: URL, outputDirectory: URL,
                    backend: any TranscriptionBackend, modelID: String?,
                    gateway: any OpenRouterGateway, registry: OpenRouterModelRegistry,
                    progress: @escaping @Sendable (ProcessingProgress) -> Void = { _ in }) async throws -> ProcessingResult {
        guard ClipRenderer.supports(configuration.outputFormat) else {
            throw RenderError.unsupportedFormat
        }
        progress(.init(stage: .preparing, fraction: 0))
        let source = try await ingestor.prepare(descriptor) { update in
            progress(.init(stage: .preparing, fraction: update.fraction ?? 0,
                           detail: update.stage == .downloading ? "Downloading video" : "Checking source"))
        }
        return try await run(prepared: source, expectedAsset: expectedAsset,
            configuration: configuration, cachedTranscript: cachedTranscript,
            cacheDirectory: cacheDirectory, outputDirectory: outputDirectory,
            backend: backend, modelID: modelID, gateway: gateway, registry: registry,
            progress: progress)
    }

    public func run(prepared source: PreparedSource, expectedAsset: MediaAsset? = nil,
                    configuration: ClipConfiguration, cachedTranscript: Transcript? = nil,
                    cacheDirectory: URL, outputDirectory: URL,
                    backend: any TranscriptionBackend, modelID: String?,
                    gateway: any OpenRouterGateway, registry: OpenRouterModelRegistry,
                    progress: @escaping @Sendable (ProcessingProgress) -> Void = { _ in }) async throws -> ProcessingResult {
        try Task.checkCancellation()
        guard expectedAsset.map({ $0.id == source.asset.id && $0.duration == source.asset.duration &&
            $0.width == source.asset.width && $0.height == source.asset.height }) ?? true else {
            throw ProcessingError.sourceMismatch
        }
        guard ClipRenderer.supports(configuration.outputFormat) else {
            throw RenderError.unsupportedFormat
        }
        guard cacheDirectory.isFileURL, outputDirectory.isFileURL else { throw ProcessingError.outputDirectory }
        progress(.init(stage: .preparing, fraction: 1))
        let transcript: Transcript
        if let cachedTranscript, cachedTranscript.assetID == source.asset.id,
           cachedTranscript.words.allSatisfy({ $0.range.end <= source.asset.duration }) {
            transcript = cachedTranscript
            progress(.init(stage: .transcribing, fraction: 1, detail: "Using saved transcript"))
        } else {
            progress(.init(stage: .transcribing, fraction: 0))
            transcript = try await TranscriptEngine().transcribe(sourceURL: source.fileURL,
                asset: source.asset, backend: backend) { update in
                progress(.init(stage: .transcribing, fraction: update.fraction))
            }
            progress(.init(stage: .transcribing, fraction: 1))
        }
        try Task.checkCancellation()
        progress(.init(stage: .analyzing, fraction: 0))
        let analysis = try await AnalysisEngine().analyze(sourceURL: source.fileURL,
            asset: source.asset, cacheDirectory: cacheDirectory) { update in
            progress(.init(stage: .analyzing, fraction: update.fraction))
        }
        progress(.init(stage: .analyzing, fraction: 1))
        try Task.checkCancellation()
        progress(.init(stage: .findingMoments, fraction: 0))
        let discovery = try await momentEngine.discover(asset: source.asset, transcript: transcript,
            analysis: analysis, selectedLengths: configuration.selectedLengths,
            requestedCount: configuration.requestedClipCount, modelID: modelID,
            gateway: gateway) { update in
            progress(.init(stage: .findingMoments,
                fraction: Double(update.completed) / Double(max(1, update.total))))
        }
        guard !discovery.moments.isEmpty else {
            throw ProcessingError.noMoments(discovery.explanation ?? "No moments passed the quality threshold.")
        }
        progress(.init(stage: .findingMoments, fraction: 1))
        try Task.checkCancellation()
        let full = try MediaTimeRange(start: MediaTime(microseconds: 0), end: source.asset.duration)
        progress(.init(stage: .checkingShots, fraction: 0))
        let localScreens = try await ScreenContentDetector().detect(sourceURL: source.fileURL,
            asset: source.asset, analysis: analysis, range: full) { fraction in
            progress(.init(stage: .checkingShots, fraction: fraction * 0.5))
        }
        var screenHints = localScreens
        if configuration.smartEdit.useVisionForTrickyShots {
            let layoutHints = try await Self.optionalHints {
                try await LayoutVisionAdvisor().classify(sourceURL: source.fileURL,
                    asset: source.asset, configuration: configuration, range: full,
                    analysis: analysis, localHints: localScreens, registry: registry, gateway: gateway)
            }
            screenHints.append(contentsOf: layoutHints)
        }
        var frameHints: [[ContentClassification]] = []
        for (index, moment) in discovery.moments.enumerated() {
            try Task.checkCancellation()
            let hints = try await Self.optionalHints {
                try await FramingVisionAdvisor().classify(sourceURL: source.fileURL,
                    asset: source.asset, configuration: configuration, range: moment.proposal.range,
                    analysis: analysis, registry: registry, gateway: gateway)
            }
            progress(.init(stage: .checkingShots,
                fraction: 0.5 + Double(index + 1) / Double(discovery.moments.count) * 0.5))
            frameHints.append(hints)
        }
        var plans: [(ClipProposal, ClipHelmEditSpec)] = []
        for (index, moment) in discovery.moments.enumerated() {
            try Task.checkCancellation()
            progress(.init(stage: .buildingClips, fraction: Double(index) / Double(discovery.moments.count)))
            let spec = try ClipPlanner().plan(clipID: ClipID(), proposal: moment.proposal,
                configuration: configuration, asset: source.asset, analysis: analysis,
                transcript: transcript, visionHints: frameHints[index], screenHints: screenHints)
            try EditSpecValidator().validate(spec, for: source.asset, proposal: moment.proposal)
            plans.append((moment.proposal, spec))
        }
        progress(.init(stage: .buildingClips, fraction: 1))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let planCount = plans.count
        let jobs = plans.enumerated().map { index, pair in
            let stem = String(format: "clip-%03d-%@", index + 1,
                              pair.1.clipID.rawValue.uuidString)
            return ProcessedClip(proposal: pair.0, spec: pair.1,
                previewURL: outputDirectory.appending(path: stem + "-preview.mp4"),
                finalURL: outputDirectory.appending(path: stem + ".mp4"))
        }
        do {
            for (index, clip) in jobs.enumerated() {
                try Task.checkCancellation()
                progress(.init(stage: .renderingPreviews,
                    fraction: Double(index) / Double(planCount), detail: "Preview \(index + 1) of \(planCount)"))
                _ = try await renderer.render(clip.spec, sourceURL: source.fileURL,
                    asset: source.asset, outputURL: clip.previewURL, quality: .preview) { update in
                    progress(.init(stage: .renderingPreviews,
                        fraction: (Double(index) + update.fraction) / Double(planCount)))
                }
            }
            for (index, clip) in jobs.enumerated() {
                try Task.checkCancellation()
                progress(.init(stage: .renderingFinals,
                    fraction: Double(index) / Double(planCount), detail: "Final clip \(index + 1) of \(planCount)"))
                _ = try await renderer.render(clip.spec, sourceURL: source.fileURL,
                    asset: source.asset, outputURL: clip.finalURL) { update in
                    progress(.init(stage: .renderingFinals,
                        fraction: (Double(index) + update.fraction) / Double(planCount)))
                }
            }
            progress(.init(stage: .complete, fraction: 1))
            return .init(source: source, transcript: transcript, analysis: analysis,
                         clips: jobs, explanation: discovery.explanation)
        } catch {
            for clip in jobs {
                try? FileManager.default.removeItem(at: clip.previewURL)
                try? FileManager.default.removeItem(at: clip.finalURL)
            }
            throw error
        }
    }

    /// Vision hints refine local framing; a failed or unsupported vision request keeps the local result.
    private static func optionalHints<T>(_ body: () async throws -> [T]) async throws -> [T] {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return []
        }
    }
}
