import SwiftUI

/// Everything one recording became, in the order it matters: what it was
/// about, what is waiting on you, what already happened, what was extracted,
/// who it involved, and the words it all came from.
struct RambleDetailView: View {
    let rambleId: String
    /// A passage a citation asked for. Opens the transcript at those words.
    var highlighting: String?

    @State private var model: RambleDetailModel
    @State private var player: AudioPlayerModel
    @State private var editingItem: ExtractedItem?
    @State private var confirmDelete = false
    @State private var isEditingTitle = false
    @Environment(\.dismiss) private var dismiss
    @Environment(Session.self) private var session

    init(rambleId: String, highlighting: String? = nil) {
        self.rambleId = rambleId
        self.highlighting = highlighting
        _model = State(initialValue: RambleDetailModel(rambleId: rambleId))
        _player = State(initialValue: AudioPlayerModel(duration: 0))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xxl) {
                if let detail = model.detail {
                    header(detail)

                    if detail.processingState == .failed {
                        StatusNotice(
                            message: "This one didn't finish processing",
                            detail: [detail.processingError, "Your recording and transcript are safe."]
                                .compactMap { $0 }.joined(separator: " "),
                            tone: .warning,
                            systemImage: "exclamationmark.triangle",
                            actionTitle: "Try again",
                            action: { Task { await model.reprocess() } }
                        )
                    } else if !detail.processingState.isTerminal {
                        StatusNotice(
                            message: detail.processingState.label,
                            detail: detail.processingState.detail,
                            tone: .working
                        )
                    }

                    if let error = model.lastActionError {
                        StatusNotice(
                            message: "That didn't save",
                            detail: error,
                            tone: .warning,
                            systemImage: "exclamationmark.triangle"
                        )
                    }

                    approvals
                    completed
                    items
                    entities(detail)
                    transcript(detail)
                    related(detail)
                } else if model.isLoading {
                    StatusNotice(message: "Opening\u{2026}", tone: .working)
                        .padding(.top, Theme.Metrics.xxl)
                } else if let error = model.errorMessage {
                    EmptyState(
                        title: "Couldn't load this.",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        actionTitle: "Try again",
                        action: { Task { await model.load() } }
                    )
                }
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { menu }
        .sheet(isPresented: $isEditingTitle) {
            if let detail = model.detail {
                EditRambleSheet(
                    title: detail.title ?? "",
                    summary: detail.summary ?? ""
                ) { title, summary in
                    await model.rename(title: title, summary: summary)
                }
            }
        }
        .sheet(item: $editingItem) { item in
            EditItemSheet(item: item) { kind, title in
                await model.correct(item, kind: kind, title: title)
            }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete()
                    dismiss()
                }
            }
        } message: {
            Text("The audio, the transcript, and everything found in it go with it. This can't be undone.")
        }
        .task {
            await model.load()
            sync()
        }
        .onChange(of: model.detail?.audioURL) { _, _ in sync() }
        .onDisappear { player.teardown() }
        .refreshable { await model.load() }
    }

    private func sync() {
        guard let detail = model.detail else { return }
        player.prepare(url: detail.audioURL.flatMap(URL.init(string:)))
    }

    // MARK: - Header

    private func header(_ detail: RambleDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            HStack(spacing: 6) {
                Text(detail.recordedAt, format: .dateTime.weekday(.wide).month(.wide).day())
                Text("\u{00B7}")
                Text(detail.recordedAt, format: .dateTime.hour().minute())
                Text("\u{00B7}")
                Text(detail.durationSeconds.durationLabel).monospacedDigit()
            }
            .rambleType(Theme.Text.eyebrow)
            .foregroundStyle(Theme.Palette.secondary)

            Text(detail.title ?? (detail.processingState.isTerminal ? "Untitled" : detail.processingState.label))
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = detail.summary, !summary.isEmpty {
                Text(summary)
                    .rambleType(Theme.Text.reading)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AudioPlayerBar(player: player)
                .padding(.top, Theme.Metrics.sm)

            if session.isSampleMode {
                Text("Everything below was put together by a stand-in, not a real model.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            }
        }
        .padding(.top, Theme.Metrics.sm)
    }

    // MARK: - Sections

    @ViewBuilder
    private var approvals: some View {
        if !model.pendingActions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                SectionHeading("Needs your yes", trailing: "\(model.pendingActions.count)")
                ForEach(model.pendingActions) { action in
                    ApprovalCard(
                        action: action,
                        isSubmitting: model.isSubmitting(action),
                        outcome: model.outcome(for: action),
                        seek: player.isUnavailable ? nil : { player.play(from: $0) },
                        respond: { approve in
                            Task { await model.respond(to: action, approve: approve) }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var completed: some View {
        let done = model.completedActions
        let resolved = model.resolvedActions
        if !done.isEmpty || !resolved.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("Already taken care of")
                    .padding(.bottom, Theme.Metrics.sm)
                ForEach(done) { CompletedActionRow(action: $0) }
                ForEach(resolved) { action in
                    ResolvedActionRow(action: action) {
                        Task { await model.respond(to: action, approve: true) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var items: some View {
        if !model.groupedItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                ForEach(model.groupedItems) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeading(group.kind.pluralLabel, trailing: "\(group.items.count)")
                            .padding(.bottom, Theme.Metrics.sm)
                        ForEach(group.items) { item in
                            ExtractedItemView(
                                item: item,
                                seek: player.isUnavailable ? nil : { player.play(from: $0) },
                                edit: { editingItem = item }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entities(_ detail: RambleDetail) -> some View {
        if !detail.entities.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                SectionHeading("Who and what came up")
                FlowLayout(spacing: 6) {
                    ForEach(detail.entities) { entity in
                        NavigationLink(value: AppDestination.entity(entity.id)) {
                            EntityChip(name: entity.name, kind: entity.kind)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func transcript(_ detail: RambleDetail) -> some View {
        TranscriptSection(
            segments: detail.segments,
            fallbackText: detail.cleanTranscript,
            highlight: highlighting,
            seek: player.isUnavailable ? nil : { player.play(from: $0) }
        )
    }

    @ViewBuilder
    private func related(_ detail: RambleDetail) -> some View {
        if !detail.related.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("You've talked about this before")
                    .padding(.bottom, Theme.Metrics.sm)
                ForEach(detail.related) { item in
                    NavigationLink(value: AppDestination.ramble(item.id)) {
                        RelatedRambleRow(related: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil") { isEditingTitle = true }
                Button("Process again", systemImage: "arrow.clockwise") {
                    Task { await model.reprocess() }
                }
                if session.health?.hasCloudTranscription == true {
                    Button("Transcribe more accurately", systemImage: "waveform.badge.magnifyingglass") {
                        Task { await model.upgradeTranscript() }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.Palette.secondary)
            }
            .accessibilityLabel("More")
        }
    }
}
