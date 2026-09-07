import SwiftUI

/// One recording in the history.
///
/// Not a card: a ruled entry on the page. Boxing every recording turns a
/// notebook into a dashboard, and the guide asks for the former.
struct RecordingRow: View {
    let ramble: RambleCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            meta

            Text(ramble.displayTitle)
                .rambleType(Theme.Text.recordingTitle)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if ramble.processingState == .processed {
                if let summary = ramble.summary, !summary.isEmpty {
                    Text(summary)
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                labels
            } else {
                ProcessingLine(state: ramble.processingState)
            }

            if ramble.pendingActions > 0 {
                ApprovalMarker(count: ramble.pendingActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Theme.Metrics.xl)
        .contentShape(Rectangle())
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
