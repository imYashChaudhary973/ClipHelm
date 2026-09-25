import Foundation
import XCTest
import ClipHelmCore
import ClipHelmMedia
import ClipHelmOpenRouter
@testable import ClipHelmTranscription

private actor RecordingBackend: TranscriptionBackend {
    nonisolated let maximumChunkSeconds: Int
    private(set) var calls = 0
    private let invalid: Bool

    init(chunkSeconds: Int = 1, invalid: Bool = false) {
        maximumChunkSeconds = chunkSeconds
        self.invalid = invalid
    }

    func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        calls += 1
        let start = try MediaTime(microseconds: invalid ? 1_100_000 : 100_000)
        let end = try MediaTime(microseconds: invalid ? 1_200_000 : 300_000)
        return [try TranscriptWord(text: "Hello", range: MediaTimeRange(start: start, end: end),
                                   confidence: 0.9, speakerID: "speaker 1")]
    }
}

private struct CancellingBackend: TranscriptionBackend {
    let maximumChunkSeconds = 3
    func transcribe(audioURL: URL) async throws -> [TranscriptWord] {
        withUnsafeCurrentTask { $0?.cancel() }
        return [try TranscriptWord(text: "Late", range: MediaTimeRange(
            start: MediaTime(microseconds: 100_000), end: MediaTime(microseconds: 300_000)))]
    }
}

final class TranscriptEngineTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4"))
    }

    func testAppleSpeechTreatsOnlyNoSpeechErrorAsEmptyChunk() {
        XCTAssertTrue(AppleSpeechBackend.isNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        XCTAssertFalse(AppleSpeechBackend.isNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1700)))
        XCTAssertFalse(AppleSpeechBackend.isNoSpeech(NSError(domain: NSCocoaErrorDomain, code: 1110)))
    }

    func testAppleSpeechBoundsSmallChunkOverrun() throws {
        let bounded = try AppleSpeechBackend.boundedRange(
            start: 49_800_000, end: 50_160_000, maximumTime: 50_000_000)
        XCTAssertEqual(bounded?.end.microseconds, 50_000_000)
        XCTAssertNil(try AppleSpeechBackend.boundedRange(
            start: 50_050_000, end: 50_160_000, maximumTime: 50_000_000))
        XCTAssertThrowsError(try AppleSpeechBackend.boundedRange(
            start: 49_800_000, end: 51_000_000, maximumTime: 50_000_000))
    }

    @MainActor
    func testOptInRealOnDeviceSpeechProfile() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPHELM_QA_SPEECH_SOURCE"] else {
            throw XCTSkip("Set CLIPHELM_QA_SPEECH_SOURCE to an authorized speech MP4")
        }
        let source = URL(fileURLWithPath: path)
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "QA speech").asset
        let started = Date()
        let transcript = try await TranscriptEngine().transcribe(
            sourceURL: source, asset: asset, backend: AppleSpeechBackend())
        print("QA_ON_DEVICE_TRANSCRIPTION_SECONDS=\(Date().timeIntervalSince(started))")
        print("QA_TRANSCRIPT_WORDS=\(transcript.words.count)")
        XCTAssertTrue(transcript.hasMeaningfulSpeech)
    }

    func testSilentSourcesSkipBackend() async throws {
        for name in ["valid", "silent-audio"] {
            let source = try fixture(name)
            let asset = try await MediaProbe().probe(fileURL: source, displayName: name).asset
            let backend = RecordingBackend()
            let transcript = try await TranscriptEngine().transcribe(
                sourceURL: source, asset: asset, backend: backend)
            XCTAssertTrue(transcript.segments.isEmpty)
            XCTAssertFalse(transcript.hasMeaningfulSpeech)
            let calls = await backend.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testChunkTimesMapToSourceAndKeepSpeakerMetadata() async throws {
        let source = try fixture("tone3")
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Tone").asset
        let backend = RecordingBackend()
        let transcript = try await TranscriptEngine().transcribe(
            sourceURL: source, asset: asset, backend: backend)
        let calls = await backend.calls
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(transcript.words.map { $0.range.start.microseconds },
                       [100_000, 1_100_000, 2_100_000])
        XCTAssertEqual(transcript.segments.count, 3)
        XCTAssertEqual(transcript.segments[0].speakerID, "speaker 1")
        XCTAssertEqual(transcript.words[0].confidence, 0.9)
    }

    func testInvalidBackendTimingsAreRejected() async throws {
        let source = try fixture("tone3")
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Tone").asset
        do {
            _ = try await TranscriptEngine().transcribe(
                sourceURL: source, asset: asset, backend: RecordingBackend(invalid: true))
            XCTFail("Backend time outside its chunk must be rejected")
        } catch let error as TranscriptEngineError {
            XCTAssertEqual(error, .invalidWordTimings)
        }
    }

    func testCancellationAfterBackendReturnsDoesNotCommitTranscript() async throws {
        let source = try fixture("tone3")
        let asset = try await MediaProbe().probe(fileURL: source, displayName: "Tone").asset
        let job = Task {
            try await TranscriptEngine().transcribe(
                sourceURL: source, asset: asset, backend: CancellingBackend())
        }
        do {
            _ = try await job.value
            XCTFail("Cancelled transcription must not return a complete transcript")
        } catch is CancellationError { }
    }

    func testOpenRouterWordResponseRequiresTimings() async throws {
        let catalog = Data(#"{"data":[{"id":"vendor/speech","name":"Speech","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}}]}"#.utf8)
        let gateway = MockOpenRouterGateway(catalogs: [.all: Data(#"{"data":[]}"#.utf8),
                                                       .transcription: catalog])
        let registry = OpenRouterModelRegistry(gateway: gateway,
            defaultsSuiteName: "ClipHelm-Transcript-\(UUID().uuidString)")
        _ = try await registry.refresh()
        let models = await registry.models(supporting: [.transcription])
        let model = try XCTUnwrap(models.first)
        let backend = try OpenRouterTranscriptionBackend(gateway: gateway, model: model)
        let audio = FileManager.default.temporaryDirectory
            .appending(path: "ClipHelm-Transcript-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data([1, 2, 3]).write(to: audio)
        await gateway.setTranscriptionResponse(Data(#"{"text":"Hello","words":[{"word":"Hello","start":0.1,"end":0.4,"confidence":0.8,"speaker_id":"A"}]}"#.utf8))
        let words = try await backend.transcribe(audioURL: audio)
        XCTAssertEqual(words.map(\.text), ["Hello"])
        XCTAssertEqual(words[0].speakerID, "A")
        XCTAssertEqual(words[0].range.start.microseconds, 100_000)
        await gateway.setTranscriptionResponse(Data(#"{"text":"Hello"}"#.utf8))
        do {
            _ = try await backend.transcribe(audioURL: audio)
            XCTFail("Untimed text must not be used for click-to-seek")
        } catch let error as TranscriptEngineError {
            XCTAssertEqual(error, .invalidWordTimings)
        }
        await gateway.setTranscriptionResponse(Data(#"{"text":"Hello","words":[]}"#.utf8))
        do {
            _ = try await backend.transcribe(audioURL: audio)
            XCTFail("Text with no word timings must not become a silent transcript")
        } catch let error as TranscriptEngineError {
            XCTAssertEqual(error, .invalidWordTimings)
        }
    }
}
