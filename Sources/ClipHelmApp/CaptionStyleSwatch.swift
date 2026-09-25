import SwiftUI
import ClipHelmCore

/// A static sample of a caption style for pickers. Fonts and colors mirror the
/// renderer's presets in ClipHelmCaptions/CaptionRenderer.swift; keep them in sync.
struct CaptionStyleSwatch: View {
    let style: CaptionStyle

    private struct Look {
        var font: String
        var text: Color
        var emphasis: Color
        var background: Color?
        var outlined: Bool
        var uppercase: Bool
        var cornerRadius: CGFloat
    }

    private var look: Look {
        switch style {
        case .pop:
            Look(font: "HelveticaNeue-Bold", text: .white, emphasis: Color(red: 1, green: 0.85, blue: 0.25),
                 background: nil, outlined: true, uppercase: false, cornerRadius: 0)
        case .spotlight:
            Look(font: "HelveticaNeue-Medium", text: .white, emphasis: Color(red: 1, green: 0.78, blue: 0.32),
                 background: Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.82),
                 outlined: false, uppercase: false, cornerRadius: 10)
        case .impact:
            Look(font: "Impact", text: .white, emphasis: Color(red: 1, green: 0.32, blue: 0.18),
                 background: nil, outlined: true, uppercase: true, cornerRadius: 0)
        case .glowBox:
            Look(font: "HelveticaNeue-Bold", text: Color(red: 0.95, green: 1, blue: 1),
                 emphasis: Color(red: 0.36, green: 0.92, blue: 1),
                 background: Color(red: 0.02, green: 0.12, blue: 0.18).opacity(0.82),
                 outlined: false, uppercase: false, cornerRadius: 7)
        case .editorial:
            Look(font: "Georgia-Bold", text: Color(red: 0.97, green: 0.96, blue: 0.91),
                 emphasis: Color(red: 1, green: 0.83, blue: 0.54),
                 background: Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.66),
                 outlined: false, uppercase: false, cornerRadius: 3)
        case .highPunch:
            Look(font: "HelveticaNeue-CondensedBlack", text: .white,
                 emphasis: Color(red: 1, green: 0.42, blue: 0.17),
                 background: nil, outlined: true, uppercase: true, cornerRadius: 0)
        case .neonHeadline:
            Look(font: "HelveticaNeue-Bold", text: Color(red: 0.97, green: 0.95, blue: 1),
                 emphasis: Color(red: 0.98, green: 0.35, blue: 0.89),
                 background: Color(red: 0.08, green: 0.03, blue: 0.14).opacity(0.86),
                 outlined: false, uppercase: true, cornerRadius: 6)
        case .paper:
            Look(font: "Georgia-Bold", text: Color(red: 0.13, green: 0.12, blue: 0.10),
                 emphasis: Color(red: 0.72, green: 0.22, blue: 0.12),
                 background: Color(red: 0.97, green: 0.94, blue: 0.84).opacity(0.94),
                 outlined: false, uppercase: false, cornerRadius: 2)
        }
    }

    /// "The best part" with the middle word in the style's emphasis color.
    private func sample(_ look: Look) -> AttributedString {
        let words = look.uppercase ? ["THE", "BEST", "PART"] : ["The", "best", "part"]
        var sample = AttributedString(words[0] + " ")
        sample.foregroundColor = look.text
        var emphasis = AttributedString(words[1])
        emphasis.foregroundColor = look.emphasis
        var tail = AttributedString(" " + words[2])
        tail.foregroundColor = look.text
        sample.append(emphasis)
        sample.append(tail)
        return sample
    }

    var body: some View {
        let look = look
        let line = Text(sample(look)).font(.custom(look.font, size: 17))

        ZStack {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            line
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .shadow(color: look.outlined ? .black.opacity(0.9) : .clear, radius: 0, x: 1, y: 1)
                .shadow(color: look.outlined ? .black.opacity(0.9) : .clear, radius: 0, x: -1, y: -1)
                .padding(.horizontal, look.background == nil ? 0 : 10)
                .padding(.vertical, look.background == nil ? 0 : 5)
                .background {
                    if let background = look.background {
                        RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
                            .fill(background)
                    }
                }
                .padding(.horizontal, DS.Space.xs)
        }
        .accessibilityHidden(true)
    }
}

/// Selectable caption style tile: sample on top, name below.
struct CaptionStyleCard: View {
    let style: CaptionStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                CaptionStyleSwatch(style: style)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                HStack {
                    Text(style.label).font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DS.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DS.Space.xs)
            .background(isSelected ? DS.accent.opacity(0.08) : DS.surface,
                        in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .strokeBorder(isSelected ? DS.accent : DS.hairline, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.label) caption style")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension CaptionStyle {
    static let pickerOrder: [CaptionStyle] = [
        .pop, .spotlight, .impact, .glowBox, .editorial, .highPunch, .neonHeadline, .paper,
    ]
}

extension PacingMode {
    var detail: String {
        switch self {
        case .natural: "Keep the speaker's rhythm; only long pauses are shortened."
        case .balanced: "Trim noticeable pauses while keeping a relaxed feel."
        case .tight: "Remove most pauses for a focused, steady pace."
        case .fast: "Cut aggressively for a quick, high-energy rhythm."
        }
    }
}
