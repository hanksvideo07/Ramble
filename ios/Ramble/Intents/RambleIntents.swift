import AppIntents
import SwiftUI

/// Start a recording without opening the app first.
///
/// This is the capture path the product is built around: the person presses
/// the Action Button and talks. Assigning it there, or to a lock-screen or
/// Control Centre button, is all done through the system once this intent
/// exists.
struct StartRambleIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a ramble"
    static var description = IntentDescription(
        "Start recording immediately. Ramble works out what it was afterwards."
    )

    /// Recording needs the app in the foreground: the microphone, the timer,
    /// and the stop button all live there.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLink.shared.pending = .record
        return .result()
    }
}

/// Ask a question without opening the app and navigating first.
struct AskRambleIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Ramble"
    static var description = IntentDescription("Ask a question about everything you've said.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLink.shared.pending = .ask(question)
        return .result()
    }
}

struct RambleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRambleIntent(),
            phrases: [
                "Start a \(.applicationName)",
                "New \(.applicationName)",
                "\(.applicationName) this",
            ],
            shortTitle: "Start a ramble",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: AskRambleIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Ramble",
            systemImageName: "magnifyingglass"
        )
    }
}

/// Routes an incoming intent or URL to a screen.
///
/// Shared by App Intents, the `ramble://` URL scheme, and (later) widgets and
/// notifications, so every entry point lands the same way.
@MainActor
@Observable
final class DeepLink {
    static let shared = DeepLink()

    enum Destination: Equatable {
        case record
        case compose(paste: Bool)
        case search
        case ask(String)
        case ramble(String)
        case entity(String)
    }

    /// Consumed by the root view the next time it can act on it.
    var pending: Destination?

    private init() {
        #if DEBUG
        // Lets a local build be launched straight onto a screen, which is how
        // the simulator can be driven without tapping:
        //   SIMCTL_CHILD_RAMBLE_OPEN=ramble://search xcrun simctl launch …
        if let raw = ProcessInfo.processInfo.environment["RAMBLE_OPEN"],
           let url = URL(string: raw) {
            handle(url)
        }
        #endif
    }

    /// Parses `ramble://record`, `ramble://compose`, `ramble://search`, `ramble://ask?q=…`,
    /// `ramble://ramble/<id>`, and `ramble://entity/<id>`.
    func handle(_ url: URL) {
        guard url.scheme == "ramble" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        switch url.host() {
        case "record":
            pending = .record
        case "compose", "write":
            // ?paste=1 comes from the widget's Paste button, which means "open
            // this with what I just copied already in it".
            let wantsPaste = components?.queryItems?.contains { $0.name == "paste" } ?? false
            pending = .compose(paste: wantsPaste)
        case "search":
            pending = .search
        case "ask":
            let question = components?.queryItems?.first { $0.name == "q" }?.value
            pending = question.map { .ask($0) } ?? .search
        case "ramble":
            // ramble://ramble/<uuid>
            if let id = url.pathComponents.first(where: { $0 != "/" }) {
                pending = .ramble(id)
            }
        case "entity":
            // ramble://entity/<uuid>
            if let id = url.pathComponents.first(where: { $0 != "/" }) {
                pending = .entity(id)
            }
        default:
            break
        }
    }
}
