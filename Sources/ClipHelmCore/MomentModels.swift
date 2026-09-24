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
    public let score: MomentScore

    public init(id: UUID = UUID(), assetID: AssetID, range: MediaTimeRange,
                signals: [MomentSignal], score: MomentScore) throws {
        guard signals.allSatisfy({ range.start <= $0.range.start && $0.range.end <= range.end }) else {
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
                      score: c.decode(MomentScore.self, forKey: .score))
    }
}

/// Explicit evidence dimensions. Dependency and repetition reduce quality.
public struct MomentScore: Codable, Equatable, Sendable {
    public let hook: Double
    public let standaloneCompleteness: Double
    public let insight: Double
    public let story: Double
    public let questionAnswerCompletion: Double
    public let educationalValue: Double
    public let interest: Double
    public let contextDependency: Double
    public let repetition: Double
    public let localEvidence: Double

    public init(hook: Double, standaloneCompleteness: Double, insight: Double,
                story: Double, questionAnswerCompletion: Double, educationalValue: Double,
                interest: Double, contextDependency: Double, repetition: Double,
                localEvidence: Double = 0) throws {
        let values = [hook, standaloneCompleteness, insight, story, questionAnswerCompletion,
                      educationalValue, interest, contextDependency, repetition, localEvidence]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ModelError.invalid("MomentScore")
        }
        self.hook = hook
        self.standaloneCompleteness = standaloneCompleteness
        self.insight = insight
        self.story = story
        self.questionAnswerCompletion = questionAnswerCompletion
        self.educationalValue = educationalValue
        self.interest = interest
        self.contextDependency = contextDependency
        self.repetition = repetition
        self.localEvidence = localEvidence
    }

    public var quality: Double {
        let positive = (hook + 1.5 * standaloneCompleteness + insight + story +
                        questionAnswerCompletion + educationalValue + interest + localEvidence) / 8.5
        return max(0, min(1, positive - 0.2 * contextDependency - 0.15 * repetition))
    }

    public func withLocalEvidence(_ value: Double) throws -> Self {
        try Self(hook: hook, standaloneCompleteness: standaloneCompleteness, insight: insight,
                 story: story, questionAnswerCompletion: questionAnswerCompletion,
                 educationalValue: educationalValue, interest: interest,
                 contextDependency: contextDependency, repetition: repetition, localEvidence: value)
    }

    private enum CodingKeys: String, CodingKey {
        case hook, standaloneCompleteness, insight, story, questionAnswerCompletion
        case educationalValue, interest, contextDependency, repetition, localEvidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hook: c.decode(Double.self, forKey: .hook),
                      standaloneCompleteness: c.decode(Double.self, forKey: .standaloneCompleteness),
                      insight: c.decode(Double.self, forKey: .insight), story: c.decode(Double.self, forKey: .story),
                      questionAnswerCompletion: c.decode(Double.self, forKey: .questionAnswerCompletion),
                      educationalValue: c.decode(Double.self, forKey: .educationalValue),
                      interest: c.decode(Double.self, forKey: .interest),
                      contextDependency: c.decode(Double.self, forKey: .contextDependency),
                      repetition: c.decode(Double.self, forKey: .repetition),
                      localEvidence: c.decodeIfPresent(Double.self, forKey: .localEvidence) ?? 0)
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
    public let score: MomentScore?

    public init(id: UUID = UUID(), assetID: AssetID, range: MediaTimeRange,
                title: String, rationale: String, confidence: Double,
                score: MomentScore? = nil) throws {
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
        self.score = score
    }

    public func validate(for asset: MediaAsset) throws {
        guard assetID == asset.id, range.end <= asset.duration else {
            throw ModelError.invalid("ClipProposal source bounds")
        }
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, range, title, rationale, confidence, score }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
                      assetID: c.decode(AssetID.self, forKey: .assetID),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      title: c.decode(String.self, forKey: .title),
                      rationale: c.decode(String.self, forKey: .rationale),
                      confidence: c.decode(Double.self, forKey: .confidence),
                      score: c.decodeIfPresent(MomentScore.self, forKey: .score))
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
