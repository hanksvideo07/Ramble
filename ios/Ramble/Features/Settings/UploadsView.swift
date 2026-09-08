import SwiftUI

/// What is still on the phone, and — the part that matters — whether the
/// system is actually moving it while the app is closed.
///
/// "Sending…" looks identical whether a transfer is genuinely in flight or
/// quietly stalled, which makes the question unanswerable by watching. So this
/// shows the timestamp of the last byte that moved and whether the app was on
/// screen when it did. An entry that advanced while the app was backgrounded is
/// the proof, and there is no way to fake it.
struct UploadsView: View {
    @State private var queue = CaptureQueue.shared
    @State private var uploader = BackgroundUploader.shared
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                header

                if queue.pending.isEmpty {
                    EmptyState(
                        title: "Everything's uploaded.",
                        message: "Nothing is waiting. Recordings appear here between stopping and the server having them.",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    ForEach(queue.pending) { capture in
                        UploadRow(
                            capture: capture,
                            state: queue.state(for: capture),
                            progress: uploader.progress[capture.id],
                            now: now
                        )
                    }

                    Button("Try again now") { queue.sync() }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, Theme.Metrics.sm)
                }

                howToTest
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text("Uploads")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("Still on your phone.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text("Recordings are safe here whether or not they've sent. Nothing is ever deleted from the phone until the server confirms it has them.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Metrics.sm)
    }

    /// Written here rather than left to a support page, because the test is
    /// genuinely counter-intuitive: force-quitting is the one thing that
    /// stops it working, and it is the first thing anyone tries.
    private var howToTest: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            SectionHeading("Checking it works in the background")
            Text("Record something long, then **lock the phone** — don't swipe the app away. Come back in a minute and look at the line above: if it says the last activity happened while the app was closed, the system carried it for you.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Swiping an app away in the app switcher tells iOS you want it stopped, and it stops carrying its transfers too. That's the system working as designed, not Ramble failing.")
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Metrics.lg)
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct UploadRow: View {
    let capture: CaptureQueue.PendingCapture
    let state: UploadState
    let progress: BackgroundUploader.Progress?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            HStack {
                Text(capture.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .rambleType(Theme.Text.bodyStrong)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer()
                Text(capture.duration.durationLabel)
                    .rambleType(Theme.Text.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.secondary)
            }

            Text(state.label)
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(
                    { if case .failed = state { Theme.Palette.warning } else { Theme.Palette.secondary } }()
                )

            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Palette.divider).frame(height: 3)
                        Capsule()
                            .fill(Theme.Palette.action)
                            .frame(width: geometry.size.width * progress.fraction, height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(bytes(progress.bytesSent)) of \(bytes(progress.totalBytes)) sent")
                    // The line that answers the question.
                    Text(activityLine(progress))
                        .foregroundStyle(
                            progress.lastActivityInForeground
                                ? Theme.Palette.secondary
                                : Theme.Palette.action
                        )
                }
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, Theme.Metrics.md)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func activityLine(_ progress: BackgroundUploader.Progress) -> String {
        let ago = Int(now.timeIntervalSince(progress.lastActivityAt))
        let when = ago < 2 ? "just now" : ago < 60 ? "\(ago)s ago" : "\(ago / 60)m ago"
        return progress.lastActivityInForeground
            ? "Last activity \(when), with the app open"
            : "Last activity \(when), while the app was closed \u{2713}"
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
