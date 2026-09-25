import Foundation
import Speech
import AVFoundation
import ClipHelmCore

/// On-device long-form transcription. Unlike `SFSpeechRecognizer`, which resets its transcript
/// after a pause and returns only the last utterance of a chunk, `SpeechTranscriber` reports
/// every finalized result with per-word audio time ranges.
@available(macOS 26, *)
public final class SpeechAnalyzerBackend: TranscriptionBackend {
    public let maximumChunkSeconds = 50
    private let locale: Locale

    private init(locale: Locale) { self.locale = locale }

    /// Returns a backend when this Mac supports the current language, installing its
    /// on-device speech model first if needed.
    public static func make(locale requested: Locale = .current) async throws -> SpeechAnalyzerBackend? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return nil }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                      attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        return SpeechAnalyzerBackend(locale: locale)
    }

    public func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audioURL) }
        catch { throw TranscriptEngineError.audioUnreadable }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard seconds.isFinite, seconds > 0, seconds <= 50.5 else { throw TranscriptEngineError.audioUnreadable }
        let maximumTime = Int64((seconds * 1_000_000).rounded())

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var spans: [TimedSpan] = []
            for try await result in transcriber.results {
                spans.append(contentsOf: Self.spans(in: result.text))
            }
            return spans
        }
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                collector.cancel()
            }
            let spans = try await collector.value
            try Task.checkCancellation()
            return try Self.words(from: spans, maximumTime: maximumTime)
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch let error as TranscriptEngineError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptEngineError.unavailable
        }
    }

    struct TimedSpan: Sendable, Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    private static func spans(in text: AttributedString) -> [TimedSpan] {
        text.runs.compactMap { run in
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { return nil }
            return TimedSpan(text: String(text[run.range].characters),
                             start: range.start.seconds, end: range.end.seconds)
        }
    }

    /// Splits timed runs into words, sharing a run's time by character count.
    static func words(from spans: [TimedSpan], maximumTime: Int64) throws -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for span in spans {
            let tokens = span.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty, span.start.isFinite, span.end.isFinite,
                  span.start >= 0, span.end > span.start else { continue }
            let start = Int64((span.start * 1_000_000).rounded())
            let duration = Int64((span.end * 1_000_000).rounded()) - start
            guard duration > 0 else { continue }
            let total = tokens.reduce(0) { $0 + $1.count }
            var preceding = 0
            for token in tokens {
                let first = start + duration * Int64(preceding) / Int64(total)
                preceding += token.count
                let last = start + duration * Int64(preceding) / Int64(total)
                if let range = try AppleSpeechBackend.boundedRange(start: first, end: last,
                                                                     maximumTime: maximumTime) {
                    words.append(try TranscriptWord(text: token, range: range))
                }
            }
        }
        return words.sorted { $0.range.start < $1.range.start }
    }
}

/// Picks the best on-device recognizer this Mac offers.
public enum OnDeviceSpeech {
    public static func backend() async throws -> any TranscriptionBackend {
        if #available(macOS 26, *), let modern = try await SpeechAnalyzerBackend.make() {
            return modern
        }
        return await AppleSpeechBackend()
    }
}
