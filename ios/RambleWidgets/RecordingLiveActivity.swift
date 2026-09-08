import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity shown while a recording is running.
///
/// A long ramble is invisible once the screen locks, which is exactly when
/// someone is most likely to be walking and talking. This puts the elapsed time
/// on the Lock Screen and in the Dynamic Island, and gives a way back to the
/// app to stop it.
///
/// The timer is rendered from a start date rather than pushed a new value each
/// second. A Live Activity updated once a second would be throttled by the
/// system almost immediately; `Text(_:style:.timer)` counts on its own.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 14) {
                RecordingDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetPalette.secondary)
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 26, weight: .regular, design: .serif))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.ink)
                }
                Spacer()
                Link(destination: URL(string: "ramble://record")!) {
                    Text("Stop")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WidgetPalette.onAction)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(WidgetPalette.action)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .activityBackgroundTint(WidgetPalette.paper)
            .activitySystemActionForegroundColor(WidgetPalette.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingDot()
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "ramble://record")!) {
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(WidgetPalette.action, in: Capsule())
                            .foregroundStyle(WidgetPalette.onAction)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(WidgetPalette.action)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(WidgetPalette.ink)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(WidgetPalette.action)
            }
            .widgetURL(URL(string: "ramble://record"))
        }
    }
}

/// The one piece of motion. A steady pulse says "still listening" in a way a
/// static dot cannot, and it is the only animation a Live Activity gets.
private struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(WidgetPalette.action)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .stroke(WidgetPalette.action.opacity(0.35), lineWidth: 6)
                    .scaleEffect(1.6)
            )
    }
}
