import SwiftUI

/// Everyone and everything that has come up. Built entirely from what was
/// said — there is nothing here to add or manage.
struct PeopleView: View {
    @Bindable var model: PeopleModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                header
                searchField
                filters
                content
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xl)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Palette.paper)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            Text("People")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("Who keeps coming up.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text("Everyone here came out of something you said.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
        }
        .padding(.top, Theme.Metrics.xxl)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Metrics.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.secondary)
            TextField("Find a name\u{2026}", text: $model.query)
                .rambleType(Theme.Text.body)
                .foregroundStyle(Theme.Palette.ink)
                .autocorrectionDisabled()
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Palette.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, Theme.Metrics.md)
        .frame(minHeight: Theme.Metrics.minimumTouchTarget)
        .background(Theme.Palette.raised)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                .strokeBorder(Theme.Palette.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous))
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Metrics.sm) {
                ForEach(PeopleModel.Filter.allCases) { option in
                    let selected = model.filter == option
                    Button { model.filter = option } label: {
                        Text(option.label)
                            .rambleType(Theme.Text.chip)
                            .foregroundStyle(selected ? Theme.Palette.onAction : Theme.Palette.secondary)
                            .padding(.horizontal, Theme.Metrics.md)
                            .padding(.vertical, 7)
                            .background(selected ? Theme.Palette.action : Theme.Palette.subtle)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: Theme.Metrics.labelRadius,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && !model.hasLoaded {
            StatusNotice(message: "Gathering names\u{2026}", tone: .working)
        } else if let error = model.errorMessage, model.entities.isEmpty {
            EmptyState(
                title: "Couldn't load this.",
                message: error,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try again",
                action: { Task { await model.refresh() } }
            )
        } else if model.visible.isEmpty && !model.query.isEmpty {
            EmptyState(
                title: "No one by that name.",
                message: "Names appear here once you mention them in a recording.",
                systemImage: "magnifyingglass"
            )
        } else if model.visible.isEmpty {
            EmptyState(
                title: "No one yet.",
                message: "Mention someone while you're talking and they'll show up here, with everything you've said about them.",
                systemImage: "person.2"
            )
        } else {
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                ForEach(model.sections, id: \.letter) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeading(section.letter)
                            .padding(.bottom, Theme.Metrics.sm)
                        ForEach(section.entities) { entity in
                            NavigationLink(value: AppDestination.entity(entity.id)) {
                                EntityRow(entity: entity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct EntityRow: View {
    let entity: EntitySummary

    var body: some View {
        HStack(spacing: Theme.Metrics.md) {
            InitialsAvatar(name: entity.name, kind: entity.kind, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Metrics.sm)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.secondary.opacity(0.7))
        }
        .padding(.vertical, Theme.Metrics.md)
        .frame(minHeight: Theme.Metrics.minimumTouchTarget)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let mentions = entity.mentionCount == 1 ? "1 mention" : "\(entity.mentionCount) mentions"
        return entity.aliases.isEmpty
            ? mentions
            : "\(mentions) \u{00B7} also \(entity.aliases.prefix(2).joined(separator: ", "))"
    }
}
