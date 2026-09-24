import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import ClipHelmCore
import ClipHelmMedia

public struct AudioActivityDetector: Sendable {
    public init() { }

    public func analyze(sourceURL: URL, asset: MediaAsset, hasAudio: Bool,
                        progress: @escaping AnalysisProgressHandler = { _ in }) async throws -> [LocalSignal] {
        guard hasAudio else { return [] }
        return try await runAnalysisOffMain {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            let source = AVURLAsset(url: sourceURL, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            guard let track = try await source.loadTracks(withMediaType: .audio).first else { return [] }
            let reader = try AVAssetReader(asset: source)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { throw MediaEngineError.processingFailed }
            reader.add(output)
            guard reader.startReading() else { throw MediaEngineError.processingFailed }
            // Keep long recordings bounded while retaining 250 ms resolution for normal projects.
            let targetSamples = max(Int64(4_000),
                Int64((Double(asset.duration.microseconds) * 16_000 / 1_000_000 / 100_000).rounded(.up)))
            let windowSamples = ((targetSamples + 15) / 16) * 16
            let windowMicros = windowSamples * 1_000_000 / 16_000
            let totalWindows = (asset.duration.microseconds - 1) / windowMicros + 1
            var signals: [LocalSignal] = []
            var bucket: Int64 = 0
            var sumSquares = 0.0
            var count = 0
            var lastProgress = -1.0

            func finishBucket() throws {
                try Task.checkCancellation()
                let start = bucket * windowMicros
                guard start < asset.duration.microseconds else { return }
                let end = min(asset.duration.microseconds, start + windowMicros)
                let rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
                let activity = min(1, rms / 0.12)
                let timeResolution = min(1, 250_000 / Double(windowMicros))
                let confidence = (count == 0 ? 0.3 : min(0.85, 0.45 + abs(rms - 0.008) * 8))
                    * timeResolution
                signals.append(try LocalSignal(kind: .audioActivity,
                    range: MediaTimeRange(start: MediaTime(microseconds: start),
                                          end: MediaTime(microseconds: end)),
                    strength: activity, confidence: confidence))
                bucket += 1
                sumSquares = 0
                count = 0
            }

            do {
                while let sampleBuffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    guard timestamp.isNumeric, timestamp.seconds.isFinite,
                          timestamp.seconds >= 0,
                          let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                    let byteCount = CMBlockBufferGetDataLength(block)
                    guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) else { continue }
                    var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                    let status = samples.withUnsafeMutableBytes { destination in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0,
                            dataLength: byteCount, destination: destination.baseAddress!)
                    }
                    guard status == noErr else { throw MediaEngineError.processingFailed }
                    let firstSample = Int64((timestamp.seconds * 16_000).rounded())
                    for (index, value) in samples.enumerated() {
                        let target = (firstSample + Int64(index)) / windowSamples
                        guard target >= 0, target < totalWindows else { continue }
                        while bucket < target { try finishBucket() }
                        let finite = value.isFinite ? Double(value) : 0
                        sumSquares += finite * finite
                        count += 1
                    }
                    let fraction = min(1, timestamp.seconds * 1_000_000 / Double(asset.duration.microseconds))
                    if fraction - lastProgress >= 0.02 {
                        progress(.init(stage: .audio, fraction: fraction))
                        lastProgress = fraction
                    }
                }
                guard reader.status == .completed else { throw MediaEngineError.processingFailed }
                while bucket < totalWindows { try finishBucket() }
                progress(.init(stage: .audio, fraction: 1))
                return signals
            } catch {
                reader.cancelReading()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }
}

public struct PauseDetector: Sendable {
    public init() { }

    /// Quiet audio is a possible pause, not proof of a speech pause.
    public func detect(activity: [LocalSignal], minimumDuration: Int64 = 500_000) throws -> [LocalSignal] {
        guard minimumDuration > 0 else { throw ModelError.invalid("PauseDetector.minimumDuration") }
        var pauses: [LocalSignal] = []
        var start: MediaTime?
        var end: MediaTime?
        var confidence = 1.0
        for signal in activity where signal.kind == .audioActivity {
            if signal.strength < 0.075 {
                if start == nil { start = signal.range.start }
                end = signal.range.end
                confidence = min(confidence, signal.confidence)
            } else if let pauseStart = start, let pauseEnd = end {
                if pauseEnd.microseconds - pauseStart.microseconds >= minimumDuration {
                    pauses.append(try LocalSignal(kind: .pause,
                        range: MediaTimeRange(start: pauseStart, end: pauseEnd),
                        strength: min(1, Double(pauseEnd.microseconds - pauseStart.microseconds) / 2_000_000),
                        confidence: min(0.7, confidence)))
                }
                start = nil
                end = nil
                confidence = 1
            }
        }
        if let start, let end, end.microseconds - start.microseconds >= minimumDuration {
            pauses.append(try LocalSignal(kind: .pause,
                range: MediaTimeRange(start: start, end: end),
                strength: min(1, Double(end.microseconds - start.microseconds) / 2_000_000),
                confidence: min(0.7, confidence)))
        }
        return pauses
    }
}
