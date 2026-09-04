import Foundation
import Observation

/// Loads the timeline and groups it into days.
@MainActor
@Observable
final class TimelineModel {
    struct Day: Identifiable {
        let id: Date
        let label: String
        var rambles: [RambleCard]
    }

    private(set) var days: [Day] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = false
    var errorMessage: String?

    private var cards: [RambleCard] = []
    private var nextCursor: Date?
    /// Rambles still being processed are polled until they settle.
    private var pollTask: Task<Void, Never>?

    func load() async {
        guard cards.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        await fetch(reset: true)
    }

    func refresh() async {
        await fetch(reset: true)
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await APIClient.shared.timeline(before: cursor)
            cards.append(contentsOf: page.rambles)
            nextCursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            regroup()
        } catch {
            canLoadMore = false
            errorMessage = error.localizedDescription
        }
    }

    private func fetch(reset: Bool) async {
        do {
            let page = try await APIClient.shared.timeline()
            cards = page.rambles
            nextCursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            errorMessage = nil
            regroup()
            schedulePollIfNeeded()
        } catch APIError.notAuthenticated {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func regroup() {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: cards) { calendar.startOfDay(for: $0.recordedAt) }
        days = grouped
            .map { Day(id: $0.key, label: Self.label(for: $0.key), rambles: $0.value.sorted { $0.recordedAt > $1.recordedAt }) }
            .sorted { $0.id > $1.id }
    }

    /// Anything mid-pipeline is refreshed on a timer, so a card fills itself in
    /// while the user watches instead of needing a pull.
    private func schedulePollIfNeeded() {
        pollTask?.cancel()
        guard cards.contains(where: { !$0.processingState.isTerminal }) else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.fetch(reset: false)
        }
    }

    private static func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        // Within the last week, the weekday alone is the most readable label.
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
