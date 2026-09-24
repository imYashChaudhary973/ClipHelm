import Foundation

public struct MediaProgress: Sendable {
    public enum Stage: Sendable { case probing, thumbnail, proxy, audio, frames }
    public let stage: Stage
    public let fraction: Double?

    public init(stage: Stage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}

public typealias MediaProgressHandler = @Sendable (MediaProgress) -> Void
