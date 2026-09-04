import SwiftUI

/// A small labelled count, e.g. "2 Tasks". Chips are how a timeline card shows
/// what a recording became without opening it.
struct KindChip: View {
    let kind: ItemKind
    let count: Int

    var body: some View {
        Text(count > 1 ? "\(count) \(kind.pluralLabel)" : kind.label)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.kind(kind))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.Palette.kind(kind).opacity(0.10))
            .clipShape(Capsule())
    }
}

/// An entity reference on a card. Visually quieter than a kind chip because
/// it names a thing rather than an outcome.
struct EntityChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }
}

/// Wraps chips onto as many lines as they need. A card may carry any number of
/// them, and they must never clip or force horizontal scrolling.
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

/// Shown when a screen has nothing yet. Says what to do, never apologizes.
struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "waveform"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.muted.opacity(0.6))
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.text)
            Text(message)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}

/// Marks output produced by a stand-in provider rather than a real one, so
/// mocked results are never mistaken for genuine understanding.
struct MockBadge: View {
    var body: some View {
        Text("SAMPLE")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Theme.Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.Palette.hairline.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
