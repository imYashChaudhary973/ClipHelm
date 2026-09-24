import Foundation
import AVFoundation
import Vision
import CoreGraphics
import ClipHelmCore
import ClipHelmMedia

struct VideoSample: Sendable {
    let time: MediaTime
    let motion: Double
    let cut: Double
    let edgeDensity: Double
    let textDensity: Double
    let screenScore: Double
    let detections: [SubjectDetection]
    let subjectsReliable: Bool
    let textReliable: Bool
}

struct LocalVideoSampler: Sendable {
    func sample(sourceURL: URL, asset: MediaAsset,
                progress: @escaping AnalysisProgressHandler) async throws -> [VideoSample] {
        try await runAnalysisOffMain {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            let source = AVURLAsset(url: sourceURL, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            let generator = AVAssetImageGenerator(asset: source)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

            let duration = asset.duration.microseconds
            let interval = max(Int64(1_000_000), duration / 3_600)
            let count = Int((duration - 1) / interval + 1)
            var samples: [VideoSample] = []
            var previousPixels: [UInt8]?
            var previousHistogram: [Int]?
            for index in 0..<count {
                try Task.checkCancellation()
                let requested = min(duration - 1, Int64(index) * interval + interval / 2)
                do {
                    let (image, actual) = try await generator.image(
                        at: CMTime(value: requested, timescale: 1_000_000))
                    try Task.checkCancellation()
                    guard actual.isNumeric, actual.seconds.isFinite, actual.seconds >= 0,
                          actual.seconds < Double(duration) / 1_000_000 else { continue }
                    let time = try MediaTime(microseconds: Int64((actual.seconds * 1_000_000).rounded()))
                    guard samples.last.map({ $0.time < time }) ?? true else { continue }
                    let pixels = try FramePixels(image: image)
                    let difference = previousPixels.map { pixels.difference(from: $0) } ?? 0
                    let histogramChange = previousHistogram.map { pixels.histogramDifference(from: $0) } ?? 0
                    let cut = difference > 0.23 && histogramChange > 0.12
                        ? min(1, (difference - 0.23) / 0.30 + (histogramChange - 0.12) / 0.30) : 0
                    let detected = try? SubjectDetector().detect(image: image, time: time)
                    let measuredText = index.isMultiple(of: 3)
                        ? try? ScreenContentSignals().textDensity(image: image) : nil
                    let text = measuredText ?? (samples.last?.textDensity ?? 0)
                    let screen = ScreenContentSignals().score(textDensity: text, edgeDensity: pixels.edgeDensity)
                    samples.append(VideoSample(time: time, motion: min(1, difference / 0.30),
                        cut: cut, edgeDensity: pixels.edgeDensity, textDensity: text,
                        screenScore: screen, detections: detected ?? [],
                        subjectsReliable: detected != nil,
                        textReliable: measuredText != nil || (samples.last?.textReliable ?? false)))
                    previousPixels = pixels.bytes
                    previousHistogram = pixels.histogram
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A damaged or undecodable sample lowers coverage; other frames can still be useful.
                }
                progress(.init(stage: .video, fraction: Double(index + 1) / Double(count)))
            }
            guard !samples.isEmpty else { throw MediaEngineError.unsupportedMedia }
            return samples
        }
    }
}

private struct FramePixels {
    let bytes: [UInt8]
    let histogram: [Int]
    let edgeDensity: Double

    init(image: CGImage) throws {
        let width = 64, height = 64
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let drew = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw MediaEngineError.processingFailed }
        bytes = raw
        var bins = [Int](repeating: 0, count: 48)
        var edges = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<3 { bins[channel * 16 + Int(raw[offset + channel]) / 16] += 1 }
                if x > 0 {
                    let left = offset - 4
                    let delta = (0..<3).reduce(0) { $0 + abs(Int(raw[offset + $1]) - Int(raw[left + $1])) }
                    if delta > 72 { edges += 1 }
                }
            }
        }
        histogram = bins
        edgeDensity = Double(edges) / Double(height * (width - 1))
    }

    func difference(from previous: [UInt8]) -> Double {
        guard previous.count == bytes.count else { return 0 }
        var sum = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 { sum += abs(Int(bytes[index + channel]) - Int(previous[index + channel])) }
        }
        return Double(sum) / Double(64 * 64 * 3 * 255)
    }

    func histogramDifference(from previous: [Int]) -> Double {
        guard previous.count == histogram.count else { return 0 }
        let sum = zip(histogram, previous).reduce(0) { $0 + abs($1.0 - $1.1) }
        return Double(sum) / Double(64 * 64 * 3 * 2)
    }
}

public struct SubjectDetector: Sendable {
    public init() { }

    public func detect(image: CGImage, time: MediaTime) throws -> [SubjectDetection] {
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([faces, people])
        let faceResults = faces.results ?? []
        let bodyResults = (people.results ?? []).filter { body in
            !faceResults.contains { body.boundingBox.contains(CGPoint(x: $0.boundingBox.midX,
                                                                    y: $0.boundingBox.midY)) }
        }
        let observations: [(VNDetectedObjectObservation, Bool)] =
            faceResults.map { ($0, true) } + bodyResults.map { ($0, false) }
        return try observations.compactMap { observation, isFace in
            let box = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
            let bounds = try NormalizedRect(x: box.minX, y: 1 - box.maxY,
                                            width: box.width, height: box.height)
            return try SubjectDetection(time: time, bounds: bounds,
                                        confidence: Double(observation.confidence), isFace: isFace)
        }
    }
}

