import Foundation

// MARK: - Item kinds

/// What a piece of a ramble turned out to be. Mirrors the server's vocabulary.
enum ItemKind: String, Codable, CaseIterable, Hashable {
    case summary, note, idea, task, reminder, decision, question, journal
    case commitment
    case followUp = "follow_up"
    case reference

    var label: String {
        switch self {
        case .summary: "Summary"
        case .note: "Note"
        case .idea: "Idea"
        case .task: "Task"
        case .reminder: "Reminder"
        case .decision: "Decision"
        case .question: "Question"
        case .journal: "Journal"
        case .commitment: "Commitment"
        case .followUp: "Follow-up"
        case .reference: "Reference"
        }
    }

    var pluralLabel: String {
        switch self {
        case .summary: "Summaries"
        case .followUp: "Follow-ups"
        default: label + "s"
        }
    }

    var systemImage: String {
        switch self {
        case .task: "checkmark.circle"
        case .reminder: "bell"
        case .idea: "lightbulb"
        case .decision: "arrow.triangle.branch"
        case .question: "questionmark.circle"
        case .journal: "book.closed"
        case .commitment, .followUp: "hand.raised"
        case .reference: "link"
        default: "text.alignleft"
        }
    }

    /// The order kinds appear in a detail view: what you owe first, thoughts after.
    var sortRank: Int {
        switch self {
        case .task, .reminder: 0
        case .commitment, .followUp: 1
        case .decision: 2
        case .idea: 3
        case .question: 4
        default: 5
        }
    }
}

// MARK: - Processing state

enum ProcessingState: String, Codable, Equatable {
    case awaitingUpload = "awaiting_upload"
    case uploaded, transcribing, transcribed, understanding, embedding, processed, failed

    var isTerminal: Bool { self == .processed || self == .failed }

    /// What the user sees on a row while work is still happening.
    var label: String {
        switch self {
        case .awaitingUpload: "Saved on your phone"
        case .uploaded, .transcribing: "Finding the words\u{2026}"
        case .transcribed, .understanding: "Finding the shape of it\u{2026}"
        case .embedding: "Almost there\u{2026}"
        case .processed: "Ready"
        case .failed: "Couldn't finish"
        }
    }

    /// The reassuring second line. The person was told to walk away, so the
    /// wait has to explain itself without sounding like something is wrong.
    var detail: String? {
        switch self {
        case .awaitingUpload: "It'll send when you're back online."
        case .uploaded, .transcribing, .transcribed, .understanding, .embedding:
            "Your recording is here. Understanding is on its way."
        case .processed: nil
        case .failed: "Your recording and transcript are safe."
        }
    }
}

/// Where a locally captured recording has got to. The recording exists from
/// the moment it stops; this only describes how far it has travelled.
enum UploadState: Equatable {
    case storedLocally
    case uploading
    case waitingForConnection
    case failed(String)

    var label: String {
        switch self {
        case .storedLocally: "Saved on your phone"
        case .uploading: "Sending\u{2026}"
        case .waitingForConnection: "Waiting for a connection"
        case .failed: "Couldn't send yet"
        }
    }

    var detail: String? {
        switch self {
        case .storedLocally: "Understanding starts once it uploads."
        case .uploading: "Your recording is here. Understanding is on its way."
        case .waitingForConnection: "It'll send by itself when you reconnect."
        case .failed(let reason): reason
        }
    }
}

// MARK: - Timeline

struct RambleCard: Identifiable, Codable, Hashable {
    let id: String
    let title: String?
    let summary: String?
    let recordedAt: Date
    let durationSeconds: Double
    let processingState: ProcessingState
    let sourceDevice: String
    let itemCounts: [String: Int]
    let entityNames: [String]
    let pendingActions: Int

    enum CodingKeys: String, CodingKey {
        case id, title, summary
        case recordedAt = "recorded_at"
        case durationSeconds = "duration_seconds"
        case processingState = "processing_state"
        case sourceDevice = "source_device"
        case itemCounts = "item_counts"
        case entityNames = "entity_names"
        case pendingActions = "pending_actions"
    }

