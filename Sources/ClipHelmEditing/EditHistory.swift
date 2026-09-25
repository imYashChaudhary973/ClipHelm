import ClipHelmCore

public enum EditOperation: Sendable {
    case trim(to: MediaTimeRange)
    case remove(MediaTimeRange)
    case setCropPaths([CropPath])
    case setLayout(LayoutMode)
    case overrideShotLayout(range: MediaTimeRange, layout: ShotLayout)
    case setAudio(AudioOperation)
    case setCaptions(style: CaptionStyle?, track: CaptionTrack?)
}

/// In-memory, non-destructive edit snapshots. Project persistence comes later.
public struct EditHistory: Sendable {
    public private(set) var current: ClipHelmEditSpec
    private var past: [ClipHelmEditSpec] = []
    private var future: [ClipHelmEditSpec] = []

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public init(initial: ClipHelmEditSpec, asset: MediaAsset,
                proposal: ClipProposal? = nil) throws {
        try EditSpecValidator().validate(initial, for: asset, proposal: proposal)
        current = initial
    }

    public mutating func apply(_ operation: EditOperation, asset: MediaAsset,
                               proposal: ClipProposal? = nil) throws {
        var segments = current.segments
        var crops = current.cropPaths
        var layout = current.layout
        var layoutCues = current.layoutCues
        var framing = current.framingMode
        var audio = current.audioOperation
        var style = current.captionStyle
        var captions = current.captionTrack

        switch operation {
        case .trim(let range):
            segments = try segments.compactMap { segment in
                try intersection(segment.sourceRange, range).map(EditSegment.init(sourceRange:))
            }
        case .remove(let range):
            segments = try subtract(segments.map(\.sourceRange), removing: range)
                .map(EditSegment.init(sourceRange:))
        case .setCropPaths(let paths): crops = paths
        case .setLayout(let mode):
            layout = mode
            switch mode {
            case .fill:
                if framing == .classicFullFrame || framing == .blurred { framing = .fullFrame }
            case .fit: framing = .classicFullFrame
            case .blurredBackground: framing = .blurred
            }
            if mode != .fill { crops = [] }
            if mode != .fill { layoutCues = [] }
        case .overrideShotLayout(let range, let choice):
            guard contains(range, in: segments), layout == .fill else {
                throw ModelError.invalid("EditHistory layout range")
            }
            var updated: [LayoutCue] = []
            for cue in layoutCues {
                if cue.sourceRange.end <= range.start || range.end <= cue.sourceRange.start {
                    updated.append(cue)
                } else {
                    if cue.sourceRange.start < range.start {
                        updated.append(LayoutCue(sourceRange: try MediaTimeRange(
                            start: cue.sourceRange.start, end: range.start),
                            layout: cue.layout, origin: cue.origin))
                    }
                    if range.end < cue.sourceRange.end {
                        updated.append(LayoutCue(sourceRange: try MediaTimeRange(
                            start: range.end, end: cue.sourceRange.end),
                            layout: cue.layout, origin: cue.origin))
                    }
                }
            }
            updated.append(LayoutCue(sourceRange: range, layout: choice, origin: .manual))
            layoutCues = updated.sorted { $0.sourceRange.start < $1.sourceRange.start }
        case .setAudio(let operation): audio = operation
        case .setCaptions(let newStyle, let track):
            style = newStyle
            captions = track
        }

        guard !segments.isEmpty else { throw ModelError.invalid("EditHistory empty clip") }
        if case .trim = operation { try retainTimedEdits() }
        if case .remove = operation { try retainTimedEdits() }

        func retainTimedEdits() throws {
            crops = crops.filter { contains($0.sourceRange, in: segments) }
            layoutCues = try layoutCues.flatMap { cue in
                try segments.compactMap { segment in
                    try intersection(cue.sourceRange, segment.sourceRange).map {
                        LayoutCue(sourceRange: $0, layout: cue.layout, origin: cue.origin)
                    }
                }
            }
            if let track = captions {
                let cues = track.cues.filter { contains($0.sourceRange, in: segments) }
                captions = cues.isEmpty ? nil : try CaptionTrack(cues: cues,
                    wordByWord: track.wordByWord, blurIn: track.blurIn)
                if captions == nil { style = nil }
            }
        }

        let next = try ClipHelmEditSpec(clipID: current.clipID, sourceAssetID: current.sourceAssetID,
                                       segments: segments, outputFormat: current.outputFormat,
                                       framingMode: framing, pacingMode: current.pacingMode,
                                       soundMode: audio.soundMode, captionStyle: style,
                                       layout: layout, cropPaths: crops, captionTrack: captions,
                                       layoutCues: layoutCues)
        try EditSpecValidator().validate(next, for: asset, proposal: proposal)
        guard next != current else { return }
        past.append(current)
        // ponytail: cap in-memory snapshots at 100; persist history if projects need cross-launch undo.
        if past.count > 100 { past.removeFirst() }
        current = next
        future.removeAll()
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = past.popLast() else { return false }
        future.append(current)
        current = previous
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = future.popLast() else { return false }
        past.append(current)
        current = next
        return true
    }
}
