import Foundation

public enum FramingMode: String, Codable, Sendable {
    case smartAuto, fullFrame, classicFullFrame, blurred
}

public enum PacingMode: String, Codable, CaseIterable, Sendable {
    case natural, balanced, tight, fast
}

public enum CaptionStyle: String, Codable, Sendable {
    case pop, spotlight, impact, glowBox, editorial, highPunch, neonHeadline, paper
}

public enum SoundMode: String, Codable, Sendable {
    case source, normalize, mute
}

public enum ClipLength: String, Codable, CaseIterable, Sendable {
    case seconds10to30, seconds30to60, minutes1to2, minutes2to5
    case minutes5to10, minutes10to15, minutes15to30

    public var boundsSeconds: ClosedRange<Int> {
        switch self {
        case .seconds10to30: 10...30
        case .seconds30to60: 30...60
        case .minutes1to2: 60...120
        case .minutes2to5: 120...300
        case .minutes5to10: 300...600
        case .minutes10to15: 600...900
        case .minutes15to30: 900...1800
        }
    }
}

/// Target canvas dimensions. V1 presents only the two standard presets.
public struct OutputFormat: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public static let vertical = try! Self(width: 1080, height: 1920)
    public static let horizontal = try! Self(width: 1920, height: 1080)

    public init(width: Int, height: Int) throws {
        guard (1...16_384).contains(width), (1...16_384).contains(height) else {
            throw ModelError.invalid("OutputFormat dimensions")
        }
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width),
                      height: c.decode(Int.self, forKey: .height))
    }
}

public struct SmartEditOptions: Codable, Equatable, Sendable {
    public var useVisionForTrickyShots: Bool
    public var cutDeadAir: Bool
    public var trimLongPauses: Bool
    public var cleanFillers: Bool
    public var keepDemos: Bool

    public init(useVisionForTrickyShots: Bool, cutDeadAir: Bool,
                trimLongPauses: Bool, cleanFillers: Bool, keepDemos: Bool) {
        self.useVisionForTrickyShots = useVisionForTrickyShots
        self.cutDeadAir = cutDeadAir
        self.trimLongPauses = trimLongPauses
        self.cleanFillers = cleanFillers
        self.keepDemos = keepDemos
    }
}

public struct ClipConfiguration: Codable, Equatable, Sendable {
    public let outputFormat: OutputFormat
    public let framingMode: FramingMode
    public let pacingMode: PacingMode
    public let selectedLengths: [ClipLength]
    public let requestedClipCount: Int?
    public let soundMode: SoundMode
    public let captionStyle: CaptionStyle?
    public let captionWordByWord: Bool
    public let captionBlurIn: Bool
    public let smartEdit: SmartEditOptions

    public init(outputFormat: OutputFormat, framingMode: FramingMode, pacingMode: PacingMode,
                selectedLengths: [ClipLength], requestedClipCount: Int?, soundMode: SoundMode,
                captionStyle: CaptionStyle?, smartEdit: SmartEditOptions,
                captionWordByWord: Bool = false, captionBlurIn: Bool = false) throws {
        guard Set(selectedLengths).count == selectedLengths.count,
              requestedClipCount.map({ (1...1_000).contains($0) }) ?? true,
              captionStyle != nil || (!captionWordByWord && !captionBlurIn) else {
            throw ModelError.invalid("ClipConfiguration")
        }
        self.outputFormat = outputFormat
        self.framingMode = framingMode
        self.pacingMode = pacingMode
        self.selectedLengths = selectedLengths
        self.requestedClipCount = requestedClipCount
        self.soundMode = soundMode
        self.captionStyle = captionStyle
        self.captionWordByWord = captionWordByWord
        self.captionBlurIn = captionBlurIn
        self.smartEdit = smartEdit
    }

    public func disablingCaptions() throws -> Self {
        try Self(outputFormat: outputFormat, framingMode: framingMode, pacingMode: pacingMode,
                 selectedLengths: selectedLengths, requestedClipCount: requestedClipCount,
                 soundMode: soundMode, captionStyle: nil, smartEdit: smartEdit)
    }

    private enum CodingKeys: String, CodingKey {
        case outputFormat, framingMode, pacingMode, selectedLengths
        case requestedClipCount, soundMode, captionStyle, smartEdit, captionWordByWord, captionBlurIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(outputFormat: c.decode(OutputFormat.self, forKey: .outputFormat),
                      framingMode: c.decode(FramingMode.self, forKey: .framingMode),
                      pacingMode: c.decode(PacingMode.self, forKey: .pacingMode),
                      selectedLengths: c.decode([ClipLength].self, forKey: .selectedLengths),
                      requestedClipCount: c.decodeIfPresent(Int.self, forKey: .requestedClipCount),
                      soundMode: c.decode(SoundMode.self, forKey: .soundMode),
                      captionStyle: c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle),
                      smartEdit: c.decode(SmartEditOptions.self, forKey: .smartEdit),
                      captionWordByWord: c.decodeIfPresent(Bool.self, forKey: .captionWordByWord) ?? false,
                      captionBlurIn: c.decodeIfPresent(Bool.self, forKey: .captionBlurIn) ?? false)
    }
}

/// One retained source interval, in output order. No filesystem or renderer input.
public struct EditSegment: Codable, Equatable, Sendable {
    public let sourceRange: MediaTimeRange
    public init(sourceRange: MediaTimeRange) { self.sourceRange = sourceRange }
}

public struct ClipHelmEditSpec: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let schemaVersion: Int
    public let clipID: ClipID
    public let sourceAssetID: AssetID
    public let segments: [EditSegment]
    public let outputFormat: OutputFormat
    public let framingMode: FramingMode
    public let pacingMode: PacingMode
    public let soundMode: SoundMode
    public let captionStyle: CaptionStyle?

    public init(schemaVersion: Int = Self.currentVersion, clipID: ClipID,
                sourceAssetID: AssetID, segments: [EditSegment], outputFormat: OutputFormat,
                framingMode: FramingMode, pacingMode: PacingMode, soundMode: SoundMode,
                captionStyle: CaptionStyle?) throws {
        guard schemaVersion == Self.currentVersion, !segments.isEmpty,
              zip(segments, segments.dropFirst()).allSatisfy({ $0.sourceRange.end <= $1.sourceRange.start }) else {
            throw ModelError.invalid("ClipHelmEditSpec")
        }
        self.schemaVersion = schemaVersion
        self.clipID = clipID
        self.sourceAssetID = sourceAssetID
        self.segments = segments
        self.outputFormat = outputFormat
        self.framingMode = framingMode
        self.pacingMode = pacingMode
        self.soundMode = soundMode
        self.captionStyle = captionStyle
    }

    public func validate(for asset: MediaAsset) throws {
        guard sourceAssetID == asset.id,
              segments.allSatisfy({ $0.sourceRange.end <= asset.duration }) else {
            throw ModelError.invalid("ClipHelmEditSpec source bounds")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, clipID, sourceAssetID, segments, outputFormat
        case framingMode, pacingMode, soundMode, captionStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
                      clipID: c.decode(ClipID.self, forKey: .clipID),
                      sourceAssetID: c.decode(AssetID.self, forKey: .sourceAssetID),
                      segments: c.decode([EditSegment].self, forKey: .segments),
                      outputFormat: c.decode(OutputFormat.self, forKey: .outputFormat),
                      framingMode: c.decode(FramingMode.self, forKey: .framingMode),
                      pacingMode: c.decode(PacingMode.self, forKey: .pacingMode),
                      soundMode: c.decode(SoundMode.self, forKey: .soundMode),
                      captionStyle: c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle))
    }
}
