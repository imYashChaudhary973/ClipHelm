import Foundation
import ClipHelmCore

public struct FrameSampler: Sendable {
    public init() { }

    public func sample(fileURL: URL, range: MediaTimeRange, count: Int,
                       outputDirectory: URL, maximumDimension: Int = 720,
                       progress: @escaping MediaProgressHandler = { _ in }) async throws -> [Thumbnail] {
        guard (1...48).contains(count), range.durationMicroseconds >= Int64(count) else {
            throw MediaEngineError.invalidTime
        }
        let lastOffset = UInt64(range.durationMicroseconds - 1)
        let denominator = UInt64(max(1, count - 1))
        let times = try (0..<count).map { index in
            let offset = count == 1 ? lastOffset / 2
                : denominator.dividingFullWidth(lastOffset.multipliedFullWidth(by: UInt64(index))).quotient
            return try MediaTime(microseconds: range.start.microseconds + Int64(offset))
        }
        return try await ThumbnailEngine().generate(fileURL: fileURL, at: times,
            outputDirectory: outputDirectory, maximumDimension: maximumDimension) { update in
            progress(MediaProgress(stage: .frames, fraction: update.fraction))
        }
    }
}
