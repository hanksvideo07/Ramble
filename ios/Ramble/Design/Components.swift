import SwiftUI

// MARK: - Section heading

/// A small all-caps marker above a group. Used instead of card borders to
/// separate sections, so the page stays open rather than becoming a stack
/// of boxes.
struct SectionHeading: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Spacer(minLength: Theme.Metrics.sm)
            if let trailing {
                Text(trailing)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Labels and chips

/// What a recording became: "1 decision", "2 tasks". Small, muted, and tinted
/// by kind so the shape of a recording reads before any of its words do.
struct ExtractionLabel: View {
    let kind: ItemKind
    var count: Int = 1

    private var text: String {
        count > 1 ? "\(count) \(kind.pluralLabel.lowercased())" : kind.label.lowercased()
    }

    var body: some View {
        let accent = Theme.Palette.accent(for: kind)
        Text(text)
            .rambleType(Theme.Text.chip)
            .foregroundStyle(accent.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(accent.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous))
            .accessibilityLabel(count > 1 ? "\(count) \(kind.pluralLabel)" : kind.label)
    }
}

/// A person, company, or project referenced somewhere. Quieter than an
/// extraction label because it names a thing rather than an outcome.
struct EntityChip: View {
    let name: String
    var kind: String = "person"
    var showsAvatar: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if showsAvatar {
                InitialsAvatar(name: name, kind: kind, size: 18)
            }
            Text(name)
                .rambleType(Theme.Text.chip)
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, showsAvatar ? 5 : 7)
        .padding(.vertical, showsAvatar ? 4 : 4)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous)
                .strokeBorder(Theme.Palette.divider, lineWidth: 1)
        )
    }
}

/// Initials on a muted tinted circle. Used for people, companies, and projects
/// alike — the tint is what distinguishes them.
struct InitialsAvatar: View {
    let name: String
    var kind: String = "person"
    var size: CGFloat = 44

    private var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        return parts.isEmpty ? "?" : parts.joined().uppercased()
    }

    var body: some View {
        let accent = Theme.Palette.accent(forEntityKind: kind)
        Circle()
            .fill(accent.surface)
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .regular, design: .serif))
                    .foregroundStyle(accent.text)
            )
            .overlay(Circle().strokeBorder(Theme.Palette.divider, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The single filled button. Reserved for the affirmative choice.
struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .rambleType(Theme.Text.control)
            .foregroundStyle(Theme.Palette.onAction)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minimumTouchTarget)
            .background(Theme.Palette.action.opacity(isEnabled ? 1 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The outlined counterpart. Declining is never styled as a danger.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .rambleType(Theme.Text.control)
            .foregroundStyle(Theme.Palette.ink)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minimumTouchTarget)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.divider, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// An underlined text action, for the quiet third choice on a screen.
struct QuietButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .regular))
                }
                Text(title)
                    .underline(pattern: .solid)
            }
            .rambleType(Theme.Text.supporting)
            .foregroundStyle(Theme.Palette.secondary)
            .frame(minHeight: Theme.Metrics.minimumTouchTarget, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notices

/// A short, honest line about the state of things: offline, processing,
/// failed, simulated. Never an apology, always what happens next.
struct StatusNotice: View {
    enum Tone { case neutral, working, warning }

    let message: String
    var detail: String?
    var tone: Tone = .neutral
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?

    private var foreground: Color {
        tone == .warning ? Theme.Palette.warning : Theme.Palette.secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if tone == .working {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(foreground)
                }
            }
            .frame(width: 18, alignment: .center)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.ink)
                if let detail {
                    Text(detail)
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Theme.Metrics.sm)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.md)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous))
    }
}

/// Marks output produced by a stand-in rather than a real model, so nothing
/// simulated is ever mistaken for the real thing.
struct SampleBadge: View {
    var text: String = "Sample"

    var body: some View {
        Text(text)
            .rambleType(Theme.Text.eyebrow)
            .foregroundStyle(Theme.Palette.approvalAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.Palette.approvalSurface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.approvalBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous))
    }
}

// MARK: - Empty state

/// Shown when a screen genuinely has nothing. Says what to do next; never
/// apologises, and is never used to hide a failed request.
struct EmptyState: View {
    let title: String
    let message: String
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.Palette.secondary.opacity(0.7))
            }
            Text(title)
                .rambleType(Theme.Text.recordingTitle)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                QuietButton(title: actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Metrics.xxl)
    }
}

// MARK: - Layout

/// Wraps chips onto as many lines as they need. Chips must never clip or force
/// the page to scroll sideways.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(width: width, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height + spacing }
        return CGSize(width: proposal.width ?? 0, height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func computeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x + size.width > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A hairline. Named so no view reaches for `Divider()` and picks up the
/// system's colour instead of the paper's.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.divider)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Standard horizontal insets for a screen's content.
    func screenPadding() -> some View {
        padding(.horizontal, Theme.Metrics.screenPadding)
    }

    /// A row separated from the next by a rule rather than enclosed in a box.
    /// This is the default treatment; boxes are reserved for things that
    /// genuinely are separate objects.
    func ruledRow(top: Bool = false) -> some View {
        VStack(spacing: 0) {
            if top { Hairline() }
            self
            if !top { Hairline() }
        }
    }
}
