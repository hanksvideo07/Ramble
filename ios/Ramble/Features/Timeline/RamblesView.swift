import SwiftUI

/// The history. Newest first, grouped by day, with nothing on it allowed to
/// compete with the record button below.
struct RamblesView: View {
    @Bindable var model: TimelineModel
    let startRecording: () -> Void

    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inbox = InboxModel.shared
    @State private var queue = CaptureQueue.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                notices
                content
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task {
            await model.load()
            await inbox.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                Text("ramble")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Your thoughts.")
                    .rambleType(Theme.Text.screenTitle)
                    .foregroundStyle(Theme.Palette.ink)
            }
            Spacer()
            NavigationLink(value: AppDestination.activity) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(
                        width: Theme.Metrics.minimumTouchTarget,
                        height: Theme.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What Ramble did")

            NavigationLink(value: AppDestination.settings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(
                        width: Theme.Metrics.minimumTouchTarget,
                        height: Theme.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .padding(.trailing, -Theme.Metrics.md)
        }
        .padding(.top, Theme.Metrics.lg)
        .padding(.bottom, Theme.Metrics.xl)
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: Theme.Metrics.sm) {
            if let waiting = inbox.needsYouLabel {
                NavigationLink(value: AppDestination.inbox) {
                    HStack(spacing: Theme.Metrics.md) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(waiting)
                                .rambleType(Theme.Text.bodyStrong)
                            Text("Nothing happens until you say so.")
                                .rambleType(Theme.Text.meta)
                                .foregroundStyle(Theme.Palette.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.secondary)
                    }
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(Theme.Metrics.md)
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                    .background(Theme.Palette.approvalSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                            .strokeBorder(Theme.Palette.approvalBorder, lineWidth: 1)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            if !queue.isOnline && queue.hasPending {
                StatusNotice(
                    message: queue.pending.count == 1
                        ? "1 recording is waiting to send"
                        : "\(queue.pending.count) recordings are waiting to send",
                    detail: "They're safe on your phone and will go up by themselves.",
                    systemImage: "wifi.slash"
                )
            }

            if session.isSampleMode {
                StatusNotice(
                    message: "Understanding is a stand-in right now",
                    detail: "The server has no model configured, so titles and extracted items are simulated. Your recordings and transcripts are real.",
                    systemImage: "flask"
                )
            }

            // A failed request while rows are already on screen must not wipe
            // them; it says so above what is already there.
            if let error = model.errorMessage, !model.isEmpty {
                StatusNotice(
                    message: "Couldn't refresh",
                    detail: error,
                    tone: .warning,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    action: { Task { await model.refresh() } }
                )
            }
        }
        .padding(.bottom, model.isEmpty ? 0 : Theme.Metrics.lg)
    }

    // MARK: - History

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.isEmpty && model.errorMessage == nil {
            StatusNotice(message: "Opening your notebook\u{2026}", tone: .working)
        } else if model.isEmpty, let error = model.errorMessage {
            EmptyState(
                title: "Couldn't load your rambles.",
                message: error,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try again",
                action: { Task { await model.refresh() } }
            )
        } else if model.isEmpty {
            // Showing rather than telling. An empty state that states a fact
            // and stops teaches nothing; this is the whole product in one
            // block, and it is honestly labelled as an example.
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                Text("Nothing here yet.")
                    .rambleType(Theme.Text.recordingTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Text("Press the green button and talk. Don't sort it, don't title it \u{2014} that's the whole idea. Here's what one recording turns into:")
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WelcomeExtraction()
                Text("An example, not one of yours.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            }
            .padding(.top, Theme.Metrics.lg)
        } else {
            if let summary = model.summary, summary.isWorthShowing {
                MemoryStrip(summary: summary)
            }

            ForEach(model.days) { day in
                DayHeading(label: day.label, count: day.entries.count)
                ForEach(day.entries) { entry in
                    row(for: entry)
                }
            }
            // A recording that finishes processing while you're looking at the
            // list should ease in rather than snap.
            .animation(reduceMotion ? nil : .ramble(0.3), value: model.entryCount)

            if model.canLoadMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Metrics.xl)
                    .task { await model.loadMore() }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: TimelineEntry) -> some View {
        switch entry {
        case .local(let capture, let state):
            LocalRecordingRow(capture: capture, state: state) { queue.sync() }
                .overlay(alignment: .bottom) { Hairline().padding(.bottom, Theme.Metrics.md) }
        case .remote(let card):
            NavigationLink(value: AppDestination.ramble(card.id)) {
                RecordingRow(ramble: card)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { Hairline().padding(.bottom, Theme.Metrics.md) }
            .transition(
                reduceMotion || !model.arriving.contains(card.id)
                    ? .identity
                    : .opacity.combined(with: .offset(y: -8))
            )
        }
    }
}

/// A day in the history. Serif, because it is a heading in a notebook and not
/// a table's column label.
private struct DayHeading: View {
    let label: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .rambleType(Theme.Text.sectionSerif)
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
            Text(count == 1 ? "1 recording" : "\(count) recordings")
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
        }
        .padding(.top, Theme.Metrics.sm)
        .padding(.bottom, Theme.Metrics.lg)
        .accessibilityAddTraits(.isHeader)
    }
}
