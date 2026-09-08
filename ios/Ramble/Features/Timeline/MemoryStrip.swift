import SwiftUI

/// What has built up.
///
/// The app could tell you what you said and never that you had been saying it —
/// no sense of how much had accumulated, who keeps coming up, or how long this
/// had been going on. For a product whose whole promise is that it remembers
/// for you, that absence was the loudest thing about it.
///
/// Deliberately not a dashboard. No big numbers, no charts, no streak badge
/// demanding to be kept alive. One sentence in the app's own voice, and the
/// names that keep recurring — which is the part a person genuinely cannot see
/// for themselves.
struct MemoryStrip: View {
    let summary: MemorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            Text(sentence)
                .rambleType(Theme.Text.quote)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !summary.recurring.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                    Text("Keeps coming up")
                        .rambleType(Theme.Text.eyebrow)
                        .foregroundStyle(Theme.Palette.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(summary.recurring) { entity in
                            NavigationLink(value: AppDestination.entity(entity.id)) {
                                EntityChip(name: entity.name, kind: entity.kind)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.bottom, Theme.Metrics.xl)
    }

    /// Written as a sentence rather than a row of figures, because "you have
    /// been thinking out loud for three weeks" means something and "21" does
    /// not.
    private var sentence: String {
        var parts: [String] = []
        parts.append("\(summary.rambles) recordings, \(summary.spokenLabel) of talking")

        let kinds = summary.notableKinds
        if !kinds.isEmpty {
            let phrase = kinds
                .map { "\($0.count) \($0.count == 1 ? $0.kind.label.lowercased() : $0.kind.pluralLabel.lowercased())" }
                .joined(separator: ", ")
            parts.append(phrase)
        }

        if let first = summary.firstRecordedAt {
            let days = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
            if days >= 14 {
                parts.append("since \(first.formatted(.dateTime.month(.wide).year()))")
            }
        }

        return parts.joined(separator: " \u{00B7} ") + "."
    }
}
