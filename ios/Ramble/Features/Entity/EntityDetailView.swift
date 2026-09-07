import SwiftUI

/// One person, company, or project: everything Ramble knows about them,
/// assembled from every recording that mentioned them.
///
/// The same page serves all three — the tint on the avatar and the wording of
/// the overview are the only things that differ.
struct EntityDetailView: View {
    let entityId: String

    @State private var page: EntityPage?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xxl) {
                if let page {
                    header(page)
                    if let overview = page.overview, !overview.isEmpty {
                        overviewBlock(overview, page: page)
                    }
                    if !page.openItems.isEmpty { openItems(page) }
                    if !page.decisions.isEmpty { decisions(page) }
                    if !page.relatedEntities.isEmpty { connected(page) }
                    if !page.activity.isEmpty { mentions(page) }
                } else if isLoading {
                    StatusNotice(message: "Gathering everything you've said\u{2026}", tone: .working)
                        .padding(.top, Theme.Metrics.xxl)
                } else if let errorMessage {
                    EmptyState(
                        title: "Couldn't load this.",
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        actionTitle: "Try again",
                        action: { Task { await load() } }
                    )
                }
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Sections

    private func header(_ page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            InitialsAvatar(name: page.name, kind: page.kind, size: 52)

            Text(page.name)
                .rambleType(Theme.Text.pageTitle)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(descriptor(page))
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)

            if !page.aliases.isEmpty {
                Text("Also \(page.aliases.joined(separator: " \u{00B7} "))")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            }
        }
        .padding(.top, Theme.Metrics.sm)
    }

    private func descriptor(_ page: EntityPage) -> String {
        let kind = switch page.kind {
        case "organization", "company": "Company"
        case "project": "Project"
        case "place": "Place"
        default: "Person"
        }
        let rambles = page.rambleCount == 1 ? "1 recording" : "\(page.rambleCount) recordings"
        return "\(kind) \u{00B7} \(rambles)"
    }

    private func overviewBlock(_ overview: String, page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text(overview)
                .rambleType(Theme.Text.reading)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Put together from what you've said, not from anywhere else.")
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
        }
    }

    private func openItems(_ page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Still open", trailing: "\(page.openItems.count)")
                .padding(.bottom, Theme.Metrics.sm)
            ForEach(page.openItems) { item in
                NavigationLink(value: AppDestination.ramble(item.rambleId)) {
                    HStack(alignment: .top, spacing: Theme.Metrics.md) {
                        Image(systemName: item.kind.systemImage)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Theme.Palette.accent(for: item.kind).text)
                            .frame(width: 18)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .rambleType(Theme.Text.body)
                                .foregroundStyle(Theme.Palette.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.kind.label)
                                .rambleType(Theme.Text.meta)
                                .foregroundStyle(Theme.Palette.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Palette.secondary.opacity(0.7))
                            .padding(.top, 4)
                    }
                    .padding(.vertical, Theme.Metrics.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Hairline() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func decisions(_ page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Decided")
                .padding(.bottom, Theme.Metrics.sm)
            ForEach(page.decisions) { decision in
                NavigationLink(value: AppDestination.ramble(decision.rambleId)) {
                    VStack(alignment: .leading, spacing: Theme.Metrics.xs) {
                        Text(decision.title)
                            .rambleType(Theme.Text.sectionSerif)
                            .foregroundStyle(Theme.Palette.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let body = decision.body, !body.isEmpty {
                            Text(body)
                                .rambleType(Theme.Text.supporting)
                                .foregroundStyle(Theme.Palette.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, Theme.Metrics.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Hairline() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func connected(_ page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            SectionHeading("Connected to")
            FlowLayout(spacing: 6) {
                ForEach(page.relatedEntities) { related in
                    NavigationLink(value: AppDestination.entity(related.id)) {
                        EntityChip(name: related.name, kind: related.kind)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func mentions(_ page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Every mention", trailing: "\(page.activity.count)")
                .padding(.bottom, Theme.Metrics.sm)
            ForEach(page.activity) { activity in
                NavigationLink(value: AppDestination.ramble(activity.id)) {
                    VStack(alignment: .leading, spacing: Theme.Metrics.xs) {
                        Text(activity.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .rambleType(Theme.Text.meta)
                            .foregroundStyle(Theme.Palette.secondary)
                        Text(activity.title ?? "Untitled")
                            .rambleType(Theme.Text.sectionSerif)
                            .foregroundStyle(Theme.Palette.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let summary = activity.summary, !summary.isEmpty {
                            Text(summary)
                                .rambleType(Theme.Text.supporting)
                                .foregroundStyle(Theme.Palette.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.vertical, Theme.Metrics.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Hairline() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        isLoading = page == nil
        defer { isLoading = false }
        do {
            page = try await APIClient.shared.entity(id: entityId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
