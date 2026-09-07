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

enum ProcessingState: String, Codable {
    case awaitingUpload = "awaiting_upload"
    case uploaded, transcribing, transcribed, understanding, embedding, processed, failed

    var isTerminal: Bool { self == .processed || self == .failed }

    /// What the user sees on a card while work is still happening.
    var label: String {
        switch self {
        case .awaitingUpload: "Waiting for a connection"
        case .uploaded, .transcribing: "Transcribing"
        case .transcribed, .understanding: "Making sense of it"
        case .embedding: "Almost done"
        case .processed: "Ready"
        case .failed: "Couldn't finish"
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

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, attributes, status, confidence
        case sourceStartSeconds = "source_start_seconds"
        case sourceQuote = "source_quote"
        case correctedByUser = "corrected_by_user"
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

struct RambleAction: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let parameters: JSONValue
    let state: String
    let confidence: Double
    let intentClass: String
    let risk: String
    let requiresConfirmation: Bool
    let result: JSONValue?
    let error: String?
    let executedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, type, parameters, state, confidence, risk, result, error
        case intentClass = "intent_class"
        case requiresConfirmation = "requires_confirmation"
        case executedAt = "executed_at"
    }

    /// Plain phrasing for the confirmation card. The user never sees an action type.
    var label: String {
        switch type {
        case "calendar.create_event": "Add to calendar"
        case "calendar.update_event": "Change a calendar event"
        case "reminder.create": "Add a reminder"
        case "task.create": "Add a task"
        case "note.create": "Save a note"
        case "email.draft": "Draft an email"
        case "email.send": "Send an email"
        default: type
        }
    }

    var systemImage: String {
        switch type {
        case "calendar.create_event", "calendar.update_event": "calendar"
        case "reminder.create": "bell"
        case "task.create": "checkmark.circle"
        case "email.draft", "email.send": "envelope"
        default: "bolt"
        }
    }

    /// The one-line description shown under the action's name.
    var detail: String {
        let title = parameters["title"]?.stringValue ?? parameters["subject"]?.stringValue ?? ""
        guard let when = parameters["starts_at"]?.stringValue ?? parameters["due_at"]?.stringValue,
              let date = ISO8601DateFormatter.flexible.date(from: when)
        else { return title }
        return title.isEmpty
            ? date.formatted(.dateTime.weekday(.wide).hour().minute())
            : "\(title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    var isPending: Bool { state == "awaiting_confirmation" }
    var isDone: Bool { state == "completed" }
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
    }
}

// MARK: - Inbox

struct Inbox: Codable {
    let pendingActions: [PendingAction]
    let openItems: [ExtractedItem]

    enum CodingKeys: String, CodingKey {
        case pendingActions = "pending_actions"
        case openItems = "open_items"
    }

    struct PendingAction: Codable, Identifiable, Hashable {
        let id: String
        let type: String
        let parameters: JSONValue
        let confidence: Double
        let intentClass: String
        let risk: String
        let rambleId: String
        let rambleTitle: String?

        enum CodingKeys: String, CodingKey {
            case id, type, parameters, confidence, risk
            case intentClass = "intent_class"
            case rambleId = "ramble_id"
            case rambleTitle = "ramble_title"
        }
    }
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