public struct SubjectTracker: Sendable {
    public init() { }

    public func track(assetID: AssetID, detections: [SubjectDetection],
                      maximumGap: Int64 = 3_000_000) throws -> [SubjectTrack] {
        guard maximumGap > 0 else { throw ModelError.invalid("SubjectTracker.maximumGap") }
        var groups: [[SubjectDetection]] = []
        for detection in detections.sorted(by: { $0.time < $1.time }) {
            var best: (index: Int, distance: Double)?
            for index in groups.indices {
                guard let last = groups[index].last, last.isFace == detection.isFace,
                      last.time < detection.time,
                      detection.time.microseconds - last.time.microseconds <= maximumGap else { continue }
                let dx = last.bounds.x + last.bounds.width / 2 - detection.bounds.x - detection.bounds.width / 2
                let dy = last.bounds.y + last.bounds.height / 2 - detection.bounds.y - detection.bounds.height / 2
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < 0.20 && (best == nil || distance < best!.distance) {
                    best = (index, distance)
                }
            }
            if let best { groups[best.index].append(detection) }
            else { groups.append([detection]) }
        }
        return try groups.map { group in
            try SubjectTrack(assetID: assetID,
                observations: group.map { SubjectObservation(time: $0.time, bounds: $0.bounds) })
        }
    }
}

public struct SceneDetector: Sendable {
    public init() { }

    func detect(asset: MediaAsset, samples: [VideoSample]) throws -> ([Scene], [LocalSignal]) {
        var boundaries: [(MediaTime, Double)] = []
        for pair in zip(samples, samples.dropFirst()) where pair.1.cut >= 0.55 {
            let midpoint = pair.0.time.microseconds +
                (pair.1.time.microseconds - pair.0.time.microseconds) / 2
            guard midpoint > (boundaries.last?.0.microseconds ?? 0) + 500_000,
                  midpoint < asset.duration.microseconds else { continue }
            let sampleGap = pair.1.time.microseconds - pair.0.time.microseconds
            let confidence = pair.1.cut * min(0.85, 850_000 / Double(sampleGap))
            boundaries.append((try MediaTime(microseconds: midpoint), confidence))
        }
        let start = try MediaTime(microseconds: 0)
        let points = [start] + boundaries.map(\.0) + [asset.duration]
        let scenes = try zip(points, points.dropFirst()).map {
            Scene(assetID: asset.id, range: try MediaTimeRange(start: $0, end: $1))
        }
        let changes = try boundaries.map { boundary in
            let end = try MediaTime(microseconds: min(asset.duration.microseconds,
                boundary.0.microseconds + 1))
            return try LocalSignal(kind: .sceneChange,
                range: MediaTimeRange(start: boundary.0, end: end),
                strength: min(1, boundary.1 / 0.85), confidence: boundary.1)
        }
        return (scenes, changes)
    }
}

public struct MotionAnalyzer: Sendable {
    public init() { }

    func analyze(asset: MediaAsset, samples: [VideoSample]) throws -> [LocalSignal] {
        try samples.enumerated().map { index, sample in
            let range = try sampleRange(index: index, samples: samples, duration: asset.duration)
            return try LocalSignal(kind: .motion, range: range,
                strength: sample.cut >= 0.55 ? 0 : sample.motion,
                confidence: (index == 0 ? 0.25 : 0.60) *
                    min(1, 1_000_000 / Double(range.durationMicroseconds)))
        }
    }
}

public struct ScreenContentSignals: Sendable {
    public init() { }

    func textDensity(image: CGImage) throws -> Double {
        let request = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return min(1, Double(request.results?.count ?? 0) / 12)
    }

    func score(textDensity: Double, edgeDensity: Double) -> Double {
        textDensity > 0.08 ? min(1, textDensity * 0.75 + edgeDensity * 0.25)
            : min(0.08, edgeDensity * 0.08)
    }

    func analyze(asset: MediaAsset, samples: [VideoSample]) throws -> [LocalSignal] {
        try samples.enumerated().flatMap { index, sample in
            let range = try sampleRange(index: index, samples: samples, duration: asset.duration)
            let coverage = min(1, 1_000_000 / Double(range.durationMicroseconds))
            return [
                try LocalSignal(kind: .screenContent, range: range,
                    strength: sample.screenScore,
                    confidence: (sample.textReliable ? (index.isMultiple(of: 3) ? 0.65 : 0.4) : 0.1) * coverage),
                try LocalSignal(kind: .textDensity, range: range,
                    strength: sample.textDensity,
                    confidence: (sample.textReliable ? (index.isMultiple(of: 3) ? 0.65 : 0.4) : 0.1) * coverage)
            ]
        }
    }
}

private func sampleRange(index: Int, samples: [VideoSample],
                         duration: MediaTime) throws -> MediaTimeRange {
    let start = index == 0 ? 0 :
        samples[index - 1].time.microseconds +
            (samples[index].time.microseconds - samples[index - 1].time.microseconds) / 2
    let end = index == samples.count - 1 ? duration.microseconds :
        samples[index].time.microseconds +
            (samples[index + 1].time.microseconds - samples[index].time.microseconds) / 2
    return try MediaTimeRange(start: MediaTime(microseconds: start),
                              end: MediaTime(microseconds: end))
}
