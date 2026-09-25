import SwiftUI
import ClipHelmCore

/// The workspace's primary surface: a Start button, then each phase of the run as it happens.
struct ClipJobCard: View {
    @ObservedObject var job: ClipJob
    let hasClips: Bool
    /// Why Start is unavailable, if it is.
    let startBlocker: String?
    let summary: [(label: String, value: String)]
    let onStart: () -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if job.running || job.failed || (job.finished && !hasClips) {
                header
                phaseList
            } else if job.finished {
                finishedSummary
            } else {
                startPanel
            }
            if let message = job.message {
                StatusMessage(text: message, tone: job.failed ? .error : job.finished ? .success : .info)
            }
        }
        .surfaceCard(padding: DS.Space.lg, highlighted: !job.running && !job.finished)
    }

    // MARK: Before a run

    private var startPanel: some View {
        HStack(alignment: .center, spacing: DS.Space.xl) {
            StartButton(enabled: startBlocker == nil, action: onStart)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(hasClips ? "Make more clips" : "Ready to make clips")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let source = job.source {
                    DownloadStatusLine(preparation: source)
                }
                if let startBlocker {
                    StatusMessage(text: startBlocker, tone: .warning)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(summary, id: \.label) { item in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                            Text(item.label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(item.value).lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: During and after a run

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            ProgressRing(fraction: job.overallFraction, failed: job.failed)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.failed ? "Clip making stopped" : job.finished ? "Clips are ready" : "Making your clips")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(job.currentPhase.map { "Now: \($0.title)" } ?? (job.failed ? "Fix the issue below, then try again." : "All steps finished."))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if job.running {
                Button("Cancel", role: .cancel, action: onCancel)
            } else {
                Button(action: onStart) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(startBlocker != nil)
            }
        }
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PipelinePhase.allCases) { phase in
                PhaseRow(phase: phase, state: job.state(of: phase))
                if phase != PipelinePhase.allCases.last { Divider().padding(.leading, 40) }
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: job.phases)
    }

    private var finishedSummary: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clips are ready").font(.title3.weight(.semibold))
                Text("Play, edit, or download them below. Captions are already in the video.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onStart) {
                Label("Run Again", systemImage: "arrow.clockwise")
            }
            .disabled(startBlocker != nil)
        }
    }
}

/// A large circular Start control; the one primary action before processing.
private struct StartButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(enabled ? AnyShapeStyle(DS.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                    .shadow(color: .black.opacity(enabled ? 0.18 : 0), radius: hovering ? 10 : 5, y: 3)
                VStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 30, weight: .bold))
                    Text("Start").font(.headline)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 128, height: 128)
            .scaleEffect(hovering && enabled && !reduceMotion ? 1.04 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DS.Motion.quick, value: hovering)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Start making clips (⌘↩)")
        .accessibilityLabel("Start making clips")
    }
}

private struct PhaseRow: View {
    let phase: PipelinePhase
    let state: PhaseState

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            indicator.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(phase.title)
                        .font(.body.weight(isRunning ? .semibold : .regular))
                        .foregroundStyle(isPending ? .secondary : .primary)
                    Spacer()
                    Text(statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if case .running(let fraction, let detail) = state {
                    if let fraction { ProgressView(value: min(max(fraction, 0), 1)) }
                    if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                } else if case .done(let detail?) = state {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phase.title): \(statusText)")
    }

    private var isRunning: Bool { if case .running = state { true } else { false } }
    private var isPending: Bool { state == .pending }

    private var statusText: String {
        switch state {
        case .pending: "Waiting"
        case .running(let fraction?, _): fraction.formatted(.percent.precision(.fractionLength(0)))
        case .running: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .pending:
            Image(systemName: phase.systemImage).foregroundStyle(.tertiary).font(.title3)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title3)
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double
    let failed: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(failed ? Color.red : DS.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityLabel("Overall progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// Live state of a download that runs while options are chosen.
struct DownloadStatusLine: View {
    @ObservedObject var preparation: SourcePreparation

    var body: some View {
        switch preparation.status {
        case .installingTool:
            TaskProgressRow(label: "Installing the YouTube downloader", fraction: nil)
        case .downloading(let fraction):
            TaskProgressRow(label: "Downloading video", fraction: fraction)
        case .validating:
            TaskProgressRow(label: "Checking the video", fraction: nil)
        case .ready:
            StatusMessage(text: preparation.prepared.map { "Video downloaded · \($0.asset.width) × \($0.asset.height) · \(Self.duration($0.asset.duration))" }
                          ?? "Video downloaded", tone: .success)
        case .failed(let message):
            StatusMessage(text: message, tone: .error)
        }
    }

    static func duration(_ time: MediaTime) -> String {
        let seconds = Int(time.microseconds / 1_000_000)
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
