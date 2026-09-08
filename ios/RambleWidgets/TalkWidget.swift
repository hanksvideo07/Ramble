import SwiftUI
import WidgetKit

/// The Lock Screen widget. One thing only: talk.
///
/// A Lock Screen accessory is glanced at and pressed without looking, often
/// one-handed and often mid-thought. Offering a choice there would defeat the
/// point — the whole promise is that capturing something costs no decision.
/// So this is a single tap target that starts recording, and nothing else.
struct TalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.ramble.widget.talk", provider: TalkProvider()) { _ in
            TalkView()
                .widgetURL(URL(string: "ramble://record"))
                .containerBackground(for: .widget) { WidgetPalette.paper }
        }
        .configurationDisplayName("Talk")
        .description("One press and you're recording.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct TalkEntry: TimelineEntry {
    let date: Date
}

struct TalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> TalkEntry { TalkEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (TalkEntry) -> Void) {
        completion(TalkEntry(date: .now))
    }

    /// Nothing here changes, so the timeline is one entry that never expires.
    /// A widget that asks to be refreshed for no reason spends someone's
    /// battery to redraw the same microphone.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TalkEntry>) -> Void) {
        completion(Timeline(entries: [TalkEntry(date: .now)], policy: .never))
    }
}

private struct TalkView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Ramble", systemImage: "mic")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ramble").font(.system(size: 15, weight: .semibold, design: .serif))
                    Text("Just talk.").font(.system(size: 12, design: .serif)).italic()
                }
                Spacer()
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.system(size: 20, weight: .medium))
            }
        }
    }
}
