import SwiftUI

/// An entity page: everything Ramble knows about one person, company, or
/// project, assembled from every recording that mentioned them.
struct EntityDetailView: View {
    let entityId: String

    @State private var page: EntityPage?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let page {
                    header(page)

                    if !page.openItems.isEmpty {
                        Section(header: SectionLabel("Still open")) {
                            VStack(spacing: 6) {
                                ForEach(page.openItems) { item in
                                    NavigationLink(value: RelatedDestination(id: item.rambleId)) {
                                        SimpleRow(
                                            icon: item.kind.systemImage,
                                            tint: Theme.Palette.kind(item.kind),
                                            title: item.title
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !page.decisions.isEmpty {
                        Section(header: SectionLabel("Decisions")) {
                            VStack(spacing: 6) {
                                ForEach(page.decisions) { decision in
                                    NavigationLink(value: RelatedDestination(id: decision.rambleId)) {
                                        SimpleRow(
                                            icon: ItemKind.decision.systemImage,
                                            tint: Theme.Palette.kind(.decision),
                                            title: decision.title,
                                            subtitle: decision.body
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !page.relatedEntities.isEmpty {
                        Section(header: SectionLabel("Connected to")) {
                            FlowLayout(spacing: 6) {
                                ForEach(page.relatedEntities) { related in
                                    NavigationLink(value: related.id) {
                                        EntityChip(name: related.name)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !page.activity.isEmpty {
                        Section(header: SectionLabel("Every mention")) {
                            VStack(spacing: 6) {
                                ForEach(page.activity) { activity in
                                    NavigationLink(value: RelatedDestination(id: activity.id)) {
                                        ActivityRow(activity: activity)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if let errorMessage {
                    EmptyStateView(
                        title: "Couldn't load this",
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, 40)
        }
        .background(Theme.Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: RelatedDestination.self) { RambleDetailView(rambleId: $0.id) }
        .task { await load() }
    }

    private func header(_ page: EntityPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)

            HStack(spacing: 6) {
                Text(page.kind.capitalized)
                Text("·")
                Text(page.rambleCount == 1 ? "1 ramble" : "\(page.rambleCount) rambles")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.muted)

            if let overview = page.overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.top, 4)
            }

            if !page.aliases.isEmpty {
                Text("Also called \(page.aliases.joined(separator: ", "))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .padding(.top, 8)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            page = try await APIClient.shared.entity(id: entityId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SimpleRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.text)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.muted)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ActivityRow: View {
    let activity: EntityPage.Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(activity.recordedAt, format: .dateTime.month(.abbreviated).day())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
                Spacer()
            }
            Text(activity.title ?? "Untitled")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.text)
                .lineLimit(1)
            if let summary = activity.summary {
                Text(summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
