import Foundation

public enum MomentSignalKind: String, Codable, Sendable {
    case topicBoundary, sentenceCompletion, hook, standaloneContext
    case audioEnergy, speakerEmphasis, sceneChange, visualActivity
    case storyCompletion, repetition, contextDependency
}

public struct MomentSignal: Codable, Equatable, Sendable {
    public let kind: MomentSignalKind
    public let range: MediaTimeRange
    public let strength: Double

    public init(kind: MomentSignalKind, range: MediaTimeRange, strength: Double) throws {
        guard strength.isFinite, (0...1).contains(strength) else {
            throw ModelError.invalid("MomentSignal.strength")
        }
        self.kind = kind
        self.range = range
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey { case kind, range, strength }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(MomentSignalKind.self, forKey: .kind),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      strength: c.decode(Double.self, forKey: .strength))
    }
}

public struct MomentCandidate: Codable, Equatable, Sendable {
    public let id: UUID
    public let assetID: AssetID
    public let range: MediaTimeRange
    public let signals: [MomentSignal]
    public let score: Double

    public init(id: UUID = UUID(), assetID: AssetID, range: MediaTimeRange,
                signals: [MomentSignal], score: Double) throws {
        guard score.isFinite, (0...1).contains(score),
              signals.allSatisfy({ range.start <= $0.range.start && $0.range.end <= range.end }) else {
            throw ModelError.invalid("MomentCandidate")
        }
        self.id = id
        self.assetID = assetID
        self.range = range
        self.signals = signals
        self.score = score
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, range, signals, score }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
                      assetID: c.decode(AssetID.self, forKey: .assetID),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      signals: c.decode([MomentSignal].self, forKey: .signals),
                      score: c.decode(Double.self, forKey: .score))
    }
}

/// Semantic suggestion only. It cannot encode paths, filters, or renderer commands.
public struct ClipProposal: Codable, Equatable, Sendable {
    public let id: UUID
    public let assetID: AssetID
    public let range: MediaTimeRange
    public let title: String
    public let rationale: String
    public let confidence: Double

    public init(id: UUID = UUID(), assetID: AssetID, range: MediaTimeRange,
                title: String, rationale: String, confidence: Double) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 120, rationale.count <= 1000,
              confidence.isFinite, (0...1).contains(confidence) else {
            throw ModelError.invalid("ClipProposal")
        }
        self.id = id
        self.assetID = assetID
        self.range = range
        self.title = title
        self.rationale = rationale
        self.confidence = confidence
    }

    public func validate(for asset: MediaAsset) throws {
        guard assetID == asset.id, range.end <= asset.duration else {
            throw ModelError.invalid("ClipProposal source bounds")
        }
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, range, title, rationale, confidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
                      assetID: c.decode(AssetID.self, forKey: .assetID),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      title: c.decode(String.self, forKey: .title),
                      rationale: c.decode(String.self, forKey: .rationale),
                      confidence: c.decode(Double.self, forKey: .confidence))
    }
}

public struct AIEditIntent: Codable, Equatable, Sendable {
    public let proposalID: UUID
    public let suggestedRange: MediaTimeRange?
    public let preserveDemo: Bool
    public let framingPreference: FramingMode?

    public init(proposalID: UUID, suggestedRange: MediaTimeRange? = nil,
                preserveDemo: Bool = false, framingPreference: FramingMode? = nil) {
        self.proposalID = proposalID
        self.suggestedRange = suggestedRange
        self.preserveDemo = preserveDemo
        self.framingPreference = framingPreference
    }

    public func validate(for proposal: ClipProposal) throws {
        guard proposalID == proposal.id else { throw ModelError.invalid("AIEditIntent.proposalID") }
        if let suggestedRange {
            guard proposal.range.start <= suggestedRange.start,
                  suggestedRange.end <= proposal.range.end else {
                throw ModelError.invalid("AIEditIntent.suggestedRange")
            }
        }
    }
}
