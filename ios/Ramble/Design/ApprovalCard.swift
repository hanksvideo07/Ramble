import SwiftUI

/// The one place Ramble asks permission.
///
/// Pale honey on a restrained accent border, deliberately unlike every other
/// surface in the app: a decision that leaves the person's own data should not
/// look like a paragraph. Everything needed to say yes responsibly is on the
/// card — what would happen, where it would land, and the words it came from.
struct ApprovalCard: View {
    let action: RambleAction
    /// Nil when the card is shown inside the recording it came from, since the
    /// source is then already on screen.
    var showsSource: Bool = false
    var isSubmitting: Bool = false
    var outcome: InboxModel.ActionOutcome?
    /// Seeks the recording's audio to the quoted moment, where playback exists.
    var seek: ((Double) -> Void)?
    let respond: (Bool) -> Void

    @State private var showingDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            header
            if let reason = action.reason {
                Text(reason)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quote = action.sourceQuote, !quote.isEmpty {
                sourceQuote(quote)
            }
            inspector
            footer
        }
        .padding(Theme.Metrics.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.approvalSurface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.surfaceRadius, style: .continuous)
                .strokeBorder(Theme.Palette.approvalBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.surfaceRadius, style: .continuous))
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            HStack(spacing: 6) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 12, weight: .regular))
                Text("Needs your yes")
                    .rambleType(Theme.Text.eyebrow)
            }
            .foregroundStyle(Theme.Palette.approvalAccent)

            Text(action.question)
                .rambleType(Theme.Text.sectionSerif)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !action.detail.isEmpty {
                Text(action.detail)
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsSource, let title = action.rambleTitle, let rambleId = action.rambleId {
                NavigationLink(value: AppDestination.ramble(rambleId)) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform").font(.system(size: 10))
                        Text("From \(title)").lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(minHeight: 28, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sourceQuote(_ quote: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.xs) {
            Text("\u{201C}\(quote)\u{201D}")
                .rambleType(Theme.Text.quote)
                .italic()
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let start = action.sourceStartSeconds {
                if let seek {
                    Button { seek(start) } label: {
                        Label(start.durationLabel, systemImage: "play.circle")
                            .rambleType(Theme.Text.meta)
                            .foregroundStyle(Theme.Palette.approvalAccent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(start.durationLabel)
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(Theme.Palette.secondary)
                }
            }
        }
        .padding(.leading, Theme.Metrics.md)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Palette.approvalBorder)
                .frame(width: 2)
        }
    }

    /// Everything the person is entitled to see before agreeing. Collapsed,
    /// because most yeses are obvious — but never more than one tap away.
    private var inspector: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Button {
                withAnimation(reduceMotion ? nil : .ramble()) { showingDetails.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showingDetails ? "Hide what would happen" : "See exactly what would happen")
                }
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
                .frame(minHeight: Theme.Metrics.minimumTouchTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See exactly what would happen")

            if showingDetails {
                VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                    ForEach(action.inspection, id: \.label) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label)
                                .rambleType(Theme.Text.eyebrow)
                                .foregroundStyle(Theme.Palette.secondary)
                            Text(field.value)
                                .rambleType(Theme.Text.supporting)
                                .foregroundStyle(Theme.Palette.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Metrics.md)
                .background(Theme.Palette.paper.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch outcome {
        case .approved:
            resultLine(
                icon: "checkmark",
                text: action.runsOnDevice
                    ? "Approved. Your phone is taking care of it."
                    : "Approved.",
                tone: Theme.Palette.action
            )
        case .declined:
            resultLine(icon: "xmark", text: "Declined. Nothing was sent.", tone: Theme.Palette.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                resultLine(icon: "exclamationmark.triangle", text: message, tone: Theme.Palette.warning)
                Button("Try again") { respond(true) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case nil:
            HStack(spacing: Theme.Metrics.sm) {
                Button(action.declineTitle) { respond(false) }
                    .buttonStyle(SecondaryButtonStyle())
                Button {
                    respond(true)
                } label: {
                    HStack(spacing: 6) {
                        if isSubmitting { ProgressView().controlSize(.small).tint(Theme.Palette.onAction) }
                        Text(action.confirmTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(isSubmitting)
        }
    }

    private func resultLine(icon: String, text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .rambleType(Theme.Text.supporting)
        .foregroundStyle(tone)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
