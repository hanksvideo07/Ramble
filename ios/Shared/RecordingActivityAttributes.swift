import ActivityKit
import Foundation

/// Shared between the app and its widget extension, which is why it lives in
/// its own directory belonging to both targets: ActivityKit requires the
/// attributes type to be literally the same type on each side.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When capture began. The Live Activity renders a live timer from
        /// this rather than being pushed a new value every second — a widget
        /// that updated once a second would be throttled into uselessness.
        var startedAt: Date
        /// A coarse level for the bars. Updated occasionally, not per frame.
        var level: Double
    }

    /// Nothing varies per recording that the Lock Screen needs, but
    /// ActivityAttributes requires a type, and a name is the honest thing to
    /// put here if this ever shows one.
    var name: String = "Ramble"
}
