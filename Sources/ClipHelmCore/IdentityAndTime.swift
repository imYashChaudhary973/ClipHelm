import Foundation

public enum ModelError: Error, Equatable, Sendable {
    case invalid(String)
}

public struct ProjectID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AssetID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ClipID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Integer microseconds avoid floating-point drift in persisted timelines.
public struct MediaTime: Hashable, Comparable, Codable, Sendable {
    public let microseconds: Int64

    public init(microseconds: Int64) throws {
        guard microseconds >= 0 else { throw ModelError.invalid("MediaTime.microseconds") }
        self.microseconds = microseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.microseconds < rhs.microseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(microseconds: container.decode(Int64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(microseconds)
    }
}

/// Half-open interval: start is included, end is excluded.
public struct MediaTimeRange: Hashable, Codable, Sendable {
    public let start: MediaTime
    public let end: MediaTime

    public init(start: MediaTime, end: MediaTime) throws {
        guard start < end else { throw ModelError.invalid("MediaTimeRange") }
        self.start = start
        self.end = end
    }

    public var durationMicroseconds: Int64 { end.microseconds - start.microseconds }

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: container.decode(MediaTime.self, forKey: .start),
            end: container.decode(MediaTime.self, forKey: .end)
        )
    }
}
