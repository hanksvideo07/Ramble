import SwiftUI

/// Everything waiting on you, gathered from every recording.
///
/// Until this screen existed, approving something meant remembering which
/// recording it came from and opening that one. The server has always known
/// the whole set; this is where the person finally sees it.
struct InboxView: View {
    @State private var model = InboxModel.shared
    @Environment(Session.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xxl) {
                header

                if let error = model.errorMessage, model.inbox.isEmpty {
                    StatusNotice(
                        message: "Couldn't load what's waiting",
                        detail: error,
                        tone: .warning,
                        systemImage: "exclamationmark.triangle",
                        actionTitle: "Retry",
                        action: { Task { await model.refresh() } }
                    )
                } else if model.isLoading && !model.hasLoaded {
                    StatusNotice(message: "Gathering what's waiting\u{2026}", tone: .working)
                } else if model.inbox.isEmpty {
                    EmptyState(
                        title: "Nothing is waiting on you.",
                        message: "Approvals and open loops from all your recordings collect here. Right now there aren't any.",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    if !model.inbox.pendingActions.isEmpty { approvals }
                    if !model.inbox.openItems.isEmpty { openLoops }
                }
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xxl)
        }
        .background(Theme.Palette.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text("Waiting on you")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("Your yes.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text("Nothing here happens until you say so.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
        }
        .padding(.top, Theme.Metrics.sm)
    }

    private var approvals: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading("Needs your yes", trailing: "\(model.pendingCount)")
                if model.bulkApprovable.count > 1 {
                    Button("Approve \(model.bulkApprovable.count)") {
                        Task { await model.approveAll(model.bulkApprovable) }
                    }
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                }
            }

            if model.bulkApprovable.count < model.pendingCount {
                Text("Anything that reaches another person is left out of that \u{2014} those get an individual yes.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.inbox.pendingActions) { action in
                ApprovalCard(
                    action: action,
                    showsSource: true,
                    isSubmitting: model.isSubmitting(action),
                    outcome: model.outcome(for: action),
                    respond: { approve in
                        Task { await model.respond(to: action, approve: approve) }
                    }
                )
            }
        }
    }

    private var openLoops: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
            ForEach(model.inbox.groupedOpenItems, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(group.kind.pluralLabel, trailing: "\(group.items.count)")
                        .padding(.bottom, Theme.Metrics.sm)
                    ForEach(group.items) { item in
                        OpenLoopRow(
                            item: item,
                            complete: { Task { await model.complete(item) } }
                        )
                    }
                }
            }
        }
    }
}

/// One open task, commitment, or question. Tappable through to the recording
/// it came from, with a single control to close it out.
private struct OpenLoopRow: View {
    let item: ExtractedItem
    let complete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.md) {
            Button(action: complete) {
                Image(systemName: "circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(
                        width: Theme.Metrics.minimumTouchTarget,
                        height: Theme.Metrics.minimumTouchTarget,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(item.title) done")

            rowBody.modifier(LinkToRamble(rambleId: item.rambleId))
        }
        .padding(.bottom, Theme.Metrics.md)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.xs) {
            Text(item.title)
                .rambleType(Theme.Text.body)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let due = item.dueDate {
                    Text(due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    Text("\u{00B7}")
                }
                if let title = item.rambleTitle {
                    Text(title).lineLimit(1)
                }
            }
            .rambleType(Theme.Text.meta)
            .foregroundStyle(Theme.Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 11)
    }
}

/// Makes a row open its recording, but only when there is one to open — a
/// link that goes nowhere is worse than no link.
private struct LinkToRamble: ViewModifier {
    let rambleId: String?

    func body(content: Content) -> some View {
        if let rambleId {
            NavigationLink(value: AppDestination.ramble(rambleId)) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}
