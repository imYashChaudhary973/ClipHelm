import Foundation
import ClipHelmCore

public struct EditSpecValidator: Sendable {
    public init() { }

    @discardableResult
    public func validate(_ spec: ClipHelmEditSpec, for asset: MediaAsset,
                         proposal: ClipProposal? = nil) throws -> EditTimeline {
        try spec.validate(for: asset)
        if let proposal {
            try proposal.validate(for: asset)
            guard spec.segments.allSatisfy({ proposal.range.start <= $0.sourceRange.start &&
                                             $0.sourceRange.end <= proposal.range.end }) else {
                throw ModelError.invalid("EditSpec outside proposal")
            }
        }
        let targetAspect = Double(spec.outputFormat.width) / Double(spec.outputFormat.height)
        for path in spec.cropPaths {
            for keyframe in path.keyframes {
                let rect = keyframe.rect
                let cropAspect = Double(asset.width) * rect.width / (Double(asset.height) * rect.height)
                guard cropAspect.isFinite, abs(cropAspect / targetAspect - 1) <= 0.002 else {
                    throw ModelError.invalid("EditSpec crop aspect")
                }
            }
        }
        return try EditTimeline(spec: spec)
    }
}
