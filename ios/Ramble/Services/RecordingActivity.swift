import ActivityKit
import Foundation

/// Starts and stops the Live Activity that shows a recording in progress.
///
/// Wrapped rather than called directly from the recorder for two reasons. A
/// Live Activity is a genuine failure point — the person can disable them
/// system-wide, there is a cap on how many an app may run, and none of that
/// should be able to interrupt a recording. And the recorder should not have to
/// know that ActivityKit exists.
///
/// So every call here is best-effort and silent. A recording that captures
/// perfectly but shows nothing on the Lock Screen is a small disappointment; a
/// recording that fails because the Lock Screen widget could not start is a
/// lost thought.
@MainActor
enum RecordingActivity {
    private static var current: Activity<RecordingActivityAttributes>?

    static func start(at startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard current == nil else { return }

        do {
            current = try Activity.request(
                attributes: RecordingActivityAttributes(),
                content: ActivityContent(
                    state: .init(startedAt: startedAt, level: 0),
                    // No staleness date: a recording is over when the app says
                    // so, not on a timer the app cannot predict.
                    staleDate: nil
                )
            )
        } catch {
            // Activities disabled, or the system's limit reached. Neither is
            // worth telling someone about mid-thought.
        }
    }

    /// Nudges the level. Called rarely on purpose — an activity updated at
    /// frame rate is throttled by the system almost immediately, and the timer
    /// on screen counts by itself from the start date.
    static func update(level: Double, startedAt: Date) {
        guard let current else { return }
        Task {
            await current.update(
                ActivityContent(state: .init(startedAt: startedAt, level: level), staleDate: nil)
            )
        }
    }

    static func stop() {
        guard let activity = current else { return }
        current = nil
        Task {
            // .immediate: the recording has stopped, so leaving a live timer on
            // the Lock Screen would be actively misleading.
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
