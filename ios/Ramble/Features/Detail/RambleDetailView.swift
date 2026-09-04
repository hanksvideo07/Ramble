import AVKit
import SwiftUI

/// Everything one recording became: what it was about, what needs approving,
/// what was extracted, who it involved, and the transcript it all came from.
struct RambleDetailView: View {
    let rambleId: String

    @State private var model: RambleDetailModel
    @State private var showingTranscript = false
    @State private var editingItem: ExtractedItem?
    @Environment(\.dismiss) private var dismiss

    init(rambleId: String) {
        self.rambleId = rambleId
        _model = State(initialValue: RambleDetailModel(rambleId: rambleId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let detail = model.detail {
                    header(detail)

                    if detail.processingState == .failed {
                        FailedBanner(message: detail.processingError) {
                            Task { await model.reprocess() }
                        }
                    }

                    // Pending approvals come first: they are the only thing on
                    // this screen that is waiting on the person.
                    let pending = detail.actions.filter(\.isPending)
                    if !pending.isEmpty {
                        Section(header: SectionLabel("Needs your OK")) {
                            VStack(spacing: 8) {
                                ForEach(pending) { action in
                                    ActionCard(action: action) { approved in
                                        Task { await model.respond(to: action, approve: approved) }
                                    }
                                }
                            }
                        }
                    }

                    let done = detail.actions.filter(\.isDone)
                    if !done.isEmpty {
                        Section(header: SectionLabel("Done for you")) {
                            VStack(spacing: 6) {
                                ForEach(done) { action in
                                    CompletedActionRow(action: action)
                                }
                            }
                        }
                    }

                    if !model.groupedItems.isEmpty {
                        ForEach(model.groupedItems, id: \.kind) { group in
                            Section(header: SectionLabel(group.kind.pluralLabel)) {
                                VStack(spacing: 6) {
                                    ForEach(group.items) { item in
                                        ItemRow(item: item) { editingItem = item }
                                    }
                                }
                            }
                        }
                    }

                    if !detail.entities.isEmpty {
                        Section(header: SectionLabel("People and places")) {
                            FlowLayout(spacing: 6) {
                                ForEach(detail.entities) { entity in
                                    NavigationLink(value: entity.id) {
                                        EntityChip(name: entity.name)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    transcriptSection(detail)

                    if !detail.related.isEmpty {
                        Section(header: SectionLabel("Related")) {
                            VStack(spacing: 6) {
                                ForEach(detail.related) { related in
                                    NavigationLink(value: RelatedDestination(id: related.id)) {
                                        RelatedRow(related: related)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if let error = model.errorMessage {
                    EmptyStateView(
                        title: "Couldn't load this",
                        message: error,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, 40)
        }
        .background(Theme.Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Process again", systemImage: "arrow.clockwise") {
                        Task { await model.reprocess() }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task {
                            await model.delete()
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
        }
        .navigationDestination(for: String.self) { EntityDetailView(entityId: $0) }
        .navigationDestination(for: RelatedDestination.self) { RambleDetailView(rambleId: $0.id) }
        .sheet(item: $editingItem) { item in
            ItemCorrectionSheet(item: item) { kind, title in
                Task { await model.correct(item, kind: kind, title: title) }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    // MARK: - Sections

    private func header(_ detail: RambleDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.recordedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.muted)

            Text(detail.title ?? "Untitled")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)

            if let summary = detail.summary {
                Text(summary)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.muted)
            }

            if let urlString = detail.audioURL, let url = URL(string: urlString) {
                AudioPlayerBar(url: url, duration: detail.durationSeconds)
                    .padding(.top, 6)
            }
        }
        .padding(.top, 8)
    }

    private func transcriptSection(_ detail: RambleDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingTranscript.toggle() }
            } label: {
                HStack {
                    SectionLabel("Transcript")
                    Spacer()
                    Image(systemName: showingTranscript ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            .buttonStyle(.plain)

            if showingTranscript {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.segments) { segment in
                        HStack(alignment: .top, spacing: 10) {
                            Text(segment.startSeconds.durationLabel)
                                .font(Theme.Typography.caption.monospacedDigit())
                                .foregroundStyle(Theme.Palette.muted)
                                .frame(width: 40, alignment: .leading)
                            Text(segment.text)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.text)
                        }
                    }
                }
                .rambleCard()
            }
        }
    }
}

/// Distinguishes a related-ramble link from an entity link in the same stack.
struct RelatedDestination: Hashable {
    let id: String
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FailedBanner: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This one didn't finish processing")
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(Theme.Palette.text)
            if let message {
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text("Your recording and transcript are safe.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.muted)
            Button("Try again", action: retry)
                .font(Theme.Typography.secondary.weight(.medium))
                .foregroundStyle(Theme.Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rambleCard()
    }
}

private struct RelatedRow: View {
    let related: RambleDetail.RelatedRamble

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(related.title ?? "Untitled")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                Text(related.recordedAt, format: .dateTime.month(.abbreviated).day())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
        }
        .rambleCard()
    }
}
