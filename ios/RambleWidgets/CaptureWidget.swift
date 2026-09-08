import SwiftUI
import WidgetKit

/// The Home Screen widget: talk, type, paste.
///
/// Three ways in, because on the Home Screen there is room for a choice and the
/// three are genuinely different intentions — say it, write it, or keep
/// something you just read. Talking is still the largest and the greenest.
///
/// Each region is a Link with its own URL. Where the system honours per-region
/// links the three route separately; where it does not, the whole widget falls
/// back to widgetURL and starts recording — which is the primary action anyway,
/// so the degraded case is still the right one.
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.ramble.widget.capture", provider: TalkProvider()) { _ in
            CaptureView()
                .widgetURL(URL(string: "ramble://record"))
                .containerBackground(for: .widget) { WidgetPalette.paper }
        }
        .configurationDisplayName("Capture")
        .description("Talk, type, or paste something you want to keep.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct CaptureView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemMedium {
            HStack(spacing: 10) {
                talk
                VStack(spacing: 8) {
                    action("Type", systemImage: "square.and.pencil", url: "ramble://compose")
                    action("Paste", systemImage: "doc.on.clipboard", url: "ramble://compose?paste=1")
                }
                .frame(width: 108)
            }
        } else {
            VStack(spacing: 8) {
                talk
                HStack(spacing: 6) {
                    compact("Type", systemImage: "square.and.pencil", url: "ramble://compose")
                    compact("Paste", systemImage: "doc.on.clipboard", url: "ramble://compose?paste=1")
                }
            }
        }
    }

    /// The one that matters. Sized and coloured so there is no doubt which of
    /// the three the widget is for.
    private var talk: some View {
        Link(destination: URL(string: "ramble://record")!) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(WidgetPalette.halo)
                    Circle().fill(WidgetPalette.action).padding(6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: family == .systemMedium ? 22 : 18, weight: .medium))
                        .foregroundStyle(WidgetPalette.onAction)
                }
                .frame(
                    width: family == .systemMedium ? 76 : 58,
                    height: family == .systemMedium ? 76 : 58
                )
                Text("Just talk.")
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(WidgetPalette.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func action(_ title: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 7) {
                Image(systemName: systemImage).font(.system(size: 13))
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(WidgetPalette.ink)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(WidgetPalette.divider, lineWidth: 1)
            )
        }
    }

    private func compact(_ title: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(WidgetPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(WidgetPalette.divider, lineWidth: 1)
            )
        }
    }
}
