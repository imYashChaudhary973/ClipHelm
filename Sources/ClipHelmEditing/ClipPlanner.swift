import Foundation
import ClipHelmCore
import ClipHelmAnalysis

/// Converts validated suggestions and local evidence into renderer-independent decisions.
public struct ClipPlanner: Sendable {
    public init() { }

    public func plan(clipID: ClipID, proposal: ClipProposal, configuration: ClipConfiguration,
                     asset: MediaAsset, analysis: AnalysisResult, intent: AIEditIntent? = nil,
                     transcript: Transcript? = nil) throws -> ClipHelmEditSpec {
        try proposal.validate(for: asset)
        try analysis.validate(for: asset)
        try intent?.validate(for: proposal)
        if let transcript {
            guard transcript.assetID == asset.id,
                  transcript.words.allSatisfy({ $0.range.end <= asset.duration }) else {
                throw ModelError.invalid("ClipPlanner transcript")
            }
        }

        let range = intent?.suggestedRange ?? proposal.range
        var retained: [MediaTimeRange] = []
        var cursor = range.start
        for cut in try pauseCuts(in: range, configuration: configuration,
                                 analysis: analysis, preserveDemo: intent?.preserveDemo == true) {
            if cursor < cut.start {
                retained.append(try MediaTimeRange(start: cursor, end: cut.start))
            }
            cursor = max(cursor, cut.end)
        }
        if cursor < range.end { retained.append(try MediaTimeRange(start: cursor, end: range.end)) }
        if retained.reduce(Int64(0), { $0 + $1.durationMicroseconds }) < 1_000_000 {
            retained = [range]
        }
        let segments = retained.map(EditSegment.init(sourceRange:))
        let layout = LayoutMode(framing: configuration.framingMode)
        let crops = try layout == .fill
            ? segments.map { try cropPath(for: $0.sourceRange, asset: asset,
                                          format: configuration.outputFormat, analysis: analysis) }
            : []
        let captions = try captionTrack(transcript: transcript, segments: segments,
                                        configuration: configuration)
        let spec = try ClipHelmEditSpec(clipID: clipID, sourceAssetID: asset.id, segments: segments,
                                       outputFormat: configuration.outputFormat,
                                       framingMode: configuration.framingMode,
                                       pacingMode: configuration.pacingMode,
                                       soundMode: configuration.soundMode,
                                       captionStyle: captions == nil ? nil : configuration.captionStyle,
                                       layout: layout, cropPaths: crops, captionTrack: captions)
        try EditSpecValidator().validate(spec, for: asset, proposal: proposal)
        return spec
    }

    private func pauseCuts(in range: MediaTimeRange, configuration: ClipConfiguration,
                           analysis: AnalysisResult, preserveDemo: Bool) throws -> [MediaTimeRange] {
        let thresholds: (edge: Int64, middle: Int64)
        switch configuration.pacingMode {
        case .natural: thresholds = (2_000_000, 3_000_000)
        case .balanced: thresholds = (1_200_000, 2_000_000)
        case .tight: thresholds = (700_000, 1_200_000)
        case .fast: thresholds = (400_000, 800_000)
        }
        var cuts: [MediaTimeRange] = []
        for signal in analysis.signals where signal.kind == .pause &&
            signal.strength >= 0.75 && signal.confidence >= 0.65 {
            guard let pause = try intersection(signal.range, range) else { continue }
            let atEdge = pause.start == range.start || pause.end == range.end
            guard atEdge ? configuration.smartEdit.cutDeadAir : configuration.smartEdit.trimLongPauses,
                  pause.durationMicroseconds >= (atEdge ? thresholds.edge : thresholds.middle) else {
                continue
            }
            if (configuration.smartEdit.keepDemos || preserveDemo) && analysis.classifications.contains(where: {
                $0.kind == .demo && $0.confidence >= 0.6 &&
                $0.range.start < pause.end && pause.start < $0.range.end
            }) { continue }
            if atEdge {
                cuts.append(pause)
            } else {
                let breathingRoom: Int64 = 200_000
                cuts.append(try MediaTimeRange(
                    start: MediaTime(microseconds: pause.start.microseconds + breathingRoom),
                    end: MediaTime(microseconds: pause.end.microseconds - breathingRoom)))
            }
        }
        return cuts.sorted { $0.start < $1.start }
    }

    private func cropPath(for range: MediaTimeRange, asset: MediaAsset,
                          format: OutputFormat, analysis: AnalysisResult) throws -> CropPath {
        let observations = analysis.subjectTracks
            .map { track in track.observations.filter { range.start <= $0.time && $0.time < range.end } }
            .max { $0.count < $1.count } ?? []
        func center(_ observation: SubjectObservation) -> (Double, Double) {
            (observation.bounds.x + observation.bounds.width / 2,
             observation.bounds.y + observation.bounds.height / 2)
        }
        let first = observations.first.map(center)
        let last = observations.last.map(center)
        let coverage = observations.count >= 2 &&
            observations.first!.time.microseconds - range.start.microseconds <= range.durationMicroseconds / 6 &&
            range.end.microseconds - observations.last!.time.microseconds <= range.durationMicroseconds / 6
        if coverage, let first, let last,
           hypot(first.0 - last.0, first.1 - last.1) >= 0.08 {
            return try CropPath(sourceRange: range, keyframes: [
                CropKeyframe(sourceTime: range.start,
                             rect: try cropRect(center: first, asset: asset, format: format)),
                CropKeyframe(sourceTime: range.end,
                             rect: try cropRect(center: last, asset: asset, format: format)),
            ])
        }
        let middle = observations.isEmpty ? (0.5, 0.5) : center(observations[observations.count / 2])
        return try CropPath(sourceRange: range, keyframes: [
            CropKeyframe(sourceTime: range.start,
                         rect: cropRect(center: middle, asset: asset, format: format)),
        ])
    }

    private func cropRect(center: (Double, Double), asset: MediaAsset,
                          format: OutputFormat) throws -> NormalizedRect {
        let sourceAspect = Double(asset.width) / Double(asset.height)
        let targetAspect = Double(format.width) / Double(format.height)
        let width = min(1, targetAspect / sourceAspect)
        let height = min(1, sourceAspect / targetAspect)
        return try NormalizedRect(x: max(0, min(1 - width, center.0 - width / 2)),
                                  y: max(0, min(1 - height, center.1 - height / 2)),
                                  width: width, height: height)
    }

    private func captionTrack(transcript: Transcript?, segments: [EditSegment],
                              configuration: ClipConfiguration) throws -> CaptionTrack? {
        guard configuration.captionStyle != nil, let transcript else { return nil }
        var cues: [CaptionCue] = []
        for word in transcript.words.sorted(by: { $0.range.start < $1.range.start }) {
            guard contains(word.range, in: segments),
                  cues.last.map({ $0.sourceRange.end <= word.range.start }) ?? true else { continue }
            cues.append(try CaptionCue(sourceRange: word.range, text: word.text))
        }
        guard !cues.isEmpty else { return nil }
        return try CaptionTrack(cues: cues, wordByWord: configuration.captionWordByWord,
                                blurIn: configuration.captionBlurIn)
    }
}
