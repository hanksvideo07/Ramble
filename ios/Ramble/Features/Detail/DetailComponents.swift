import SwiftUI

/// One extracted thing. Tapping edit opens the correction sheet, because
/// "this isn't a task" should be a one-tap thought and not a trip to settings.
struct ExtractedItemView: View {
    let item: ExtractedItem
    var seek: ((Double) -> Void)?
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.md) {
            VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                HStack(spacing: Theme.Metrics.sm) {
                    ExtractionLabel(kind: item.kind)
                    if item.correctedByUser {
                        Text("edited by you")
                            .rambleType(Theme.Text.meta)
                            .foregroundStyle(Theme.Palette.secondary)
                    }
                }

                Text(item.title)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Metrics.md) {
                    if let due = item.dueDate {
                        Label {
                            Text(due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        } icon: {
                            Image(systemName: "calendar").font(.system(size: 10))
                        }
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(Theme.Palette.accent(for: item.kind).text)
                    }
                    if let start = item.sourceStartSeconds, let seek {
                        Button { seek(start) } label: {
                            Label(start.durationLabel, systemImage: "play.circle")
                                .rambleType(Theme.Text.meta)
                                .foregroundStyle(Theme.Palette.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play from \(start.durationLabel)")
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: edit) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(
                        width: Theme.Metrics.minimumTouchTarget,
                        height: Theme.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(item.title)")
        }
        .padding(.vertical, Theme.Metrics.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// Correcting an item: fix the words, or say it was never that kind of thing.
/// Both are saved through the same adapter and show up everywhere the item does.
struct EditItemSheet: View {
    let item: ExtractedItem
    let save: (ItemKind, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ItemKind
    @State private var title: String
    @State private var isSaving = false

    init(item: ExtractedItem, save: @escaping (ItemKind, String) async -> Void) {
        self.item = item
        self.save = save
        _kind = State(initialValue: item.kind)
        _title = State(initialValue: item.title)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    private var editableKinds: [ItemKind] {
        ItemKind.allCases.filter { $0 != .summary }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                    VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                        SectionHeading("What it says")
                        TextField("What it says", text: $title, axis: .vertical)
                            .rambleType(Theme.Text.body)
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(2...6)
                            .padding(Theme.Metrics.md)
                            .background(Theme.Palette.raised)
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: Theme.Metrics.inputRadius,
                                    style: .continuous
                                )
                                .strokeBorder(Theme.Palette.divider, lineWidth: 1)
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: Theme.Metrics.inputRadius,
                                    style: .continuous
                                )
                            )
                    }

                    VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                        SectionHeading("What kind of thing it is")
                        FlowLayout(spacing: 6) {
                            ForEach(editableKinds, id: \.self) { option in
                                Button { kind = option } label: {
                                    kindOption(option, selected: option == kind)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(
                                    option == kind ? [.isButton, .isSelected] : .isButton
                                )
                            }
                        }
                    }

                    if let quote = item.sourceQuote, !quote.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                            SectionHeading("What you said")
                            Text("\u{201C}\(quote)\u{201D}")
                                .rambleType(Theme.Text.quote)
                                .italic()
                                .foregroundStyle(Theme.Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .screenPadding()
                .padding(.vertical, Theme.Metrics.lg)
            }
            .background(Theme.Palette.paper)
            .navigationTitle("Fix this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await save(kind, title.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? Theme.Palette.action : Theme.Palette.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func kindOption(_ option: ItemKind, selected: Bool) -> some View {
        let accent = Theme.Palette.accent(for: option)
        return HStack(spacing: 5) {
            Image(systemName: option.systemImage).font(.system(size: 11))
            Text(option.label)
        }
        .rambleType(Theme.Text.chip)
        .foregroundStyle(selected ? Theme.Palette.onAction : accent.text)
        .padding(.horizontal, Theme.Metrics.md)
        .padding(.vertical, 8)
        .background(selected ? Theme.Palette.action : accent.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.labelRadius, style: .continuous))
    }
}

/// An action that already happened. Stated plainly, without celebration, and
/// only ever for something the underlying service actually confirmed.
struct CompletedActionRow: View {
    let action: RambleAction

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.md) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.action)
                .frame(width: 16)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.completedLabel)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    if let date = action.scheduledAt {
                        Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        Text("\u{00B7}")
                    }
                    Text(action.destination)
                }
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Metrics.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An action that was declined or that failed. Kept visible rather than
/// silently removed, so the person can see what became of their answer.
struct ResolvedActionRow: View {
    let action: RambleAction
    var retry: (() -> Void)?

