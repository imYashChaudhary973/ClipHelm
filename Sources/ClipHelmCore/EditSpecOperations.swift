import Foundation

public enum LayoutMode: String, Codable, Sendable {
    case fill, fit, blurredBackground

    public init(framing: FramingMode) {
        switch framing {
        case .smartAuto, .fullFrame: self = .fill
        case .classicFullFrame: self = .fit
        case .blurred: self = .blurredBackground
        }
    }

    public func accepts(_ framing: FramingMode) -> Bool {
        self == Self(framing: framing)
    }
}

/// A fixed, renderer-independent audio decision. No filter strings or commands.
public enum AudioOperation: String, Codable, Sendable {
    case original, normalize, mute

    public init(soundMode: SoundMode) {
        switch soundMode {
        case .source: self = .original
        case .normalize: self = .normalize
        case .mute: self = .mute
        }
    }

    public var soundMode: SoundMode {
        switch self {
        case .original: .source
        case .normalize: .normalize
        case .mute: .mute
        }
    }
}

public struct CropKeyframe: Codable, Equatable, Sendable {
    public let sourceTime: MediaTime
    public let rect: NormalizedRect

    public init(sourceTime: MediaTime, rect: NormalizedRect) {
        self.sourceTime = sourceTime
        self.rect = rect
    }
}

/// One static crop or a linearly interpolated source-time crop trajectory.
public struct CropPath: Codable, Equatable, Sendable {
    public let sourceRange: MediaTimeRange
    public let keyframes: [CropKeyframe]

    public init(sourceRange: MediaTimeRange, keyframes: [CropKeyframe]) throws {
        guard (1...256).contains(keyframes.count),
              keyframes.first?.sourceTime == sourceRange.start,
              (keyframes.count == 1 || keyframes.last?.sourceTime == sourceRange.end),
              zip(keyframes, keyframes.dropFirst()).allSatisfy({ $0.sourceTime < $1.sourceTime }) else {
            throw ModelError.invalid("CropPath.keyframes")
        }
        self.sourceRange = sourceRange
        self.keyframes = keyframes
    }

    public func rect(atSourceTime time: MediaTime) throws -> NormalizedRect {
        guard sourceRange.start <= time, time <= sourceRange.end else {
            throw ModelError.invalid("CropPath time")
        }
        if keyframes.count == 1 { return keyframes[0].rect }
        guard let next = keyframes.firstIndex(where: { time <= $0.sourceTime }) else {
            return keyframes[keyframes.count - 1].rect
        }
        if next == 0 { return keyframes[0].rect }
        let before = keyframes[next - 1]
        let after = keyframes[next]
        let fraction = Double(time.microseconds - before.sourceTime.microseconds) /
                       Double(after.sourceTime.microseconds - before.sourceTime.microseconds)
        func interpolate(_ first: Double, _ last: Double) -> Double {
            first + (last - first) * fraction
        }
        return try NormalizedRect(
            x: interpolate(before.rect.x, after.rect.x),
            y: interpolate(before.rect.y, after.rect.y),
            width: interpolate(before.rect.width, after.rect.width),
            height: interpolate(before.rect.height, after.rect.height))
    }

    private enum CodingKeys: String, CodingKey { case sourceRange, keyframes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceRange: c.decode(MediaTimeRange.self, forKey: .sourceRange),
                      keyframes: c.decode([CropKeyframe].self, forKey: .keyframes))
    }
}

public struct CaptionCue: Codable, Equatable, Sendable {
    public let sourceRange: MediaTimeRange
    public let text: String

    public init(sourceRange: MediaTimeRange, text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelError.invalid("CaptionCue.text")
        }
        self.sourceRange = sourceRange
        self.text = clean
    }

    private enum CodingKeys: String, CodingKey { case sourceRange, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceRange: c.decode(MediaTimeRange.self, forKey: .sourceRange),
                      text: c.decode(String.self, forKey: .text))
    }
}

public struct CaptionTrack: Codable, Equatable, Sendable {
    public let cues: [CaptionCue]
    public let wordByWord: Bool
    public let blurIn: Bool

    public init(cues: [CaptionCue], wordByWord: Bool, blurIn: Bool) throws {
        guard (1...20_000).contains(cues.count),
              zip(cues, cues.dropFirst()).allSatisfy({ $0.sourceRange.end <= $1.sourceRange.start }) else {
            throw ModelError.invalid("CaptionTrack.cues")
        }
        self.cues = cues
        self.wordByWord = wordByWord
        self.blurIn = blurIn
    }

    private enum CodingKeys: String, CodingKey { case cues, wordByWord, blurIn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cues: c.decode([CaptionCue].self, forKey: .cues),
                      wordByWord: c.decode(Bool.self, forKey: .wordByWord),
                      blurIn: c.decode(Bool.self, forKey: .blurIn))
    }
}
