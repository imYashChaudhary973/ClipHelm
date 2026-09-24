import Foundation

public struct MediaAsset: Codable, Equatable, Sendable {
    public let id: AssetID
    public let displayName: String
    public let duration: MediaTime
    public let width: Int
    public let height: Int

    public init(id: AssetID, displayName: String, duration: MediaTime, width: Int, height: Int) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.microseconds > 0, width > 0, height > 0 else {
            throw ModelError.invalid("MediaAsset")
        }
        self.id = id
        self.displayName = displayName
        self.duration = duration
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, duration, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(AssetID.self, forKey: .id),
                      displayName: c.decode(String.self, forKey: .displayName),
                      duration: c.decode(MediaTime.self, forKey: .duration),
                      width: c.decode(Int.self, forKey: .width),
                      height: c.decode(Int.self, forKey: .height))
    }
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public let text: String
    public let range: MediaTimeRange
    public let confidence: Double?
    public let speakerID: String?

    public init(text: String, range: MediaTimeRange, confidence: Double? = nil,
                speakerID: String? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 200,
              confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              speakerID.map({ !$0.isEmpty && $0.count <= 100 &&
                  $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }) ?? true else {
            throw ModelError.invalid("TranscriptWord")
        }
        self.text = text
        self.range = range
        self.confidence = confidence
        self.speakerID = speakerID
    }

    private enum CodingKeys: String, CodingKey { case text, range, confidence, speakerID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(text: c.decode(String.self, forKey: .text),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      confidence: c.decodeIfPresent(Double.self, forKey: .confidence),
                      speakerID: c.decodeIfPresent(String.self, forKey: .speakerID))
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let range: MediaTimeRange
    public let words: [TranscriptWord]
    public let speakerID: String?
    public var text: String { words.map(\.text).joined(separator: " ") }

    public init(words: [TranscriptWord]) throws {
        guard let first = words.first,
              zip(words, words.dropFirst()).allSatisfy({ $0.range.start <= $1.range.start }),
              words.allSatisfy({ $0.speakerID == first.speakerID }) else {
            throw ModelError.invalid("TranscriptSegment.words")
        }
        range = try MediaTimeRange(start: first.range.start,
                                   end: words.map(\.range.end).max()!)
        self.words = words
        speakerID = first.speakerID
    }

    private enum CodingKeys: String, CodingKey { case range, words, speakerID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(words: c.decode([TranscriptWord].self, forKey: .words))
        guard range == (try c.decode(MediaTimeRange.self, forKey: .range)),
              speakerID == (try c.decodeIfPresent(String.self, forKey: .speakerID)) else {
            throw ModelError.invalid("TranscriptSegment")
        }
    }

}

public struct Transcript: Codable, Equatable, Sendable {
    public let assetID: AssetID
    public let segments: [TranscriptSegment]
    public var words: [TranscriptWord] { segments.flatMap(\.words) }
    public var hasMeaningfulSpeech: Bool { !words.isEmpty }

    public init(assetID: AssetID, segments: [TranscriptSegment]) throws {
        guard zip(segments, segments.dropFirst()).allSatisfy({ $0.range.start <= $1.range.start }) else {
            throw ModelError.invalid("Transcript.segments order")
        }
        self.assetID = assetID
        self.segments = segments
    }

    public init(assetID: AssetID, words: [TranscriptWord]) throws {
        try self.init(assetID: assetID,
                      segments: words.isEmpty ? [] : [TranscriptSegment(words: words)])
    }

    private enum CodingKeys: String, CodingKey { case assetID, segments, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let assetID = try c.decode(AssetID.self, forKey: .assetID)
        if c.contains(.segments) {
            try self.init(assetID: assetID,
                          segments: c.decode([TranscriptSegment].self, forKey: .segments))
        } else {
            try self.init(assetID: assetID,
                          words: c.decode([TranscriptWord].self, forKey: .words))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assetID, forKey: .assetID)
        try c.encode(segments, forKey: .segments)
    }
}

public struct Scene: Codable, Equatable, Sendable {
    public let id: UUID
    public let assetID: AssetID
    public let range: MediaTimeRange

    public init(id: UUID = UUID(), assetID: AssetID, range: MediaTimeRange) {
        self.id = id
        self.assetID = assetID
        self.range = range
    }
}

/// Coordinates are normalized to the source frame, with top-left origin.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw ModelError.invalid("NormalizedRect")
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: c.decode(Double.self, forKey: .x),
                      y: c.decode(Double.self, forKey: .y),
                      width: c.decode(Double.self, forKey: .width),
                      height: c.decode(Double.self, forKey: .height))
    }
}

public struct SubjectObservation: Codable, Equatable, Sendable {
    public let time: MediaTime
    public let bounds: NormalizedRect
    public init(time: MediaTime, bounds: NormalizedRect) {
        self.time = time
        self.bounds = bounds
    }
}

public struct SubjectTrack: Codable, Equatable, Sendable {
    public let id: UUID
    public let assetID: AssetID
    public let observations: [SubjectObservation]

    public init(id: UUID = UUID(), assetID: AssetID, observations: [SubjectObservation]) throws {
        guard !observations.isEmpty,
              zip(observations, observations.dropFirst()).allSatisfy({ $0.time < $1.time }) else {
            throw ModelError.invalid("SubjectTrack.observations")
        }
        self.id = id
        self.assetID = assetID
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, observations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
                      assetID: c.decode(AssetID.self, forKey: .assetID),
                      observations: c.decode([SubjectObservation].self, forKey: .observations))
    }
}
