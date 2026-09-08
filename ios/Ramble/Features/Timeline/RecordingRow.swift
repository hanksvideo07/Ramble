import SwiftUI

/// One recording in the history.
///
/// Not a card: a ruled entry on the page. Boxing every recording turns a
/// notebook into a dashboard, and the guide asks for the former.
struct RecordingRow: View {
    let ramble: RambleCard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much this recording turned out to hold.
    ///
    /// Every row used to be identical whether it carried one stray note or a
    /// twelve-minute conversation with five decisions in it, which made a
    /// history of real thinking read as a uniform list of receipts. Weight is
    /// what gives the page rhythm: a substantial recording is set larger, keeps
    /// more of its summary, and shows its labels; a passing thought stays
    /// small. The information was always there — it just wasn't visible.
    private enum Weight {
        case passing, ordinary, substantial

        var titleStyle: Theme.TypeStyle {
            switch self {
            case .passing: Theme.Text.sectionSerif
            case .ordinary: Theme.Text.recordingTitle
            case .substantial: Theme.Text.pageTitle
            }
        }

        var summaryLines: Int {
            switch self {
            case .passing: 1
            case .ordinary: 2
            case .substantial: 4
            }
        }

        var spacing: CGFloat {
            switch self {
            case .passing: Theme.Metrics.xs
            case .ordinary: Theme.Metrics.sm
            case .substantial: Theme.Metrics.md
            }
        }

        var bottomPadding: CGFloat {
            switch self {
            case .passing: Theme.Metrics.lg
            case .ordinary: Theme.Metrics.xl
            case .substantial: Theme.Metrics.xxl
            }
        }
    }

    private var weight: Weight {
        // Extracted things count for more than duration: a thirty-second
        // recording that produced a decision and two tasks matters more than
        // two minutes of thinking aloud that produced one note.
        let extracted = ramble.itemCounts
            .filter { $0.key != ItemKind.summary.rawValue && $0.key != ItemKind.note.rawValue }
            .values.reduce(0, +)
        let score = extracted * 2 + Int(ramble.durationSeconds / 45)
        if score >= 6 { return .substantial }
        if score >= 2 { return .ordinary }
        return .passing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: weight.spacing) {
            meta

            Text(ramble.displayTitle)
                .rambleType(weight.titleStyle)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if ramble.processingState == .processed {
                if let summary = ramble.summary, !summary.isEmpty {
                    Text(summary)
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                        .lineLimit(weight.summaryLines)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A passing thought does not need its own label; the title is
                // already the whole of it.
                if weight != .passing { labels }

            } else {
                ProcessingLine(state: ramble.processingState)
            }

            if ramble.pendingActions > 0 {
                ApprovalMarker(count: ramble.pendingActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, weight.bottomPadding)
        .contentShape(Rectangle())
        // The moment understanding lands. A row watched through processing
        // used to snap from a spinner to a finished entry between two polls;
        // now the summary and the labels arrive. It is the only place in the
        // app where the person can actually see the thing work.
        .animation(
            reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82),
            value: ramble.processingState
        )
        .accessibilityElement(children: .combine)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(ramble.recordedAt, format: .dateTime.hour().minute())
            Spacer(minLength: Theme.Metrics.sm)
            Image(systemName: "waveform")
                .font(.system(size: 9, weight: .regular))
            Text(ramble.durationSeconds.durationLabel)
                .monospacedDigit()
        }
        .rambleType(Theme.Text.meta)
        .foregroundStyle(Theme.Palette.secondary)
    }

    @ViewBuilder
    private var labels: some View {
        let counts = ramble.sortedCounts
        if !counts.isEmpty || !ramble.entityNames.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(counts, id: \.kind) { entry in
                    ExtractionLabel(kind: entry.kind, count: entry.count)
                }
                ForEach(ramble.entityNames.prefix(3), id: \.self) { name in
                    EntityChip(name: name, showsAvatar: false)
                }
            }
            .padding(.top, Theme.Metrics.xs)
            .transition(
                reduceMotion
                    ? .identity
                    : .opacity.combined(with: .offset(y: 6))
            )
        }
    }
}

/// A recording that hasn't reached the server yet. It is a real entry in the
/// history from the moment it stops — the audio exists, and saying otherwise
/// would make the person wonder whether they lost it.
struct LocalRecordingRow: View {
    let capture: CaptureQueue.PendingCapture
    let state: UploadState
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            HStack(spacing: 6) {
                Text(capture.recordedAt, format: .dateTime.hour().minute())
                Spacer(minLength: Theme.Metrics.sm)
                Image(systemName: "waveform").font(.system(size: 9))
                Text(capture.duration.durationLabel).monospacedDigit()
            }
            .rambleType(Theme.Text.meta)
            .foregroundStyle(Theme.Palette.secondary)

            Text(state.label)
                .rambleType(Theme.Text.recordingTitle)
                .foregroundStyle(Theme.Palette.ink)

            if let detail = state.detail {
                Text(detail)
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed = state {
                QuietButton(title: "Try sending it again", systemImage: "arrow.clockwise", action: retry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Theme.Metrics.xl)
        .accessibilityElement(children: .combine)
    }
}

/// The line shown while the pipeline is still working. The person was told to
/// walk away, so this is calm and self-explanatory rather than a spinner.
struct ProcessingLine: View {
    let state: ProcessingState

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.sm) {
            if state == .failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.warning)
                    .padding(.top, 2)
            } else {
                ProgressView().controlSize(.mini).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label)
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(state == .failed ? Theme.Palette.warning : Theme.Palette.secondary)
                if let detail = state.detail {
                    Text(detail)
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(Theme.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }
}

/// The one thing on a history row that is genuinely urgent.
struct ApprovalMarker: View {
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.raised")
                .font(.system(size: 10, weight: .regular))
            Text(count == 1 ? "1 needs your yes" : "\(count) need your yes")
                .rambleType(Theme.Text.chip)
        }
        .foregroundStyle(Theme.Palette.approvalAccent)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.Palette.approvalSurface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous)
                .strokeBorder(Theme.Palette.approvalBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous))
        .padding(.top, Theme.Metrics.xs)
    }
}

extension Double {
    /// "0:47", "12:05", "1:02:30"
    var durationLabel: String {
        let total = Int(rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
