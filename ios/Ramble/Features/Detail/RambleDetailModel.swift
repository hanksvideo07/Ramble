import Foundation
import Observation

@MainActor
@Observable
final class RambleDetailModel {
    struct ItemGroup {
        let kind: ItemKind
        var items: [ExtractedItem]
    }

    let rambleId: String
    private(set) var detail: RambleDetail?
    private(set) var isLoading = false
    var errorMessage: String?

    private var pollTask: Task<Void, Never>?

    init(rambleId: String) {
        self.rambleId = rambleId
    }

    /// Items grouped by kind, with what the user owes listed before what they thought.
    var groupedItems: [ItemGroup] {
        guard let detail else { return [] }
        let relevant = detail.items.filter { $0.kind != .summary }
        return Dictionary(grouping: relevant, by: \.kind)
            .map { ItemGroup(kind: $0.key, items: $0.value) }
            .sorted { ($0.kind.sortRank, $0.kind.label) < ($1.kind.sortRank, $1.kind.label) }
    }

    func load() async {
        isLoading = detail == nil
        defer { isLoading = false }
        do {
            detail = try await APIClient.shared.ramble(id: rambleId)
            errorMessage = nil
            schedulePollIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opening a ramble that is still processing should fill itself in rather
    /// than needing the user to pull.
    private func schedulePollIfNeeded() {
        pollTask?.cancel()
        guard let state = detail?.processingState, !state.isTerminal else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func respond(to action: RambleAction, approve: Bool) async {
        do {
            if approve {
                try await APIClient.shared.confirmAction(id: action.id)
                // The user just approved this, so prompting for calendar or
                // reminders access now has obvious context.
                await DeviceActionRunner.shared.runPendingActions(requestingAccess: true)
            } else {
                try await APIClient.shared.cancelAction(id: action.id)
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func correct(_ item: ExtractedItem, kind: ItemKind, title: String) async {
        do {
            _ = try await APIClient.shared.updateItem(
                id: item.id,
                kind: kind == item.kind ? nil : kind,
                title: title == item.title ? nil : title
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reprocess() async {
        do {
            try await APIClient.shared.reprocess(id: rambleId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete() async {
        try? await APIClient.shared.deleteRamble(id: rambleId)
    }
}
