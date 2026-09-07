import Foundation
import Observation

/// Everything across every recording that is waiting on the person: actions
/// needing an explicit yes, and open tasks, commitments, and questions.
///
/// Shared rather than per-screen, so the marker in the history header and the
/// inbox itself can never disagree about how much is waiting.
@MainActor
@Observable
final class InboxModel {
    static let shared = InboxModel()

    private(set) var inbox: Inbox = .empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// Actions currently being submitted, so a second tap cannot double-send.
    private(set) var inFlight: Set<String> = []
    /// Actions this session declined or approved, with what happened, so the
    /// row can report the outcome honestly instead of just vanishing.
    private(set) var outcomes: [String: ActionOutcome] = [:]

    enum ActionOutcome: Equatable {
        case approved
        case declined
        case failed(String)
    }

    private init() {}

    var pendingCount: Int { inbox.pendingActions.count }
    var openCount: Int { inbox.openItems.count }

    /// The phrase used wherever the count is surfaced.
    var needsYouLabel: String? {
        guard pendingCount > 0 else { return nil }
        return pendingCount == 1 ? "1 needs your yes" : "\(pendingCount) need your yes"
    }

    func load() async {
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        await fetch()
    }

    func refresh() async {
        await fetch()
    }

    private func fetch() async {
        do {
            inbox = try await APIClient.shared.inbox()
            errorMessage = nil
            hasLoaded = true
        } catch APIError.notAuthenticated {
            errorMessage = "Your session expired. Sign in again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isSubmitting(_ action: RambleAction) -> Bool { inFlight.contains(action.id) }
    func outcome(for action: RambleAction) -> ActionOutcome? { outcomes[action.id] }

    /// Approves or declines exactly the action shown, once.
    ///
    /// A yes covers this action and nothing else, and the guard against a
    /// second submission is here rather than in the view so every screen that
    /// shows an approval inherits it.
    func respond(to action: RambleAction, approve: Bool) async {
        guard !inFlight.contains(action.id) else { return }
        inFlight.insert(action.id)
        defer { inFlight.remove(action.id) }

        do {
            if approve {
                try await APIClient.shared.confirmAction(id: action.id)
                outcomes[action.id] = .approved
                // The person just said yes to this, so asking for calendar or
                // reminders access now has obvious context.
                if action.runsOnDevice {
                    await DeviceActionRunner.shared.runPendingActions(requestingAccess: true)
                }
            } else {
                try await APIClient.shared.cancelAction(id: action.id)
                outcomes[action.id] = .declined
            }
            await fetch()
        } catch {
            outcomes[action.id] = .failed(error.localizedDescription)
        }
    }

    /// Marks an open item done. The inbox is only useful if things can leave it.
    func complete(_ item: ExtractedItem) async {
        do {
            _ = try await APIClient.shared.updateItem(id: item.id, status: "done")
            await fetch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
