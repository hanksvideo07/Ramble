import AppIntents
import SwiftUI
import WidgetKit

/// The Control Centre button, which is also the Action Button.
///
/// Worth stating because it is not obvious: since iOS 18 the Action Button can
/// be assigned any Control, so this single declaration covers both. Settings →
/// Action Button → Controls → Ramble puts it on the side of the phone; a swipe
/// down from the top-right puts it in Control Centre. One thing to build, two
/// places it lands.
///
/// A Control is not a widget. It has no timeline and does not refresh — it is a
/// button with a symbol, which is exactly right for the only action that
/// matters here.
struct RambleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.ramble.control.talk") {
            ControlWidgetButton(action: StartRambleControlIntent()) {
                Label("Ramble", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to Ramble")
        .description("Start recording. Nothing to choose first.")
    }
}

/// Opens the app and starts recording.
///
/// Declared here rather than reusing the app's own StartRambleIntent because
/// an extension is a separate module and cannot see it. It carries no
/// behaviour of its own — opening the app to the recording screen is the whole
/// of it, since the microphone, the timer and the stop button all live there.
struct StartRambleControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a ramble"
    static var description = IntentDescription("Start recording immediately.")

    /// Recording needs the app in the foreground. Without this the control
    /// would appear to do nothing at all.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        // The URL is the app's own capture route, the same one the widgets and
        // the Shortcuts action use, so every entry point lands identically.
        .result(opensIntent: OpenURLIntent(URL(string: "ramble://record")!))
    }
}
