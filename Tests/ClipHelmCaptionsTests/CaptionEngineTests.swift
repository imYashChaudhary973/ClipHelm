import Foundation
import ImageIO
import XCTest
import ClipHelmCore
import ClipHelmEditing
import ClipHelmCaptions

final class CaptionEngineTests: XCTestCase {
    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(microseconds: Int64((seconds * 1_000_000).rounded()))
    }

    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    private func words(_ entries: [(String, Double, Double)]) throws -> [TranscriptWord] {
        try entries.map { try TranscriptWord(text: $0.0, range: range($0.1, $0.2)) }
    }

    private func track(_ entries: [(String, Double, Double)], wordByWord: Bool = false,
                       blur: Bool = false) throws -> CaptionTrack {
        try CaptionTrack(cues: words(entries).map {
            try CaptionCue(sourceRange: $0.range, text: $0.text)
        }, wordByWord: wordByWord, blurIn: blur)
    }

    private func program(_ entries: [(String, Double, Double)],
                         style: CaptionStyle = .pop, wordByWord: Bool = false,
                         blur: Bool = false, format: OutputFormat = .vertical) throws -> CaptionProgram {
        try CaptionProgram(track: track(entries, wordByWord: wordByWord, blur: blur),
            style: style, segments: [EditSegment(sourceRange: range(0, 10))], format: format)
    }

    func testPunctuationGapAndEditBoundarySplitPhrases() throws {
        let speech = try program([("This", 0, 0.2), ("works.", 0.2, 0.4),
                                  ("Another", 0.5, 0.8), ("point", 1.4, 1.7)])
        XCTAssertEqual(speech.phrases.map { $0.words.map(\.text) },
                       [["This", "works."], ["Another"], ["point"]])
        let cut = try CaptionProgram(track: track([("before", 1, 1.2), ("after", 1.4, 1.6)]),
            style: .pop, segments: [EditSegment(sourceRange: range(0, 1.3)),
                                    EditSegment(sourceRange: range(1.3, 2))],
            format: .vertical)
        XCTAssertEqual(cut.phrases.count, 2)
        XCTAssertNil(cut.phrase(at: try time(2.5)))
    }

    func testFastSpeechAndLineLengthBoundPhrases() throws {
        let entries: [(String, Double, Double)] = [
            ("Caption", 0, 0.12), ("phrases", 0.13, 0.25), ("should", 0.26, 0.38),
            ("stay", 0.39, 0.51), ("short", 0.52, 0.64), ("when", 0.65, 0.77),
            ("speakers", 0.78, 0.90), ("talk", 0.91, 1.03), ("rapidly", 1.04, 1.16),
        ]
        let vertical = try program(entries)
        let horizontal = try program(entries, format: .horizontal)
        XCTAssertGreaterThan(vertical.phrases.count, 1)
        XCTAssertGreaterThanOrEqual(vertical.phrases.count, horizontal.phrases.count)
        XCTAssertTrue(vertical.phrases.allSatisfy { $0.words.count <= 6 })
    }

    func testWordTimingEmphasisFadeScaleAndBlur() throws {
        let captions = try program([("Watch", 1, 1.25), ("closely", 1.3, 1.65)],
                                   wordByWord: true, blur: true)
        let canvas = CGSize(width: 1080, height: 1920)
        let early = try XCTUnwrap(captions.frame(at: time(1.04), canvasSize: canvas))
        XCTAssertEqual(early.words.map(\.text), ["Watch"])
        XCTAssertTrue(early.words[0].emphasized)
        XCTAssertGreaterThan(early.words[0].scale, 1)
        XCTAssertGreaterThan(early.blurRadius, 0)
        XCTAssertLessThan(early.opacity, 1)
        XCTAssertNotNil(CaptionRenderer().render(early, canvasSize: canvas))
        let later = try XCTUnwrap(captions.frame(at: time(1.35), canvasSize: canvas))
        XCTAssertEqual(later.words.map(\.text), ["Watch", "closely"])
        XCTAssertEqual(early.words[0].rect, later.words[0].rect)
        XCTAssertFalse(later.words[0].emphasized)
        XCTAssertTrue(later.words[1].emphasized)
        XCTAssertEqual(later.blurRadius, 0)
        XCTAssertNil(captions.frame(at: try time(0.5), canvasSize: canvas))
    }

    func testAllStylesRenderInsideSafeZonesAtBothFormats() throws {
        let styles: [CaptionStyle] = [.pop, .spotlight, .impact, .glowBox,
                                      .editorial, .highPunch, .neonHeadline, .paper]
        let renderer = CaptionRenderer()
        for format in [OutputFormat.vertical, .horizontal] {
            let size = CGSize(width: format.width, height: format.height)
            for style in styles {
                let captions = try program([("Important", 1, 1.3), ("words", 1.35, 1.7)],
                                           style: style, format: format)
                let frame = try XCTUnwrap(captions.frame(at: time(1.4), canvasSize: size))
                XCTAssertTrue(frame.words.allSatisfy { frame.safeRect.contains($0.rect) }, "\(style)")
                let image = try XCTUnwrap(renderer.render(frame, canvasSize: size))
                XCTAssertEqual(image.width, format.width)
                XCTAssertEqual(image.height, format.height)
                XCTAssertTrue(frame.words.contains(where: \.emphasized))
            }
        }
        if let path = ProcessInfo.processInfo.environment["CLIPHELM_CAPTION_STYLE_SHEET"] {
            let cell = CGSize(width: 270, height: 480)
            let context = try XCTUnwrap(CGContext(data: nil, width: 1080, height: 960,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.08, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 960))
            for (index, style) in styles.enumerated() {
                let captions = try program([("Important", 1, 1.3), ("words", 1.35, 1.7)], style: style)
                let frame = try XCTUnwrap(captions.frame(at: time(1.4), canvasSize: cell))
                let image = try XCTUnwrap(renderer.render(frame, canvasSize: cell))
                context.draw(image, in: CGRect(x: (index % 4) * 270,
                    y: (1 - index / 4) * 480, width: 270, height: 480))
            }
            let sheet = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, sheet, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }

    func testPreviewAndOutputUseProportionalLayoutAndSameRenderer() throws {
        let captions = try program([("Same", 1, 1.3), ("layout", 1.35, 1.7)],
                                   style: .glowBox, blur: true)
        let small = CGSize(width: 270, height: 480)
        let large = CGSize(width: 1080, height: 1920)
        let preview = try XCTUnwrap(captions.frame(at: time(1.4), canvasSize: small))
        let output = try XCTUnwrap(captions.frame(at: time(1.4), canvasSize: large))
        XCTAssertEqual(preview.words.count, output.words.count)
        for (left, right) in zip(preview.words, output.words) {
            XCTAssertEqual(left.rect.midX / small.width, right.rect.midX / large.width, accuracy: 0.01)
            XCTAssertEqual(left.rect.midY / small.height, right.rect.midY / large.height, accuracy: 0.01)
        }
        let renderer = CaptionRenderer()
        XCTAssertNotNil(renderer.render(preview, canvasSize: small))
        let final = try XCTUnwrap(renderer.render(output, canvasSize: large))
        if let path = ProcessInfo.processInfo.environment["CLIPHELM_CAPTION_QA_OUTPUT"] {
            let url = URL(fileURLWithPath: path)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, final, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }

    func testSilentTranscriptDisablesCaptionsAndCutWordsStayOut() throws {
        let assetID = AssetID()
        let empty = try Transcript(assetID: assetID, words: [])
        let config = try ClipConfiguration(outputFormat: .vertical, framingMode: .smartAuto,
            pacingMode: .balanced, selectedLengths: [], requestedClipCount: nil,
            soundMode: .source, captionStyle: .pop,
            smartEdit: SmartEditOptions(useVisionForTrickyShots: false, cutDeadAir: false,
                trimLongPauses: false, cleanFillers: false, keepDemos: false))
        let segments = [EditSegment(sourceRange: try range(0, 2)),
                        EditSegment(sourceRange: try range(4, 6))]
        XCTAssertNil(try CaptionTrackBuilder().build(transcript: empty,
            segments: segments, configuration: config))
        let transcript = try Transcript(assetID: assetID, words: words([
            ("first", 0.5, 0.8), ("removed", 2.4, 2.7), ("last", 4.5, 4.8)]))
        let built = try XCTUnwrap(CaptionTrackBuilder().build(transcript: transcript,
            segments: segments, configuration: config))
        XCTAssertEqual(built.cues.map(\.text), ["first", "last"])
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: assetID,
            segments: segments, outputFormat: .vertical, framingMode: .smartAuto,
            pacingMode: .balanced, soundMode: .source, captionStyle: .pop,
            captionTrack: built)
        let program = try CaptionProgram(spec: spec)
        let timeline = try EditTimeline(spec: spec)
        let sourceTime = try timeline.sourceTime(forEdited: time(2.5))
        XCTAssertEqual(program.phrase(at: sourceTime)?.words.map(\.text), ["last"])
        XCTAssertNil(try CaptionProgram(track: nil, style: nil,
            segments: segments, format: .vertical).frame(at: time(0.6),
                                                        canvasSize: CGSize(width: 270, height: 480)))
    }
}
