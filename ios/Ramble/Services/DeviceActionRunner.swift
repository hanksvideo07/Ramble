import EventKit
import Foundation

/// Runs the actions that can only happen on the device.
///
/// Apple Calendar and Reminders live behind EventKit, which has no server-side
/// equivalent. Keeping them here also means the user's calendar never reaches
/// our servers: the backend only ever knows that an event was requested and
/// whether it was created.
@MainActor
final class DeviceActionRunner {
    static let shared = DeviceActionRunner()
    private let store = EKEventStore()

    private init() {}

    // MARK: - Permissions

    func requestCalendarAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func requestRemindersAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    var hasCalendarAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var hasRemindersAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    // MARK: - Running approved actions

    /// Pulls everything the server has approved for this device, runs it, and
    /// reports each outcome back. Failures are reported too, so an action never
    /// silently disappears.
    ///
    /// `requestingAccess` decides whether a missing permission may raise a
    /// system prompt. It is false for background sweeps — being asked for
    /// calendar access the instant you sign in, before you have approved
    /// anything, is exactly the kind of interruption this product should not
    /// make. Those actions simply stay pending until the user grants access in
    /// Settings or approves an action, where the prompt has obvious context.
    func runPendingActions(requestingAccess: Bool = false) async {
        guard let actions = try? await APIClient.shared.pendingDeviceActions() else { return }

        for action in actions {
            guard requestingAccess || hasAccess(for: action.type) else { continue }
            do {
                let result = try await run(action, requestingAccess: requestingAccess)
                try? await APIClient.shared.reportActionResult(
                    id: action.id, success: true, result: result, error: nil
                )
            } catch {
                try? await APIClient.shared.reportActionResult(
                    id: action.id, success: false, result: [:],
                    error: error.localizedDescription
                )
            }
        }
    }

    /// Whether this action could run right now without prompting.
    private func hasAccess(for type: String) -> Bool {
        switch type {
        case "calendar.create_event", "calendar.update_event": hasCalendarAccess
        case "reminder.create": hasRemindersAccess
        default: false
        }
    }

    private func run(_ action: DeviceAction, requestingAccess: Bool) async throws -> [String: String] {
        switch action.type {
        case "calendar.create_event": try await createEvent(action.parameters, requestingAccess: requestingAccess)
        case "calendar.update_event": try await updateEvent(action.parameters, requestingAccess: requestingAccess)
        case "reminder.create": try await createReminder(action.parameters, requestingAccess: requestingAccess)
        default: throw DeviceActionError.unsupported(action.type)
        }
    }

    // MARK: - Calendar

    private func createEvent(_ parameters: JSONValue, requestingAccess: Bool) async throws -> [String: String] {
        // `&&` takes an autoclosure, which cannot await, so the request is
        // made in an explicit branch when access is not already granted.
        var calendarAccess = hasCalendarAccess
        if !calendarAccess, requestingAccess { calendarAccess = await requestCalendarAccess() }
        guard calendarAccess else { throw DeviceActionError.noAccess("Calendar") }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw DeviceActionError.noCalendar
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = parameters["title"]?.stringValue ?? "Ramble event"
        event.notes = parameters["notes"]?.stringValue
        event.location = parameters["location"]?.stringValue

        let start = parameters["starts_at"]?.stringValue.flatMap(Self.parseDate)
            // An event with no stated time is better placed at the next hour
            // than silently dropped; the user confirmed it deliberately.
            ?? Date().nextHour()
        event.startDate = start

        if let end = parameters["ends_at"]?.stringValue.flatMap(Self.parseDate) {
            event.endDate = end
        } else {
            let minutes = parameters["duration_minutes"]?.doubleValue ?? 30
            event.endDate = start.addingTimeInterval(minutes * 60)
        }

        try store.save(event, span: .thisEvent)
        return ["event_id": event.eventIdentifier ?? "", "starts_at": ISO8601DateFormatter.plain.string(from: start)]
    }

    private func updateEvent(_ parameters: JSONValue, requestingAccess: Bool) async throws -> [String: String] {
        var calendarAccess = hasCalendarAccess
        if !calendarAccess, requestingAccess { calendarAccess = await requestCalendarAccess() }
        guard calendarAccess else { throw DeviceActionError.noAccess("Calendar") }
        guard let id = parameters["event_id"]?.stringValue,
              let event = store.event(withIdentifier: id)
        else { throw DeviceActionError.eventNotFound }

        if let title = parameters["title"]?.stringValue { event.title = title }
        if let start = parameters["starts_at"]?.stringValue.flatMap(Self.parseDate) {
            event.startDate = start
        }
        if let end = parameters["ends_at"]?.stringValue.flatMap(Self.parseDate) {
            event.endDate = end
        }

        try store.save(event, span: .thisEvent)
        return ["event_id": id]
    }

    // MARK: - Reminders

    private func createReminder(_ parameters: JSONValue, requestingAccess: Bool) async throws -> [String: String] {
        var remindersAccess = hasRemindersAccess
        if !remindersAccess, requestingAccess { remindersAccess = await requestRemindersAccess() }
        guard remindersAccess else { throw DeviceActionError.noAccess("Reminders") }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw DeviceActionError.noCalendar
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = parameters["title"]?.stringValue ?? "Ramble reminder"
        reminder.notes = parameters["notes"]?.stringValue

        if let due = parameters["due_at"]?.stringValue.flatMap(Self.parseDate) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            // A due date without an alarm produces no notification, which is
            // not what someone asking to be reminded expects.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        try store.save(reminder, commit: true)
        return ["reminder_id": reminder.calendarItemIdentifier]
    }

    // MARK: - Helpers

    private static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.flexible.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }
}

enum DeviceActionError: LocalizedError {
    case noAccess(String)
    case noCalendar
    case eventNotFound
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noAccess(let what): "Ramble doesn't have access to your \(what.lowercased())."
        case .noCalendar: "No default calendar is set up on this device."
        case .eventNotFound: "That calendar event no longer exists."
        case .unsupported(let type): "This version can't run \(type) on the device."
        }
    }
}

private extension Date {
    func nextHour() -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: self)
        let hour = calendar.date(from: components) ?? self
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? self
    }
}
