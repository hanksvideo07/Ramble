import Foundation
import Observation

@MainActor
@Observable
final class RambleDetailModel {
    struct ItemGroup: Identifiable {
        let kind: ItemKind
        var items: [ExtractedItem]
        var id: ItemKind { kind }
    }

    let rambleId: String
    private(set) var detail: RambleDetail?
    private(set) var isLoading = false
    var errorMessage: String?
    /// Set when a correction failed, so the sheet's optimism can be walked back.
    private(set) var lastActionError: String?

    private(set) var inFlightActions: Set<String> = []
    private(set) var outcomes: [String: InboxModel.ActionOutcome] = [:]

    private var pollTask: Task<Void, Never>?

    init(rambleId: String) {
        self.rambleId = rambleId
    }

    /// Items grouped by kind, with what the person owes listed before what
    /// they merely thought.
    var groupedItems: [ItemGroup] {
        guard let detail else { return [] }
        let relevant = detail.items.filter { $0.kind != .summary }
        return Dictionary(grouping: relevant, by: \.kind)
            .map { ItemGroup(kind: $0.key, items: $0.value) }
            .sorted { ($0.kind.sortRank, $0.kind.label) < ($1.kind.sortRank, $1.kind.label) }
    }

    var pendingActions: [RambleAction] { detail?.actions.filter(\.isPending) ?? [] }
    var completedActions: [RambleAction] { detail?.actions.filter(\.isDone) ?? [] }
    /// Declined and failed, kept on screen so an answer never just vanishes.
    var resolvedActions: [RambleAction] {
        detail?.actions.filter { $0.isDeclined || $0.isFailed } ?? []
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

    /// Opening a recording that is still processing should fill itself in
    /// rather than making the person pull.
    private func schedulePollIfNeeded() {
        pollTask?.cancel()
        guard let state = detail?.processingState, !state.isTerminal else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func isSubmitting(_ action: RambleAction) -> Bool { inFlightActions.contains(action.id) }
    func outcome(for action: RambleAction) -> InboxModel.ActionOutcome? { outcomes[action.id] }

    /// A yes approves exactly the action shown, once.
    func respond(to action: RambleAction, approve: Bool) async {
        guard !inFlightActions.contains(action.id) else { return }
        inFlightActions.insert(action.id)
        defer { inFlightActions.remove(action.id) }

        do {
            if approve {
                try await APIClient.shared.confirmAction(id: action.id)
                outcomes[action.id] = .approved
                if action.runsOnDevice {
                    await DeviceActionRunner.shared.runPendingActions(requestingAccess: true)
                }
            } else {
                try await APIClient.shared.cancelAction(id: action.id)
                outcomes[action.id] = .declined
            }
            await load()
            await InboxModel.shared.refresh()
        } catch {
            outcomes[action.id] = .failed(error.localizedDescription)
        }
    }

    /// Saves a correction. Corrections are stored and survive reprocessing.
    func correct(_ item: ExtractedItem, kind: ItemKind, title: String) async {
        do {
            _ = try await APIClient.shared.updateItem(
                id: item.id,
                kind: kind == item.kind ? nil : kind,
                title: title == item.title ? nil : title
            )
            lastActionError = nil
            await load()
            await InboxModel.shared.refresh()
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    /// Re-transcribes with the cloud provider and re-runs understanding on the
    /// better transcript.
    func upgradeTranscript() async {
        do {
            try await APIClient.shared.upgradeTranscript(rambleId: rambleId)
            await load()
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    func reprocess() async {
        do {
            try await APIClient.shared.reprocess(id: rambleId)
            await load()
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    /// Rewrites the recording's own title or summary.
    ///
    /// Both are model output and were previously permanent — you could correct
    /// an item but not the sentence describing the whole recording. Reloading
    /// afterwards rather than patching in place keeps this screen honest about
    /// what the server actually stored.
    func rename(title: String, summary: String?) async {
        do {
            try await APIClient.shared.updateRamble(
                id: rambleId,
                title: title,
                summary: summary
            )
            lastActionError = nil
            await load()
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    func delete() async {
        try? await APIClient.shared.deleteRamble(id: rambleId)
    }
}
