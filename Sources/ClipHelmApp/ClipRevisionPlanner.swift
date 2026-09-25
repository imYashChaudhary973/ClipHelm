import Foundation
import ClipHelmCore
import ClipHelmSources
import ClipHelmAnalysis
import ClipHelmEditing
import ClipHelmCaptions

struct ClipRevisionOptions: Sendable {
    let trimRange: MediaTimeRange
    let framing: FramingMode
    let pacing: PacingMode
    let captionStyle: CaptionStyle?
    let focusX: Double
    let focusY: Double
    var forceReframe = false
}

/// Replans one existing proposal from local evidence, then validates the result before rendering.
struct ClipRevisionPlanner: Sendable {
    func revise(_ clip: ProjectClipRecord, source: PreparedSource,
                transcript: Transcript?, configuration: ClipConfiguration,
                cacheDirectory: URL, options: ClipRevisionOptions) async throws -> ClipHelmEditSpec {
        try Task.checkCancellation()
        guard clip.spec.sourceAssetID == source.asset.id,
              transcript.map({ $0.assetID == source.asset.id }) ?? true,
              clip.proposal.range.start <= options.trimRange.start,
              options.trimRange.end <= clip.proposal.range.end,
              options.focusX.isFinite, options.focusY.isFinite,
              (0...1).contains(options.focusX), (0...1).contains(options.focusY) else {
            throw ModelError.invalid("Clip revision")
        }
        let revisedConfiguration = try ClipConfiguration(outputFormat: clip.spec.outputFormat,
            framingMode: options.framing, pacingMode: options.pacing,
            selectedLengths: configuration.selectedLengths,
            requestedClipCount: configuration.requestedClipCount,
            soundMode: clip.spec.soundMode, captionStyle: options.captionStyle,
            smartEdit: configuration.smartEdit,
            captionWordByWord: options.captionStyle != nil &&
                (clip.spec.captionTrack?.wordByWord ?? configuration.captionWordByWord),
            captionBlurIn: options.captionStyle != nil &&
                (clip.spec.captionTrack?.blurIn ?? configuration.captionBlurIn))
        let paths: [CropPath]
        if options.framing == .fullFrame {
            paths = try manualPaths(segments: clip.spec.segments, asset: source.asset,
                format: clip.spec.outputFormat, focusX: options.focusX, focusY: options.focusY)
        } else { paths = clip.spec.cropPaths }
        if !options.forceReframe,
           options.trimRange == (clip.trimRange ?? clip.proposal.range),
           options.framing == clip.spec.framingMode,
           options.pacing == clip.spec.pacingMode {
            let captions = try CaptionTrackBuilder().build(transcript: transcript,
                segments: clip.spec.segments, configuration: revisedConfiguration)
            let spec = try ClipHelmEditSpec(clipID: clip.id,
                sourceAssetID: clip.spec.sourceAssetID, segments: clip.spec.segments,
                outputFormat: clip.spec.outputFormat, framingMode: clip.spec.framingMode,
                pacingMode: clip.spec.pacingMode, soundMode: clip.spec.soundMode,
                captionStyle: captions == nil ? nil : options.captionStyle,
                layout: clip.spec.layout,
                cropPaths: options.framing == .fullFrame ? paths : clip.spec.cropPaths,
                captionTrack: captions, layoutCues: clip.spec.layoutCues)
            try EditSpecValidator().validate(spec, for: source.asset, proposal: clip.proposal)
            return spec
        }
        let analysis = try await AnalysisEngine().analyze(sourceURL: source.fileURL,
            asset: source.asset, cacheDirectory: cacheDirectory)
        let intent = AIEditIntent(proposalID: clip.proposal.id,
                                  suggestedRange: options.trimRange)
        let planned = try ClipPlanner().plan(clipID: clip.id, proposal: clip.proposal,
            configuration: revisedConfiguration, asset: source.asset, analysis: analysis,
            intent: intent, transcript: transcript)
        guard options.framing == .fullFrame else { return planned }

        let finalPaths = try manualPaths(segments: planned.segments, asset: source.asset,
            format: planned.outputFormat, focusX: options.focusX, focusY: options.focusY)
        let spec = try ClipHelmEditSpec(clipID: planned.clipID,
            sourceAssetID: planned.sourceAssetID, segments: planned.segments,
            outputFormat: planned.outputFormat, framingMode: planned.framingMode,
            pacingMode: planned.pacingMode, soundMode: planned.soundMode,
            captionStyle: planned.captionStyle, layout: planned.layout,
            cropPaths: finalPaths, captionTrack: planned.captionTrack,
            layoutCues: planned.layoutCues)
        try EditSpecValidator().validate(spec, for: source.asset, proposal: clip.proposal)
        return spec
    }

    private func manualPaths(segments: [EditSegment], asset: MediaAsset,
                             format: OutputFormat, focusX: Double,
                             focusY: Double) throws -> [CropPath] {
        let sourceAspect = Double(asset.width) / Double(asset.height)
        let targetAspect = Double(format.width) / Double(format.height)
        let width = min(1, targetAspect / sourceAspect)
        let height = min(1, sourceAspect / targetAspect)
        let rect = try NormalizedRect(x: min(1 - width, max(0, focusX - width / 2)),
                                      y: min(1 - height, max(0, focusY - height / 2)),
                                      width: width, height: height)
        return try segments.map { segment in
            try CropPath(sourceRange: segment.sourceRange,
                keyframes: [CropKeyframe(sourceTime: segment.sourceRange.start, rect: rect)])
        }
    }
}