    /// Chips in a stable, meaningful order rather than dictionary order.
    var sortedCounts: [(kind: ItemKind, count: Int)] {
        itemCounts
            .compactMap { key, value in
                guard let kind = ItemKind(rawValue: key), kind != .summary else { return nil }
                return (kind, value)
            }
            .sorted { ($0.kind.sortRank, $0.kind.label) < ($1.kind.sortRank, $1.kind.label) }
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return processingState == .processed ? "Untitled" : processingState.label
    }
}

// MARK: - Detail

struct RambleDetail: Codable {
    let id: String
    let title: String?
    let summary: String?
    let cleanTranscript: String?
    let recordedAt: Date
    let durationSeconds: Double
    let processingState: ProcessingState
    let processingError: String?
    let sourceDevice: String
    let language: String?
    let audioURL: String?
    let segments: [Segment]
    let items: [ExtractedItem]
    let entities: [EntityRef]
    let actions: [RambleAction]
    let related: [RelatedRamble]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, segments, items, entities, actions, related, language
        case cleanTranscript = "clean_transcript"
        case recordedAt = "recorded_at"
        case durationSeconds = "duration_seconds"
        case processingState = "processing_state"
        case processingError = "processing_error"
        case sourceDevice = "source_device"
        case audioURL = "audio_url"
    }

    struct Segment: Codable, Identifiable, Hashable {
        let index: Int
        let startSeconds: Double
        let endSeconds: Double
        let text: String
        var id: Int { index }

        enum CodingKeys: String, CodingKey {
            case index
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case text
        }
    }

    struct RelatedRamble: Codable, Identifiable, Hashable {
        let id: String
        let title: String?
        let recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title
            case recordedAt = "recorded_at"
        }
    }
}

struct ExtractedItem: Codable, Identifiable, Hashable {
    let id: String
    var kind: ItemKind
    var title: String
    let body: String?
    let attributes: JSONValue
    var status: String
    let confidence: Double
    let sourceStartSeconds: Double?
    let sourceQuote: String?
    let correctedByUser: Bool
    /// Present when the item arrived from a cross-ramble endpoint such as the
    /// inbox, where a row has to be able to open the recording it came from.
    let rambleId: String?
    let rambleTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, attributes, status, confidence
        case sourceStartSeconds = "source_start_seconds"
        case sourceQuote = "source_quote"
        case correctedByUser = "corrected_by_user"
        case rambleId = "ramble_id"
        case rambleTitle = "ramble_title"
    }

    var dueDate: Date? {
        guard let raw = attributes["due_at"]?.stringValue else { return nil }
        return ISO8601DateFormatter.flexible.date(from: raw)
    }
}

struct EntityRef: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
}

// MARK: - Actions

/// The state machine an action moves through, server-side.
enum ActionState: String, Codable {
    case detected
    case awaitingConfirmation = "awaiting_confirmation"
    case approved, executing, completed, failed, cancelled

    /// Plain phrasing, written for the person rather than the pipeline.
    var label: String {
        switch self {
        case .detected, .awaitingConfirmation: "Waiting on you"
        case .approved, .executing: "Running\u{2026}"
        case .completed: "Done"
        case .failed: "Didn't go through"
        case .cancelled: "You said no"
        }
    }
}

