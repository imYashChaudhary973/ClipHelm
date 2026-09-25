import Foundation
import CoreGraphics
import CoreText
import CoreImage
import CoreImage.CIFilterBuiltins
import ClipHelmCore

public struct CaptionWordLayout {
    public let text: String
    public let rect: CGRect
    public let emphasized: Bool
    public let scale: CGFloat
}

public struct CaptionFrame {
    public let words: [CaptionWordLayout]
    public let safeRect: CGRect
    public let backgroundRect: CGRect?
    public let opacity: CGFloat
    public let blurRadius: CGFloat
    public let fontSize: CGFloat
    public let style: CaptionStyle
}

private struct StylePreset {
    let fontName: String
    let text: CGColor
    let emphasis: CGColor
    let background: CGColor?
    let outline: CGColor?
    let uppercase: Bool
    let verticalY: CGFloat
    let horizontalY: CGFloat
    let cornerRadius: CGFloat

    init(_ style: CaptionStyle) {
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(red: r, green: g, blue: b, alpha: a)
        }
        switch style {
        case .pop:
            self.init(fontName: "HelveticaNeue-Bold", text: color(1, 1, 1),
                emphasis: color(1, 0.85, 0.25), background: nil, outline: color(0.04, 0.05, 0.08),
                uppercase: false, verticalY: 0.18, horizontalY: 0.12, cornerRadius: 0)
        case .spotlight:
            self.init(fontName: "HelveticaNeue-Medium", text: color(1, 1, 1),
                emphasis: color(1, 0.78, 0.32), background: color(0.05, 0.06, 0.09, 0.82),
                outline: nil, uppercase: false, verticalY: 0.20, horizontalY: 0.13, cornerRadius: 0.36)
        case .impact:
            self.init(fontName: "Impact", text: color(1, 1, 1),
                emphasis: color(1, 0.32, 0.18), background: nil, outline: color(0.03, 0.03, 0.03),
                uppercase: true, verticalY: 0.17, horizontalY: 0.11, cornerRadius: 0)
        case .glowBox:
            self.init(fontName: "HelveticaNeue-Bold", text: color(0.95, 1, 1),
                emphasis: color(0.36, 0.92, 1), background: color(0.02, 0.12, 0.18, 0.82),
                outline: nil, uppercase: false, verticalY: 0.19, horizontalY: 0.12, cornerRadius: 0.22)
        case .editorial:
            self.init(fontName: "Georgia-Bold", text: color(0.97, 0.96, 0.91),
                emphasis: color(1, 0.83, 0.54), background: color(0.08, 0.08, 0.09, 0.66),
                outline: nil, uppercase: false, verticalY: 0.22, horizontalY: 0.14, cornerRadius: 0.08)
        case .highPunch:
            self.init(fontName: "HelveticaNeue-CondensedBlack", text: color(1, 1, 1),
                emphasis: color(1, 0.42, 0.17), background: nil, outline: color(0, 0, 0),
                uppercase: true, verticalY: 0.17, horizontalY: 0.10, cornerRadius: 0)
        case .neonHeadline:
            self.init(fontName: "HelveticaNeue-Bold", text: color(0.97, 0.95, 1),
                emphasis: color(0.98, 0.35, 0.89), background: color(0.08, 0.03, 0.14, 0.86),
                outline: nil, uppercase: true, verticalY: 0.19, horizontalY: 0.12, cornerRadius: 0.18)
        case .paper:
            self.init(fontName: "Georgia-Bold", text: color(0.13, 0.12, 0.10),
                emphasis: color(0.72, 0.22, 0.12), background: color(0.97, 0.94, 0.84, 0.94),
                outline: nil, uppercase: false, verticalY: 0.21, horizontalY: 0.13, cornerRadius: 0.05)
        }
    }

    private init(fontName: String, text: CGColor, emphasis: CGColor, background: CGColor?,
                 outline: CGColor?, uppercase: Bool, verticalY: CGFloat,
                 horizontalY: CGFloat, cornerRadius: CGFloat) {
        self.fontName = fontName
        self.text = text
        self.emphasis = emphasis
        self.background = background
        self.outline = outline
        self.uppercase = uppercase
        self.verticalY = verticalY
        self.horizontalY = horizontalY
        self.cornerRadius = cornerRadius
    }
}

