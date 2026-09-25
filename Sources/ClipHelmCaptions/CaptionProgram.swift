import Foundation
import ClipHelmCore

/// Builds the same word track for clip planning and source preview.
public struct CaptionTrackBuilder: Sendable {
    public init() { }

    public func build(transcript: Transcript?, segments: [EditSegment],
                      configuration: ClipConfiguration) throws -> CaptionTrack? {
        guard configuration.captionStyle != nil, let transcript, transcript.hasMeaningfulSpeech else { return nil }
        var cues: [CaptionCue] = []
        for word in transcript.words.sorted(by: { $0.range.start < $1.range.start }) {
            try Task.checkCancellation()
            guard segments.contains(where: {
                $0.sourceRange.start <= word.range.start && word.range.end <= $0.sourceRange.end
            }), cues.last.map({ $0.sourceRange.end <= word.range.start }) ?? true else { continue }
            cues.append(try CaptionCue(sourceRange: word.range, text: word.text))
        }
        guard !cues.isEmpty else { return nil }
        return try CaptionTrack(cues: cues, wordByWord: configuration.captionWordByWord,
                                blurIn: configuration.captionBlurIn)
    }
}

public struct CaptionPhrase: Equatable, Sendable {
    public let words: [CaptionCue]
    public let range: MediaTimeRange

    init(words: [CaptionCue]) throws {
        self.words = words
        range = try MediaTimeRange(start: words[0].sourceRange.start,
                                   end: words[words.count - 1].sourceRange.end)
    }
}

/// Regeneratable layout program. Both preview and export ask it for the same source-time frame.
public struct CaptionProgram: Sendable {
    public let style: CaptionStyle?
    public let wordByWord: Bool
    public let blurIn: Bool
    public let phrases: [CaptionPhrase]

    public init(spec: ClipHelmEditSpec) throws {
        try self.init(track: spec.captionTrack, style: spec.captionStyle,
                      segments: spec.segments, format: spec.outputFormat)
    }

    public init(track: CaptionTrack?, style: CaptionStyle?,
                segments: [EditSegment], format: OutputFormat) throws {
        guard (track == nil || style != nil),
              track?.cues.allSatisfy({ cue in
                  segments.contains { $0.sourceRange.start <= cue.sourceRange.start &&
                      cue.sourceRange.end <= $0.sourceRange.end }
              }) ?? true else { throw ModelError.invalid("CaptionProgram input") }
        self.style = style
        wordByWord = track?.wordByWord ?? false
        blurIn = track?.blurIn ?? false
        guard let track else { phrases = []; return }

        let maxCharacters = format.height > format.width ? 42 : 72
        let maxWords = format.height > format.width ? 6 : 9
        let maxDuration: Int64 = format.height > format.width ? 2_800_000 : 3_500_000
        var groups: [CaptionPhrase] = []
        var current: [CaptionCue] = []
        var characters = 0
        var priorSegment: Int?
        for word in track.cues {
            try Task.checkCancellation()
            let segment = segments.firstIndex { $0.sourceRange.start <= word.sourceRange.start &&
                word.sourceRange.end <= $0.sourceRange.end }
            let previous = current.last
            let gap = previous.map { word.sourceRange.start.microseconds - $0.sourceRange.end.microseconds } ?? 0
            let punctuation = previous?.text.last.map { ".!?".contains($0) } ?? false
            let commaBreak = previous?.text.last == "," && gap >= 180_000 && current.count >= 2
            let projectedCharacters = characters + word.text.count + (current.isEmpty ? 0 : 1)
            let elapsed = word.sourceRange.end.microseconds - (current.first?.sourceRange.start.microseconds ??
                word.sourceRange.start.microseconds)
            let rapidAndDense = elapsed > 0 && Double(current.count + 1) * 1_000_000 / Double(elapsed) > 3.5 &&
                projectedCharacters > maxCharacters * 2 / 3
            if !current.isEmpty && (segment != priorSegment || gap > 450_000 || punctuation || commaBreak ||
                current.count >= maxWords || projectedCharacters > maxCharacters ||
                elapsed > maxDuration || rapidAndDense) {
                groups.append(try CaptionPhrase(words: current))
                current = []
                characters = 0
            }
            current.append(word)
            characters += word.text.count + (current.count == 1 ? 0 : 1)
            priorSegment = segment
        }
        if !current.isEmpty { groups.append(try CaptionPhrase(words: current)) }
        phrases = groups
    }

    public func phrase(at sourceTime: MediaTime) -> CaptionPhrase? {
        activePhrase(at: sourceTime)?.phrase
    }

    func activePhrase(at sourceTime: MediaTime) -> (phrase: CaptionPhrase, visibleEnd: Int64)? {
        var low = 0
        var high = phrases.count
        while low < high {
            let middle = (low + high) / 2
            if phrases[middle].range.start <= sourceTime { low = middle + 1 }
            else { high = middle }
        }
        guard low > 0 else { return nil }
        let index = low - 1
        let phrase = phrases[index]
        let nextStart = index + 1 < phrases.count ? phrases[index + 1].range.start.microseconds : Int64.max
        let hold = min(350_000, Int64.max - phrase.range.end.microseconds)
        let visibleEnd = min(nextStart, phrase.range.end.microseconds + hold)
        return sourceTime.microseconds < visibleEnd ? (phrase, visibleEnd) : nil
    }
}