/// Something Ramble could do off the back of a recording.
///
/// One type decodes all three places an action appears — inside a ramble, in
/// the inbox, and in the history list — so the fields those endpoints don't
/// carry are optional rather than duplicated into parallel models.
struct RambleAction: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let parameters: JSONValue
    let state: ActionState
    let confidence: Double
    let intentClass: String
    let risk: String
    let requiresConfirmation: Bool?
    let result: JSONValue?
    let error: String?
    let executedAt: Date?
    let createdAt: Date?
    /// The words this came from, and where in the audio they were said.
    let sourceQuote: String?
    let sourceStartSeconds: Double?
    /// Set by the cross-ramble endpoints, so a row can open its recording.
    let rambleId: String?
    let rambleTitle: String?
    /// "server" or "client" — whether the phone runs this through EventKit.
    let target: String?

    enum CodingKeys: String, CodingKey {
        case id, type, parameters, state, confidence, risk, result, error, target
        case intentClass = "intent_class"
        case requiresConfirmation = "requires_confirmation"
        case executedAt = "executed_at"
        case createdAt = "created_at"
        case sourceQuote = "source_quote"
        case sourceStartSeconds = "source_start_seconds"
        case rambleId = "ramble_id"
        case rambleTitle = "ramble_title"
    }

    /// Plain phrasing for the confirmation card. The user never sees a type.
    var label: String {
        switch type {
        case "calendar.create_event": "Add this to your calendar"
        case "calendar.update_event": "Change a calendar event"
        case "reminder.create": "Set a reminder"
        case "task.create": "Add a task"
        case "note.create": "Save a note"
        case "email.draft": "Draft an email"
        case "email.send": "Send an email"
        default: type
        }
    }

    /// The question form, used as the heading of a confirmation.
    var question: String {
        if let recipient, type.hasPrefix("email") {
            return "Send \(recipient) this?"
        }
        switch type {
        case "calendar.create_event": return "Put this on your calendar?"
        case "calendar.update_event": return "Change this calendar event?"
        case "reminder.create": return "Remind you about this?"
        case "task.create": return "Add this to your tasks?"
        case "note.create": return "Save this as a note?"
        case "email.draft": return "Draft this email?"
        case "email.send": return "Send this email?"
        default: return label + "?"
        }
    }

    var systemImage: String {
        switch type {
        case "calendar.create_event", "calendar.update_event": "calendar"
        case "reminder.create": "bell"
        case "task.create": "checkmark.circle"
        case "note.create": "text.alignleft"
        case "email.draft", "email.send": "envelope"
        default: "bolt"
        }
    }

    /// Where this would actually land. Named as the person would name it.
    var destination: String {
        switch type {
        case "calendar.create_event", "calendar.update_event": "Apple Calendar, on this device"
        case "reminder.create": "Apple Reminders, on this device"
        case "email.draft": "Your email drafts"
        case "email.send": "Email"
        default: "In Ramble"
        }
    }

    var recipient: String? {
        parameters["to"]?.stringValue
            ?? parameters["recipient"]?.stringValue
            ?? parameters["contact"]?.stringValue
    }

    var subject: String? {
        parameters["subject"]?.stringValue
    }

    /// The exact text that would be sent or saved, where there is one.
    var payload: String? {
        parameters["body"]?.stringValue ?? parameters["notes"]?.stringValue
    }

    var scheduledAt: Date? {
        guard let raw = parameters["starts_at"]?.stringValue ?? parameters["due_at"]?.stringValue
        else { return nil }
        return ISO8601DateFormatter.flexible.date(from: raw)
    }

    /// The one-line description shown under the action's name.
    var detail: String {
        let title = parameters["title"]?.stringValue ?? subject ?? ""
        guard let date = scheduledAt else { return title }
        let when = date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return title.isEmpty ? when : "\(title) \u{00B7} \(when)"
    }

    /// Everything the person is entitled to inspect before saying yes.
    var inspection: [(label: String, value: String)] {
        var fields: [(String, String)] = [("Where it goes", destination)]
        if let recipient { fields.append(("To", recipient)) }
        if let subject { fields.append(("Subject", subject)) }
        if let date = scheduledAt {
            fields.append(("When", date.formatted(.dateTime.weekday(.wide).month().day().hour().minute())))
        }
        if let payload, !payload.isEmpty { fields.append(("Message", payload)) }
        return fields
    }

    /// Why Ramble is asking rather than just doing it. The safety model only
    /// works if the person can see the difference between "you told me to"
    /// and "I think you might want this".
    var reason: String? {
        switch intentClass {
        case "external_communication":
            "This reaches someone outside your own data, so Ramble always asks."
        case "information":
            "It sounded like a thought rather than an instruction."
        case "intention":
            "It sounded like something you meant to do yourself."
        default:
            confidence < 0.75 ? "Ramble wasn't certain it understood this one." : nil
        }
    }

    /// The affirmative and negative wording, matched to what would happen.
    /// A generic "Confirm" hides the consequence, which is the one thing the
    /// person is being asked to weigh.
    var confirmTitle: String {
        switch type {
        case "email.send": "Yes, send"
        case "email.draft": "Yes, draft it"
        case "calendar.create_event", "calendar.update_event": "Yes, add it"
        case "reminder.create": "Yes, remind me"
        case "task.create": "Yes, add it"
        case "note.create": "Yes, save it"
        default: "Yes, do it"
        }
    }

    var declineTitle: String {
        switch type {
        case "email.send": "No, don't send"
        case "email.draft": "No, don't draft it"
        case "calendar.create_event", "calendar.update_event": "No, don't add it"
        case "reminder.create": "No, don't remind me"
        default: "No, skip it"
        }
    }

    /// Past tense for the "already taken care of" list.
    var completedLabel: String {
        switch type {
        case "calendar.create_event": "Added to your calendar."
        case "calendar.update_event": "Updated your calendar."
        case "reminder.create": "Saved a reminder."
        case "task.create": "Added a task."
        case "note.create": "Saved a note."
        case "email.draft": "Saved a draft."
        case "email.send": "Sent."
        default: "Done."
        }
    }

    var isPending: Bool { state == .awaitingConfirmation || state == .detected }
    var isDone: Bool { state == .completed }
    var isRunning: Bool { state == .approved || state == .executing }
    var isFailed: Bool { state == .failed }
    var isDeclined: Bool { state == .cancelled }
    /// True when the phone, not the server, carries this out.
    var runsOnDevice: Bool {
        target == "client" || type.hasPrefix("calendar.") || type == "reminder.create"
    }
}

