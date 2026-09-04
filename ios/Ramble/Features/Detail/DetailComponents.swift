import AVKit
import SwiftUI

/// The confirmation card for an action Ramble wants to take.
///
/// It shows what would happen, and — crucially — why it is asking. The guide's
/// safety model only works if the person can see the difference between "you
/// told me to" and "I think you might want this".
struct ActionCard: View {
    let action: RambleAction
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(Theme.Palette.text)
                    if !action.detail.isEmpty {
                        Text(action.detail)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                }
                Spacer()
            }

            if let quote = reasonText {
                Text(quote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }

            HStack(spacing: 8) {
                Button { respond(false) } label: {
                    Text("No")
                        .font(Theme.Typography.secondary.weight(.medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                        )
                }
                Button { respond(true) } label: {
                    Text("Do it")
                        .font(Theme.Typography.secondary.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .buttonStyle(.plain)
        }
        .rambleCard()
    }

    /// Explains the ask in the user's terms, never in the model's.
    private var reasonText: String? {
        switch action.intentClass {
        case "external_communication":
            "This would reach someone else, so Ramble always asks first."
        case "information":
            "It sounded like a thought rather than an instruction."
        case "intention":
            "It sounded like something you meant to do yourself."
        default:
            action.confidence < 0.75
                ? "Ramble wasn't certain it understood this one."
                : nil
        }
    }
}

/// An action that already happened, stated plainly and without celebration.
struct CompletedActionRow: View {
    let action: RambleAction

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.kind(.task))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.label)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.text)
                if !action.detail.isEmpty {
                    Text(action.detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One extracted thing. Tapping opens the correction sheet, because the guide
/// wants "this isn't a task" to be a one-tap thought, not a settings trip.
struct ItemRow: View {
    let item: ExtractedItem
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.kind(item.kind))
                    .frame(width: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.text)
                        .multilineTextAlignment(.leading)
                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.muted)
                            .multilineTextAlignment(.leading)
                    }
                    if let due = item.dueDate {
                        Text(due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.kind(item.kind))
                    }
                }
                Spacer(minLength: 0)

                if item.correctedByUser {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.muted.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// "This isn't a task." Corrections are stored and survive reprocessing.
struct ItemCorrectionSheet: View {
    let item: ExtractedItem
    let save: (ItemKind, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ItemKind
    @State private var title: String

    init(item: ExtractedItem, save: @escaping (ItemKind, String) -> Void) {
        self.item = item
        self.save = save
        _kind = State(initialValue: item.kind)
        _title = State(initialValue: item.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What is this?") {
                    Picker("Kind", selection: $kind) {
                        ForEach(ItemKind.allCases.filter { $0 != .summary }, id: \.self) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                }
                if let quote = item.sourceQuote {
                    Section("You said") {
                        Text(quote)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                }
            }
            .navigationTitle("Fix this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(kind, title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Plays the original recording. The audio is the source of truth, so it stays
/// one tap away from everything derived from it.
struct AudioPlayerBar: View {
    let url: URL
    let duration: Double

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.text)
                    .frame(width: 32, height: 32)
                    .background(Theme.Palette.hairline.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Palette.hairline)
                        .frame(height: 3)
                    Capsule()
                        .fill(Theme.Palette.accent)
                        .frame(width: geometry.size.width * progress, height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 32)

            Text(duration.durationLabel)
                .font(Theme.Typography.caption.monospacedDigit())
                .foregroundStyle(Theme.Palette.muted)
        }
        .onDisappear {
            player?.pause()
            if let observer { player?.removeTimeObserver(observer) }
        }
    }

    private func toggle() {
        if player == nil {
            let player = AVPlayer(url: url)
            // A periodic observer is enough for a progress bar and avoids
            // driving a timer when nothing is playing.
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                queue: .main
            ) { time in
                guard duration > 0 else { return }
                progress = min(1, time.seconds / duration)
                if progress >= 1 { isPlaying = false }
            }
            self.player = player
        }

        if isPlaying {
            player?.pause()
        } else {
            if progress >= 1 {
                player?.seek(to: .zero)
                progress = 0
            }
            player?.play()
        }
        isPlaying.toggle()
    }
}
