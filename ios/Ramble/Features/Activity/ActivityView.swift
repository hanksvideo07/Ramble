import SwiftUI

/// What Ramble has actually done.
///
/// An app that takes actions on someone's behalf and gives them no way to see
/// what it did is asking for trust it has not earned. Every event, reminder,
/// task and note it created is here, along with everything that was declined
/// or failed and why.
struct ActivityView: View {
    @State private var actions: [RambleAction] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, done, declined, failed
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "Everything"
            case .done: "Done"
            case .declined: "You said no"
            case .failed: "Didn't work"
            }
        }

        func matches(_ action: RambleAction) -> Bool {
            switch self {
            case .all: !action.isPending
            case .done: action.isDone
            case .declined: action.isDeclined
            case .failed: action.isFailed
            }
        }
    }

    private var visible: [RambleAction] {
        actions.filter(filter.matches)
    }

    /// Grouped by day, because "what did it do yesterday" is the question
    /// people actually bring to this screen.
    private var days: [(day: Date, actions: [RambleAction])] {
        let calendar = Calendar.current
        return Dictionary(grouping: visible) { action in
            calendar.startOfDay(for: action.executedAt ?? action.createdAt ?? .distantPast)
        }
        .map { (day: $0.key, actions: $0.value.sorted { lhs, rhs in
            (lhs.executedAt ?? lhs.createdAt ?? .distantPast)
                > (rhs.executedAt ?? rhs.createdAt ?? .distantPast)
        }) }
        .sorted { $0.day > $1.day }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                header
                filters
                content
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text("Activity")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("What Ramble did.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text("Everything it acted on, and everything it didn't.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
        }
        .padding(.top, Theme.Metrics.sm)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Metrics.sm) {
                ForEach(Filter.allCases) { option in
                    let selected = filter == option
                    Button { filter = option } label: {
                        Text(option.label)
                            .rambleType(Theme.Text.chip)
                            .foregroundStyle(selected ? Theme.Palette.onAction : Theme.Palette.secondary)
                            .padding(.horizontal, Theme.Metrics.md)
                            .padding(.vertical, 7)
                            .background(selected ? Theme.Palette.action : Theme.Palette.subtle)
                            .clipShape(
                                RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && actions.isEmpty {
            StatusNotice(message: "Looking back through what it did\u{2026}", tone: .working)
        } else if let errorMessage, actions.isEmpty {
            EmptyState(
                title: "Couldn't load this.",
                message: errorMessage,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if visible.isEmpty {
            EmptyState(
                title: filter == .all ? "Nothing yet." : "Nothing here.",
                message: filter == .all
                    ? "When Ramble sets a reminder or adds an event for you, it'll be listed here so you can check what it actually did."
                    : "Nothing matches that filter.",
                systemImage: "checkmark.circle"
            )
        } else {
            ForEach(days, id: \.day) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(dayLabel(group.day))
                        .rambleType(Theme.Text.sectionSerif)
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.bottom, Theme.Metrics.md)
                    ForEach(group.actions) { action in
                        ActivityRow(action: action)
                    }
                }
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func load() async {
        isLoading = actions.isEmpty
        defer { isLoading = false }
        do {
            actions = try await APIClient.shared.actions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One thing Ramble did, or was stopped from doing.
private struct ActivityRow: View {
    let action: RambleAction

    private var icon: String {
        if action.isDone { return "checkmark" }
        if action.isFailed { return "exclamationmark.triangle" }
        if action.isDeclined { return "xmark" }
        return "clock"
    }

    private var tint: Color {
        if action.isDone { return Theme.Palette.action }
        if action.isFailed { return Theme.Palette.warning }
        return Theme.Palette.secondary
    }

    private var headline: String {
        if action.isDone { return action.completedLabel }
        if action.isFailed { return "\(action.label) didn't go through" }
        if action.isDeclined { return "You said no to \(action.label.lowercased())" }
        return action.label
    }

    var body: some View {
        content.modifier(LinkToSource(rambleId: action.rambleId))
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.md) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !action.detail.isEmpty {
                    Text(action.detail)
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                        .lineLimit(2)
                }

                if let error = action.error, action.isFailed {
                    Text(error)
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    if let when = action.executedAt ?? action.createdAt {
                        Text(when, format: .dateTime.hour().minute())
                    }
                    Text("\u{00B7}")
                    Text(action.destination)
                    if let title = action.rambleTitle {
                        Text("\u{00B7}")
                        Text(title).lineLimit(1)
                    }
                }
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Metrics.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Opens the recording an action came from, when there is one to open.
private struct LinkToSource: ViewModifier {
    let rambleId: String?

    func body(content: Content) -> some View {
        if let rambleId {
            NavigationLink(value: AppDestination.ramble(rambleId)) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}