public extension CaptionProgram {
    func frame(at sourceTime: MediaTime, canvasSize: CGSize) -> CaptionFrame? {
        guard let style, canvasSize.width.isFinite, canvasSize.height.isFinite,
              (64...16_384).contains(canvasSize.width),
              (64...16_384).contains(canvasSize.height),
              let active = activePhrase(at: sourceTime) else { return nil }
        let phrase = active.phrase
        let preset = StylePreset(style)
        let vertical = canvasSize.height > canvasSize.width
        let safeRect = CGRect(x: canvasSize.width * 0.08, y: canvasSize.height * 0.08,
            width: canvasSize.width * 0.84, height: canvasSize.height * 0.84)
        let lastStarted = phrase.words.lastIndex { $0.sourceRange.start <= sourceTime }
        let activeIndex = lastStarted.flatMap { index in
            sourceTime < phrase.words[index].sourceRange.end ? index : nil
        }
        let text = phrase.words.map { word -> String in
            let shortened = word.text.count > 32 ? String(word.text.prefix(31)) + "…" : word.text
            return preset.uppercase ? shortened.uppercased() : shortened
        }
        let maxWidth = safeRect.width
        var fontSize = max(12, min(canvasSize.height * (vertical ? 0.047 : 0.060),
                                   canvasSize.width * (vertical ? 0.085 : 0.044)))
        var lines: [[(Int, CGFloat)]] = []
        for _ in 0..<12 {
            let font = CTFontCreateWithName(preset.fontName as CFString, fontSize, nil)
            let gap = fontSize * 0.24
            var candidate: [[(Int, CGFloat)]] = [[]]
            var used: CGFloat = 0
            for (index, token) in text.enumerated() {
                let width = min(maxWidth, Self.measure(token, font: font))
                if !candidate[candidate.count - 1].isEmpty && used + gap + width > maxWidth {
                    candidate.append([])
                    used = 0
                }
                candidate[candidate.count - 1].append((index, width))
                used += (used == 0 ? 0 : gap) + width
            }
            lines = candidate
            if lines.count <= 2 || fontSize <= max(10, canvasSize.height * 0.02) { break }
            fontSize *= 0.88
        }
        guard lines.count <= 2 else { return nil }
        let lineHeight = fontSize * 1.25
        let gap = fontSize * 0.24
        let desiredBottom = canvasSize.height * (vertical ? preset.verticalY : preset.horizontalY)
        let bottom = min(max(desiredBottom, safeRect.minY), safeRect.maxY - CGFloat(lines.count) * lineHeight)
        var placed: [CaptionWordLayout] = []
        var allRects: [CGRect] = []
        for (lineIndex, line) in lines.enumerated() {
            let width = line.reduce(CGFloat(0)) { $0 + $1.1 } + CGFloat(max(0, line.count - 1)) * gap
            var x = (canvasSize.width - width) / 2
            let y = bottom + CGFloat(lines.count - 1 - lineIndex) * lineHeight
            for (index, wordWidth) in line {
                let cue = phrase.words[index]
                let rect = CGRect(x: x, y: y, width: wordWidth, height: lineHeight)
                allRects.append(rect)
                let emphasized = index == activeIndex
                let elapsed = max(0, sourceTime.microseconds - cue.sourceRange.start.microseconds)
                let scale = emphasized ? 1 + 0.06 * (1 - min(1, CGFloat(elapsed) / 160_000)) : 1
                if !wordByWord || cue.sourceRange.start <= sourceTime {
                    placed.append(CaptionWordLayout(text: text[index], rect: rect,
                        emphasized: emphasized, scale: scale))
                }
                x += wordWidth + gap
            }
        }
        let first = phrase.range.start.microseconds
        let visibleEnd = active.visibleEnd
        let fadeIn = min(1, CGFloat(sourceTime.microseconds - first) / 140_000)
        let fadeOut = min(1, CGFloat(visibleEnd - sourceTime.microseconds) / 180_000)
        let opacity = max(0, min(fadeIn, fadeOut))
        let blur = blurIn ? max(0, 1 - CGFloat(sourceTime.microseconds - first) / 180_000) *
            min(12, fontSize * 0.16) : 0
        let background: CGRect? = preset.background.map { _ in
            let union = allRects.reduce(CGRect.null) { $0.union($1) }
            return union.insetBy(dx: -fontSize * 0.32, dy: -fontSize * 0.18).intersection(safeRect)
        }
        return CaptionFrame(words: placed, safeRect: safeRect, backgroundRect: background,
            opacity: opacity, blurRadius: blur, fontSize: fontSize, style: style)
    }

    private static func measure(_ text: String, font: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// Produces a transparent overlay image for both live preview and final-frame composition.
public final class CaptionRenderer {
    private let imageContext = CIContext()

    public init() { }

    public func render(_ frame: CaptionFrame, canvasSize: CGSize) -> CGImage? {
        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        guard (64...16_384).contains(width), (64...16_384).contains(height),
              let context = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAlpha(frame.opacity)
        context.clip(to: frame.safeRect)
        let preset = StylePreset(frame.style)
        if let background = frame.backgroundRect, let color = preset.background {
            context.setFillColor(color)
            let radius = min(background.height * preset.cornerRadius, background.width / 2)
            context.addPath(CGPath(roundedRect: background, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let font = CTFontCreateWithName(preset.fontName as CFString, frame.fontSize, nil)
        for word in frame.words {
            context.saveGState()
            let mid = CGPoint(x: word.rect.midX, y: word.rect.midY)
            context.translateBy(x: mid.x, y: mid.y)
            context.scaleBy(x: word.scale, y: word.scale)
            context.translateBy(x: -mid.x, y: -mid.y)
            let baseline = word.rect.minY + (word.rect.height - frame.fontSize) / 2 + frame.fontSize * 0.18
            context.textPosition = CGPoint(x: word.rect.minX, y: baseline)
            let fontKey = NSAttributedString.Key(rawValue: kCTFontAttributeName as String)
            let colorKey = NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text,
                attributes: [fontKey: font, colorKey: word.emphasized ? preset.emphasis : preset.text]))
            if let outline = preset.outline {
                let stroke = CTLineCreateWithAttributedString(NSAttributedString(string: word.text,
                    attributes: [fontKey: font, colorKey: outline,
                        NSAttributedString.Key(rawValue: kCTStrokeColorAttributeName as String): outline,
                        NSAttributedString.Key(rawValue: kCTStrokeWidthAttributeName as String): 9]))
                CTLineDraw(stroke, context)
                context.textPosition = CGPoint(x: word.rect.minX, y: baseline)
            }
            CTLineDraw(line, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        guard frame.blurRadius > 0 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = CIImage(cgImage: image)
        filter.radius = Float(frame.blurRadius)
        guard let blurred = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0,
            width: width, height: height)) else { return image }
        return imageContext.createCGImage(blurred, from: blurred.extent) ?? image
    }
}
