import SwiftUI

/// Search and Ask in one place.
///
/// A short query is a lookup; a question is something to answer. Rather than
/// making the person choose a mode, the screen offers both and lets the shape
/// of what they typed decide which is offered first.
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = SearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchField

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if model.isWorking {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            } else if let answer = model.answer {
                                AnswerCard(answer: answer)
                            }

                            if !model.hits.isEmpty {
                                if model.answer != nil {
                                    SectionLabel("Where this came from")
                                        .padding(.horizontal, Theme.Metrics.screenPadding)
                                }
                                ForEach(model.hits) { hit in
                                    NavigationLink(value: hit.rambleId) {
                                        SearchHitRow(hit: hit)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, Theme.Metrics.screenPadding)
                                }
                            }

                            if model.hasSearched && model.hits.isEmpty && !model.isWorking && model.answer == nil {
                                EmptyStateView(
                                    title: "Nothing yet",
                                    message: "Nothing you've said matches that.",
                                    systemImage: "magnifyingglass"
                                )
                            }

                            if !model.hasSearched {
                                SuggestionList { model.query = $0; model.run() }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            .navigationDestination(for: String.self) { RambleDetailView(rambleId: $0) }
        }
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.muted)
            TextField("Search or ask a question", text: $model.query)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { model.run() }
            if !model.query.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.muted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, 8)
    }
}

/// The synthesized answer, with its sources attached. The guide insists the
/// person can always see where an answer came from.
private struct AnswerCard: View {
    let answer: AskAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Answer")
                Spacer()
                if answer.mocked { MockBadge() }
            }
            Text(answer.answer)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.text)
                .textSelection(.enabled)
        }
        .rambleCard()
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(hit.rambleTitle ?? "Untitled")
                    .font(Theme.Typography.secondary.weight(.medium))
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                Spacer()
                Text(hit.recordedAt, format: .dateTime.month(.abbreviated).day())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text(hit.content)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rambleCard()
    }
}

/// Example questions, shown before the first search. They teach what the
/// system can actually do better than an explanation would.
private struct SuggestionList: View {
    let pick: (String) -> Void

    private let suggestions = [
        "What did I decide about pricing?",
        "What have I been thinking about lately?",
        "What did I promise this week?",
        "Ideas I've had about onboarding",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Try asking")
            ForEach(suggestions, id: \.self) { suggestion in
                Button { pick(suggestion) } label: {
                    HStack {
                        Text(suggestion)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.text)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, 8)
    }
}
