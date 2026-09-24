import Foundation
import Speech
import ClipHelmCore

@MainActor
public final class AppleSpeechBackend: TranscriptionBackend {
    public let maximumChunkSeconds = 50

    public init() { }

    public func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptEngineError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptEngineError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let completion = RecognitionCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.setContinuation(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        do { completion.finish(.success(try Self.words(from: result))) }
                        catch { completion.finish(.failure(TranscriptEngineError.invalidWordTimings)) }
                    } else if error != nil {
                        completion.finish(.failure(TranscriptEngineError.unavailable))
                    }
                }
                completion.setTask(task)
            }
        } onCancel: {
            completion.cancel()
        }
    }

    nonisolated private static func words(from result: SFSpeechRecognitionResult) throws -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for segment in result.bestTranscription.segments {
            let tokens = segment.substring.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty, segment.timestamp.isFinite,
                  segment.duration.isFinite, segment.timestamp >= 0,
                  segment.duration > 0 else { continue }
            let start = Int64((segment.timestamp * 1_000_000).rounded())
            let duration = Int64((segment.duration * 1_000_000).rounded())
            let total = tokens.reduce(0) { $0 + $1.count }
            var preceding = 0
            for token in tokens {
                let first = start + duration * Int64(preceding) / Int64(total)
                preceding += token.count
                let last = start + duration * Int64(preceding) / Int64(total)
                guard last > first else { continue }
                words.append(try TranscriptWord(text: token,
                    range: MediaTimeRange(start: MediaTime(microseconds: first),
                                          end: MediaTime(microseconds: last)),
                    confidence: Double(segment.confidence)))
            }
        }
        return words
    }
}

private final class RecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptWord], Error>?
    private var task: SFSpeechRecognitionTask?
    private var done = false

    func setContinuation(_ value: CheckedContinuation<[TranscriptWord], Error>) {
        lock.lock()
        if done { lock.unlock(); value.resume(throwing: CancellationError()); return }
        continuation = value
        lock.unlock()
    }

    func setTask(_ value: SFSpeechRecognitionTask) {
        lock.lock()
        if done { lock.unlock(); value.cancel(); return }
        task = value
        lock.unlock()
    }

    func finish(_ result: Result<[TranscriptWord], Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let pending = continuation
        continuation = nil
        task = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let pending = continuation
        continuation = nil
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
        pending?.resume(throwing: CancellationError())
    }
}