    private var icon: String { action.isFailed ? "exclamationmark.triangle" : "xmark" }
    private var tone: Color { action.isFailed ? Theme.Palette.warning : Theme.Palette.secondary }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.md) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 16)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.isFailed ? "\(action.label) didn't go through" : "You said no to \(action.label.lowercased())")
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = action.error, action.isFailed {
                    Text(error)
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(tone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if action.isFailed, let retry {
                Button("Retry", action: retry)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
            }
        }
        .padding(.vertical, Theme.Metrics.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The full transcript, collapsed by default and set for reading rather than
/// scanning: serif, 17pt, and generously led.
struct TranscriptSection: View {
    let segments: [RambleDetail.Segment]
    let fallbackText: String?
    /// A passage to scroll to and mark, arriving from a citation.
    var highlight: String?
    var seek: ((Double) -> Void)?

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Consecutive segments read as one paragraph until there is a real pause,
    /// which is what makes a wall of speech comfortable to read.
    private var paragraphs: [Paragraph] {
        guard !segments.isEmpty else { return [] }
        var result: [Paragraph] = []
        var current: [RambleDetail.Segment] = []

        for segment in segments.sorted(by: { $0.index < $1.index }) {
            if let last = current.last, segment.startSeconds - last.endSeconds > 1.4 {
                result.append(Paragraph(segments: current))
                current = []
            }
            current.append(segment)
        }
        if !current.isEmpty { result.append(Paragraph(segments: current)) }
        return result
    }

    struct Paragraph: Identifiable {
        let segments: [RambleDetail.Segment]
        var id: Int { segments.first?.index ?? 0 }
        var start: Double { segments.first?.startSeconds ?? 0 }
        var text: String { segments.map(\.text).joined(separator: " ") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
            Button {
                withAnimation(reduceMotion ? nil : .ramble()) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Metrics.sm) {
                    Text("Full transcript")
                        .rambleType(Theme.Text.eyebrow)
                        .foregroundStyle(Theme.Palette.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.secondary)
                }
                .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide full transcript" : "Show full transcript")

            if isExpanded {
                if paragraphs.isEmpty, let fallbackText, !fallbackText.isEmpty {
                    Text(fallbackText)
                        .rambleType(Theme.Text.reading)
                        .foregroundStyle(Theme.Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if paragraphs.isEmpty {
                    Text("There's no transcript for this one yet.")
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                } else {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                            ForEach(paragraphs) { paragraph in
                                paragraphView(paragraph)
                                    .id(paragraph.id)
                            }
                        }
                        .onAppear {
                            guard let target = highlightedParagraph else { return }
                            withAnimation(reduceMotion ? nil : .ramble()) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) { Hairline() }
        .onAppear {
            // A citation asked for a specific passage, so the transcript opens
            // itself rather than making the person find the toggle.
            if highlightedParagraph != nil { isExpanded = true }
        }
    }

    private var highlightedParagraph: Int? {
        guard let highlight, !highlight.isEmpty else { return nil }
        let needle = highlight.prefix(40).lowercased()
        return paragraphs.first { $0.text.lowercased().contains(needle) }?.id
    }

    @ViewBuilder
    private func paragraphView(_ paragraph: Paragraph) -> some View {
        let isHighlighted = paragraph.id == highlightedParagraph

        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            if let seek {
                Button { seek(paragraph.start) } label: {
                    Text(paragraph.start.durationLabel)
                        .rambleType(Theme.Text.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from \(paragraph.start.durationLabel)")
            } else {
                Text(paragraph.start.durationLabel)
                    .rambleType(Theme.Text.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.secondary)
            }

            Text(paragraph.text)
                .rambleType(Theme.Text.reading)
                .foregroundStyle(Theme.Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isHighlighted ? Theme.Metrics.md : 0)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle().fill(Theme.Palette.action).frame(width: 2)
            }
        }
    }
}

/// A recording that shares people or projects with this one.
struct RelatedRambleRow: View {
    let related: RambleDetail.RelatedRamble

    var body: some View {
        HStack(spacing: Theme.Metrics.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(related.title ?? "Untitled")
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text(related.recordedAt, format: .dateTime.month(.abbreviated).day().year())
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
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
    }
}
