import SwiftUI

/// Search and Ask in one place.
///
/// A short query is a lookup; a question is something to answer. Rather than
/// making the person pick a mode, the screen offers both and lets the shape of
/// what they typed decide which they get.
struct AskView: View {
    @Bindable var model: AskModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                header
                results
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xl)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Palette.paper)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { field }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            Text("Ask")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("Ask the pages.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text("It's in there somewhere.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
        }
        .padding(.top, Theme.Metrics.xxl)
    }

    // MARK: - The input

    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Metrics.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.secondary)

                TextField("Search or ask anything\u{2026}", text: $model.query)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { model.run() }

                if !model.query.isEmpty {
                    Button { model.clear() } label: {
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
            .screenPadding()
            .padding(.vertical, Theme.Metrics.md)
        }
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Theme.Palette.paper.opacity(0), Theme.Palette.paper],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20)
                Theme.Palette.paper
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        switch model.phase {
        case .idle:
            suggestions

        case .searching:
            StatusNotice(message: "Looking through what you've said\u{2026}", tone: .working)

        case .thinking:
            StatusNotice(
                message: "Reading back through your recordings\u{2026}",
                detail: "Answers only ever come from things you actually said.",
                tone: .working
            )

        case .matches:
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                SectionHeading("Matching recordings", trailing: "\(model.hits.count)")
                hitList
            }

        case .answered:
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                if let question = model.askedQuestion { askedLine(question) }
                if let answer = model.answer { AnswerBlock(answer: answer) }
                sources
            }

        case .noResults:
            EmptyState(
                title: "Nothing in there about that.",
                message: "Ramble only answers from recordings you've actually made \u{2014} it won't invent one. Try different words, or talk about it and ask again.",
                systemImage: "magnifyingglass"
            )

        case .failed(let message):
            EmptyState(
                title: "That didn't go through.",
                message: message,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try again",
                action: { model.retry() }
            )
        }
    }

    private func askedLine(_ question: String) -> some View {
        Text(question)
            .rambleType(Theme.Text.sectionSerif)
            .foregroundStyle(Theme.Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Metrics.lg)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
    }

    /// Where the answer came from.
    ///
    /// The model's own citations when it gave any, because those are the
    /// passages it actually drew on. The retrieved set is the fallback, and is
    /// labelled differently so the two are never confused.
    @ViewBuilder
    private var sources: some View {
        if let citations = model.answer?.citations, !citations.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                SectionHeading("Where this came from", trailing: "\(citations.count)")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(citations) { citation in
                        NavigationLink(
                            value: AppDestination.rambleQuoting(
                                id: citation.rambleId,
                                quote: citation.quote
                            )
                        ) {
                            CitationRow(
                                title: citation.rambleTitle,
                                recordedAt: citation.date,
                                quote: citation.quote,
                                kind: citation.sourceKind
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if !model.hits.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                SectionHeading("Recordings that came close")
                hitList
            }
        }
    }

    private var hitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.hits) { hit in
                NavigationLink(
                    value: AppDestination.rambleQuoting(id: hit.rambleId, quote: hit.content)
                ) {
                    CitationRow(
                        title: hit.rambleTitle ?? "Untitled",
                        recordedAt: hit.recordedAt,
                        quote: hit.content,
                        kind: hit.sourceKind
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Try asking")
                .padding(.bottom, Theme.Metrics.sm)
            ForEach(model.suggestions, id: \.self) { suggestion in
                Button {
                    model.submit(suggestion)
                    focused = false
                } label: {
                    HStack(spacing: Theme.Metrics.md) {
                        Text(suggestion)
                            .rambleType(Theme.Text.body)
                            .foregroundStyle(Theme.Palette.ink)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.secondary)
                    }
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                    .padding(.vertical, Theme.Metrics.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Hairline() }
            }
        }
    }
}

/// The synthesized answer. Set in the reading serif because it is prose, and
/// always accompanied by where it came from.
private struct AnswerBlock: View {
    let answer: AskAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            if answer.mocked {
                SampleBadge(text: "Simulated answer")
            }
            Text(answer.answer)
                .rambleType(Theme.Text.answer)
                .foregroundStyle(Theme.Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if answer.mocked {
                Text("No answering model is configured on the server, so this was assembled by a stand-in rather than written from your recordings.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One recording an answer drew on, or one search result. Opens the recording
/// at the passage it quotes.
struct CitationRow: View {
    let title: String
    /// Nil when the source didn't carry a usable date; the row simply omits it
    /// rather than inventing one.
    let recordedAt: Date?
    let quote: String
    var kind: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            HStack(spacing: 6) {
                Text(title)
                    .rambleType(Theme.Text.bodyStrong)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Metrics.sm)
                if let recordedAt {
                    Text(recordedAt, format: .dateTime.month(.abbreviated).day())
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(Theme.Palette.secondary)
                }
            }

            Text(quote)
                .rambleType(Theme.Text.quote)
                .foregroundStyle(Theme.Palette.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let kind, let itemKind = ItemKind(rawValue: kind) {
                ExtractionLabel(kind: itemKind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Metrics.lg)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Hairline() }
    }
}
