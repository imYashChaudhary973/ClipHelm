import Foundation

/// Maps source and proxy presentation times without cumulative floating-point drift.
public struct MediaTimeMap: Codable, Equatable, Sendable {
    public let source: MediaTimeRange
    public let proxy: MediaTimeRange

    public init(source: MediaTimeRange, proxy: MediaTimeRange) {
        self.source = source
        self.proxy = proxy
    }

    public func proxyTime(for sourceTime: MediaTime) throws -> MediaTime {
        try map(sourceTime, from: source, to: proxy)
    }

    public func sourceTime(for proxyTime: MediaTime) throws -> MediaTime {
        try map(proxyTime, from: proxy, to: source)
    }

    private func map(_ time: MediaTime, from input: MediaTimeRange,
                     to output: MediaTimeRange) throws -> MediaTime {
        guard input.start <= time, time <= input.end else {
            throw ModelError.invalid("MediaTimeMap time outside range")
        }
        let offset = UInt64(time.microseconds - input.start.microseconds)
        let numerator = offset.multipliedFullWidth(by: UInt64(output.durationMicroseconds))
        let (quotient, remainder) = UInt64(input.durationMicroseconds).dividingFullWidth(numerator)
        let rounded = quotient + (remainder >= (UInt64(input.durationMicroseconds) + 1) / 2 ? 1 : 0)
        return try MediaTime(microseconds: output.start.microseconds + Int64(rounded))
    }
}
