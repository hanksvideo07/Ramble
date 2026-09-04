import SwiftUI

/// One recording in the timeline: when, what it was about, and what it became.
struct RambleCardView: View {
    let ramble: RambleCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ramble.recordedAt, format: .dateTime.hour().minute())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
                Spacer()
                if ramble.pendingActions > 0 {
                    Label("\(ramble.pendingActions)", systemImage: "bell.badge")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                }
                Text(ramble.durationSeconds.durationLabel)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }

            Text(ramble.displayTitle)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if ramble.processingState == .processed {
                if let summary = ramble.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                let chips = ramble.sortedCounts
                if !chips.isEmpty || !ramble.entityNames.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(chips, id: \.kind) { entry in
                            KindChip(kind: entry.kind, count: entry.count)
                        }
                        ForEach(ramble.entityNames.prefix(4), id: \.self) { name in
                            EntityChip(name: name)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                ProcessingRow(state: ramble.processingState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rambleCard()
    }
}

/// The card's state while the pipeline is still working. The user was told to
/// walk away, so this has to be calm and self-explanatory.
private struct ProcessingRow: View {
    let state: ProcessingState

    var body: some View {
        HStack(spacing: 8) {
            if state == .failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(state.label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.top, 2)
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
