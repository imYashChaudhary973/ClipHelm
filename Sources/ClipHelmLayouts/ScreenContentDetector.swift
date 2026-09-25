import Foundation
import ImageIO
import Vision
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmMedia

/// Samples likely screen segments and recognizes visible text entirely on device.
public struct ScreenContentDetector: Sendable {
    public init() { }

    public func detect(sourceURL: URL, asset: MediaAsset, analysis: AnalysisResult,
                       range: MediaTimeRange,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [ScreenContentHint] {
        guard sourceURL.isFileURL, range.end <= asset.duration else {
            throw ModelError.invalid("ScreenContentDetector inputs")
        }
        try analysis.validate(for: asset)
        let windows = analysis.classifications.compactMap { label -> MediaTimeRange? in
            let screenKind = [.screenShare, .presentation, .demo].contains(label.kind)
            let screenSignal = analysis.signals.contains { $0.kind == .screenContent &&
                $0.range.start < label.range.end && label.range.start < $0.range.end &&
                $0.strength * $0.confidence >= 0.25 }
            guard screenKind || screenSignal else { return nil }
            let start = max(range.start, label.range.start)
            let end = min(range.end, label.range.end)
            return start < end ? try? MediaTimeRange(start: start, end: end) : nil
        }
        guard !windows.isEmpty else { return [] }
        let job = Task.detached(priority: .utility) { () throws -> [ScreenContentHint] in
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "ClipHelm-screen-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            var hints: [ScreenContentHint] = []
            let step = max(1, (windows.count + 11) / 12)
            let selected = windows.enumerated().filter { $0.offset.isMultiple(of: step) }.map(\.element)
            for (index, span) in selected.enumerated() {
                defer { progress(Double(index + 1) / Double(selected.count)) }
                try Task.checkCancellation()
                let midpoint = try MediaTime(microseconds: span.start.microseconds + span.durationMicroseconds / 2)
                do {
                    let thumbnail = try await ThumbnailEngine().generate(fileURL: sourceURL,
                        at: [midpoint], outputDirectory: directory, maximumDimension: 720)[0]
                    guard let source = CGImageSourceCreateWithURL(thumbnail.fileURL as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    let averageHeight = (request.results ?? []).map(\.boundingBox.height)
                        .reduce(0, +) / Double(max(1, request.results?.count ?? 0))
                    let (kind, confidence) = Self.classify(textLines: lines, averageHeight: averageHeight)
                    hints.append(try ScreenContentHint(range: span, kind: kind, confidence: confidence))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    hints.append(try ScreenContentHint(range: span, kind: .unknown, confidence: 0.1))
                }
            }
            return hints
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    static func classify(textLines: [String], averageHeight: Double) -> (ScreenContentKind, Double) {
        let lines = textLines.map { $0.lowercased() }
        let code = lines.filter { line in
            ["func ", "import ", "def ", "class ", "const ", "let ", "#include", "=>", "</", "{", "};"]
                .contains(where: line.contains)
        }.count
        if code >= 2 { return (.ideCode, min(0.88, 0.62 + Double(code) * 0.05)) }
        if lines.contains(where: { line in
            ["https://", "http://", "www.", "localhost", ".com", ".app"].contains(where: line.contains)
        }) { return (.browserDemo, 0.75) }
        if lines.count >= 2 && lines.count <= 8 && averageHeight >= 0.055 {
            return (.slides, 0.72)
        }
        let uiWords = ["file", "edit", "view", "window", "settings", "save", "cancel", "search", "preferences"]
        let uiCount = uiWords.filter { word in lines.contains(where: { $0 == word || $0.hasPrefix(word + " ") }) }.count
        if uiCount >= 2 { return (.softwareUI, min(0.84, 0.6 + Double(uiCount) * 0.06)) }
        return (.screenShare, lines.isEmpty ? 0.30 : 0.45)
    }
}
