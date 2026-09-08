import Foundation
import Observation

/// One row in the history. A recording exists from the moment it stops, so a
/// capture still sitting on the phone is a first-class entry rather than a
/// banner bolted onto the top of the list.
enum TimelineEntry: Identifiable {
    case local(CaptureQueue.PendingCapture, UploadState)
    case remote(RambleCard)

    var id: String {
        switch self {
        case .local(let capture, _): "local-" + capture.id
        case .remote(let card): card.id
        }
    }

    var recordedAt: Date {
        switch self {
        case .local(let capture, _): capture.recordedAt
        case .remote(let card): card.recordedAt
        }
    }
}

/// Loads the history, groups it by day, and folds in whatever is still
/// waiting to upload.
@MainActor
@Observable
final class TimelineModel {
    struct Day: Identifiable {
        let id: Date
        let label: String
        var entries: [TimelineEntry]
    }

    private(set) var isLoading = false
    private(set) var canLoadMore = false
    /// A failed request, kept separate from "you have nothing yet". Saying the
    /// account is empty when the request failed would be a lie.
    private(set) var errorMessage: String?
    /// Ids seen for the first time in the latest load, so only genuinely new
    /// rows animate in.
    private(set) var arriving: Set<String> = []
    /// What has accumulated. Nil until it loads; absent is not an error.
    private(set) var summary: MemorySummary?

    private var cards: [RambleCard] = []
    private var knownIds: Set<String> = []
    private var nextCursor: Date?
    private var pollTask: Task<Void, Never>?

    /// The history, newest first, merged with anything still on the device.
    ///
    /// Computed rather than stored so a capture finishing, failing, or being
    /// retried shows up without the timeline needing to be told.
    var days: [Day] {
        let queue = CaptureQueue.shared
        let uploaded = Set(cards.map(\.id))
        let locals: [TimelineEntry] = queue.pending
            // Once the server has issued an id, its own row is the better one:
            // it carries processing state this side knows nothing about.
            .filter { $0.rambleId.map { !uploaded.contains($0) } ?? true }
            .map { .local($0, queue.state(for: $0)) }

        let all = locals + cards.map(TimelineEntry.remote)
        let calendar = Calendar.current
        return Dictionary(grouping: all) { calendar.startOfDay(for: $0.recordedAt) }
            .map { key, value in
                Day(
                    id: key,
                    label: Self.label(for: key),
                    entries: value.sorted { $0.recordedAt > $1.recordedAt }
                )
            }
            .sorted { $0.id > $1.id }
    }

    var isEmpty: Bool { cards.isEmpty && CaptureQueue.shared.pending.isEmpty }

    /// Drives the arrival animation. A count is enough: rows only ever enter
    /// at the top, and animating on identity would re-run on every poll.
    var entryCount: Int { cards.count + CaptureQueue.shared.pending.count }

    func load() async {
        guard cards.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        await fetch()
        await loadSummary()
    }

    func refresh() async {
        await fetch()
        await InboxModel.shared.refresh()
        await loadSummary()
    }

    /// Best-effort: the history is worth showing whether or not this arrives.
    func loadSummary() async {
        summary = try? await APIClient.shared.summary()
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await APIClient.shared.timeline(before: cursor)
            cards.append(contentsOf: page.rambles)
            knownIds.formUnion(page.rambles.map(\.id))
            nextCursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
        } catch {
            canLoadMore = false
            errorMessage = error.localizedDescription
        }
    }

    private func fetch() async {
        do {
            let page = try await APIClient.shared.timeline()
            let incoming = Set(page.rambles.map(\.id))
            // First load isn't an arrival — the whole list would animate.
            arriving = knownIds.isEmpty ? [] : incoming.subtracting(knownIds)
            knownIds.formUnion(incoming)
            cards = page.rambles
            nextCursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            errorMessage = nil
            schedulePollIfNeeded()
        } catch APIError.notAuthenticated {
            errorMessage = "Your session expired. Sign in again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Anything mid-pipeline is refreshed on a timer so a row fills itself in
    /// while the person watches, without them having to pull.
    private func schedulePollIfNeeded() {
        pollTask?.cancel()
        guard cards.contains(where: { !$0.processingState.isTerminal }) else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.fetch()
            await InboxModel.shared.refresh()
        }
    }

    private static func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}
