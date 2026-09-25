import AppKit
import SwiftUI

/// Shared visual tokens and small building blocks. Views use these instead of
/// ad hoc spacing, radii, colors, and status text. See docs/DESIGN_SYSTEM.md.
enum DS {
    /// 4 pt spacing scale.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    /// Readable content widths for the detail column.
    enum Width {
        static let form: CGFloat = 720
        static let content: CGFloat = 1080
    }

    enum Motion {
        static let quick = Animation.snappy(duration: 0.18)
        static let standard = Animation.smooth(duration: 0.25)
    }

    /// Brand accent, taken from the logo's blue. Light #1E66D8 and dark #2F6FE4
    /// both carry white labels at 4.5:1 or better, so prominent buttons stay
    /// legible in either appearance.
    static let accent = Color(nsColor: NSColor(name: "ClipHelmAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.184, green: 0.435, blue: 0.894, alpha: 1)
            : NSColor(srgbRed: 0.118, green: 0.400, blue: 0.847, alpha: 1)
    })

    /// The logo's teal-to-blue sweep. Reserved for brand moments, never for text.
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.498, green: 0.929, blue: 0.831),
                 Color(red: 0.196, green: 0.435, blue: 0.902)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.1)
    static let videoBackground = Color.black
}

// MARK: - Surfaces

private struct SurfaceCard: ViewModifier {
    var padding: CGFloat
    var highlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(highlighted ? DS.accent.opacity(0.55) : DS.hairline,
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

extension View {
    /// A grouped surface for one task or topic.
    func surfaceCard(padding: CGFloat = DS.Space.md, highlighted: Bool = false) -> some View {
        modifier(SurfaceCard(padding: padding, highlighted: highlighted))
    }

    /// Centers content in the detail column with a readable maximum width.
    func readableColumn(_ width: CGFloat = DS.Width.content,
                        padding: CGFloat = DS.Space.xl) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Layout

/// Grid whose cells all share one width and one height: the tallest cell's.
/// Columns never outnumber the cells, so a short set of options fills the row.
struct UniformGrid: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat = DS.Space.sm

    private func metrics(width: CGFloat, subviews: Subviews) -> (columns: Int, cell: CGSize) {
        guard !subviews.isEmpty else { return (1, .zero) }
        let fitting = Int((width + spacing) / (minimumWidth + spacing))
        let columns = max(1, min(subviews.count, fitting))
        let cellWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let cellHeight = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
        }.max() ?? 0
        return (columns, CGSize(width: cellWidth, height: cellHeight))
    }

    private func resolvedWidth(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        return minimumWidth * CGFloat(count) + spacing * CGFloat(max(0, count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal, count: subviews.count)
        let (columns, cell) = metrics(width: width, subviews: subviews)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width,
                      height: CGFloat(rows) * cell.height + spacing * CGFloat(max(0, rows - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let (columns, cell) = metrics(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index % columns) * (cell.width + spacing)
            let y = bounds.minY + CGFloat(index / columns) * (cell.height + spacing)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(cell))
        }
    }
}

// MARK: - Brand

/// The app icon as it ships in the bundle, so in-app branding always matches the Dock.
/// Unbundled runs (tests, `swift run`) have only a generic icon, so nothing is drawn.
struct AppLogo: View {
    var size: CGFloat = 64

    private static let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil

    var body: some View {
        if Self.bundled {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityLabel("ClipHelm")
        }
    }
}

// MARK: - Text

/// Small uppercase label above a title.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
}

/// Page title block used at the top of each detail route.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(eyebrow: String? = nil, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let eyebrow { Eyebrow(eyebrow) }
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

// MARK: - Status

enum StatusTone {
    case neutral, info, success, warning, error

    var symbol: String {
        switch self {
        case .neutral: "circle.dashed"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Icon plus text so meaning never depends on color alone.
struct StatusMessage: View {
    let text: String
    var tone: StatusTone = .info

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(tone == .error ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: tone.symbol).foregroundStyle(tone.color)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Compact capsule that names the state of a stage.
struct StatusBadge: View {
    let text: String
    var tone: StatusTone = .neutral

    var body: some View {
        Label(text, systemImage: tone.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Status: \(text)")
    }
}

/// The one progress presentation for any long task: bar, stage text, cancel.
struct TaskProgressRow: View {
    let label: String
    var fraction: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .frame(maxWidth: 240)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let fraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let onCancel {
                Button("Cancel", action: onCancel)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Choice cards

/// Selectable card for a small set of mutually exclusive choices.
struct OptionCard: View {
    let title: String
    var detail: String?
    var systemImage: String?
    let isSelected: Bool
    /// Checkbox indicator for multi-select groups; radio indicator otherwise.
    var multiple = false
    let action: () -> Void

    @State private var hovering = false

    private var indicator: String {
        switch (multiple, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(isSelected ? DS.accent : Color.secondary)
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: indicator)
                    .font(.title3)
                    .foregroundStyle(isSelected ? DS.accent : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(DS.Space.md)
            // Fill the cell a UniformGrid proposes so every card in a group matches.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(isSelected ? DS.accent.opacity(0.08)
                          : hovering ? Color.primary.opacity(0.04) : DS.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .strokeBorder(isSelected ? DS.accent : DS.hairline, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A grid of option cards bound to one selection.
struct OptionCardGrid<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var minimumWidth: CGFloat = 220
    let title: (Value) -> String
    var detail: (Value) -> String? = { _ in nil }
    var systemImage: (Value) -> String? = { _ in nil }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        UniformGrid(minimumWidth: minimumWidth) {
            ForEach(options, id: \.self) { option in
                OptionCard(title: title(option), detail: detail(option),
                           systemImage: systemImage(option),
                           isSelected: option == selection) {
                    withAnimation(reduceMotion ? nil : DS.Motion.quick) { selection = option }
                }
            }
        }
    }
}

/// Checkbox row with a supporting description, for independent on/off options.
struct ToggleRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Fill the row so the switch sits at the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, DS.Space.xxs)
    }
}

// MARK: - Workspace stages

/// Card for one stage of the workspace pipeline: icon, title, status, actions, body.
struct StageCard<Actions: View, Content: View>: View {
    var eyebrow: String?
    let title: String
    let systemImage: String
    let status: (text: String, tone: StatusTone)
    var highlighted = false
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                ZStack {
                    Circle().fill(highlighted ? DS.accent : Color.secondary.opacity(0.15))
                    Image(systemName: systemImage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(highlighted ? Color.white : Color.secondary)
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let eyebrow {
                        Text(eyebrow).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(title).font(.title3.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                StatusBadge(text: status.text, tone: status.tone)
                Spacer(minLength: DS.Space.xs)
                actions
            }
            content
        }
        .surfaceCard(padding: DS.Space.md, highlighted: highlighted)
    }
}