/// An action the device must run itself through EventKit.
struct DeviceAction: Codable, Identifiable {
    let id: String
    let type: String
    let parameters: JSONValue
    let rambleId: String

    enum CodingKeys: String, CodingKey {
        case id, type, parameters
        case rambleId = "ramble_id"
    }
}

// MARK: - Entities

struct EntitySummary: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
    let aliases: [String]
    let mentionCount: Int
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, name, aliases
        case mentionCount = "mention_count"
        case lastSeenAt = "last_seen_at"
    }
}

struct EntityPage: Codable {
    let id: String
    let kind: String
    let name: String
    let aliases: [String]
    let overview: String?
    let mentionCount: Int
    let rambleCount: Int
    let activity: [Activity]
    let openItems: [OpenItem]
    let decisions: [Decision]
    let relatedEntities: [Related]

    enum CodingKeys: String, CodingKey {
        case id, kind, name, aliases, overview, activity, decisions
        case mentionCount = "mention_count"
        case rambleCount = "ramble_count"
        case openItems = "open_items"
        case relatedEntities = "related_entities"
    }

    struct Activity: Codable, Identifiable, Hashable {
        let id: String
        let title: String?
        let summary: String?
        let recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title, summary
            case recordedAt = "recorded_at"
        }
    }

    struct OpenItem: Codable, Identifiable, Hashable {
        let id: String
        let kind: ItemKind
        let title: String
        let rambleId: String

        enum CodingKeys: String, CodingKey {
            case id, kind, title
            case rambleId = "ramble_id"
        }
    }

    struct Decision: Codable, Identifiable, Hashable {
        let id: String
        let title: String
        let body: String?
        let rambleId: String

        enum CodingKeys: String, CodingKey {
            case id, title, body
            case rambleId = "ramble_id"
        }
    }

    struct Related: Codable, Identifiable, Hashable {
        let id: String
        let kind: String
        let name: String
    }
}

// MARK: - Search

struct SearchHit: Codable, Identifiable, Hashable {
    let rambleId: String
    let rambleTitle: String?
    let recordedAt: Date
    let sourceKind: String
    let sourceId: String?
    let content: String
    let score: Double
    let matchedBy: [String]

    var id: String { "\(sourceKind)-\(sourceId ?? content.prefix(24).description)-\(rambleId)" }
}

struct AskAnswer: Codable {
    let question: String
    let answer: String
    let citations: [Citation]
    let mocked: Bool

    struct Citation: Codable, Identifiable, Hashable {
        let rambleId: String
        let rambleTitle: String
        let quote: String
        let recordedAt: String
        let sourceKind: String

        var id: String { rambleId + quote.prefix(16) }

        /// The server sends this as a string. Parsing here rather than in the
        /// view keeps the "no usable date" case in one place.
        var date: Date? {
            ISO8601DateFormatter.flexible.date(from: recordedAt)
                ?? ISO8601DateFormatter.plain.date(from: recordedAt)
        }
    }
}

// MARK: - Inbox

struct Inbox: Codable {
    /// Everything waiting on an explicit yes, across every recording.
    let pendingActions: [RambleAction]
    /// Everything still open: tasks, reminders, commitments, follow-ups, and
    /// the questions the person asked themselves and hasn't answered.
    let openItems: [ExtractedItem]

    enum CodingKeys: String, CodingKey {
        case pendingActions = "pending_actions"
        case openItems = "open_items"
    }

    static let empty = Inbox(pendingActions: [], openItems: [])

    var isEmpty: Bool { pendingActions.isEmpty && openItems.isEmpty }

    /// Open items grouped by kind, in the order the person owes them.
    var groupedOpenItems: [(kind: ItemKind, items: [ExtractedItem])] {
        Dictionary(grouping: openItems, by: \.kind)
            .map { (kind: $0.key, items: $0.value) }
            .sorted { ($0.kind.sortRank, $0.kind.label) < ($1.kind.sortRank, $1.kind.label) }
    }
}

// MARK: - Accumulation

/// What has built up. The one thing the app never conveyed: that anything is
/// accumulating at all.
struct MemorySummary: Codable {
    let rambles: Int
    let totalSeconds: Int
    let firstRecordedAt: Date?
    let itemsByKind: [String: Int]
    let recurring: [Recurring]
    let streakDays: Int

    enum CodingKeys: String, CodingKey {
        case rambles, recurring
        case totalSeconds = "total_seconds"
        case firstRecordedAt = "first_recorded_at"
        case itemsByKind = "items_by_kind"
        case streakDays = "streak_days"
    }

    struct Recurring: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let kind: String
        let mentions: Int
    }

    /// Hours, or minutes when there are not yet hours. Saying "0 hours" to
    /// someone on their second recording is a way of telling them they have
    /// done nothing.
    var spokenLabel: String {
        if totalSeconds >= 3600 {
            let hours = Double(totalSeconds) / 3600
            return hours >= 10
                ? "\(Int(hours.rounded())) hours"
                : String(format: "%.1f hours", hours)
        }
        return "\(max(1, totalSeconds / 60)) minutes"
    }

    /// The kinds worth naming, largest first, ignoring the filler.
    var notableKinds: [(kind: ItemKind, count: Int)] {
        itemsByKind
            .compactMap { key, value -> (ItemKind, Int)? in
                guard let kind = ItemKind(rawValue: key),
                      kind != .summary, kind != .note, value > 0
                else { return nil }
                return (kind, value)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { (kind: $0.0, count: $0.1) }
    }

    var isWorthShowing: Bool { rambles >= 2 }
}

// MARK: - Account

struct Account: Codable {
    let id: String
    let email: String
    var profile: UserProfile
    let onboarded: Bool
}

enum UserProfile: String, Codable, CaseIterable {
    case student, founder, executive, creator, developer, other

    var label: String {
        switch self {
        case .student: "Student"
        case .founder: "Founder"
        case .executive: "Executive"
        case .creator: "Creator"
        case .developer: "Developer"
        case .other: "Something else"
        }
    }

    /// Shown under each choice during onboarding so the effect is honest:
    /// it changes emphasis, not what the app can do.
    var blurb: String {
        switch self {
        case .student: "Assignments, deadlines, study ideas"
        case .founder: "Customers, follow-ups, product ideas"
        case .executive: "Delegations, meetings, commitments"
        case .creator: "Content ideas, collaborations, deadlines"
        case .developer: "Bugs, decisions, technical ideas"
        case .other: "Whatever you actually talk about"
        }
    }
}

struct HealthReport: Codable {
    let status: String
    let capabilities: [String: String]

    /// True when understanding is a stand-in rather than a real model, so the
    /// UI can say so instead of passing off sample output as real.
    var isUsingMockUnderstanding: Bool { capabilities["understanding"] == "mock" }

    /// True once the server expects the device to supply embedding vectors.
    var usesOnDeviceEmbeddings: Bool {
        capabilities["embedding"]?.hasPrefix("device:") ?? false
    }

    /// Whether the server can re-transcribe with a cloud provider. The
    /// higher-accuracy setting is hidden when it cannot, rather than offering
    /// something that would fail.
    var hasCloudTranscription: Bool {
        capabilities["cloud_transcription"] == "available"
    }
}

/// One timed span of a transcript produced on the device. Mirrors the shape
/// the server's transcript endpoint expects.
struct OnDeviceTranscriptSegment: Codable, Sendable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}
