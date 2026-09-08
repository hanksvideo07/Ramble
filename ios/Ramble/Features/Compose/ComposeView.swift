import SwiftUI

/// A ramble you type or paste instead of speaking.
///
/// Same promise, different input: nothing to file, nothing to title, no
/// category to pick. It goes through exactly the same understanding as speech
/// does, which is the point — a thought is not a different kind of thing
/// because it arrived through a keyboard.
struct ComposeView: View {
    /// Opens with whatever is on the clipboard already in place. Set by the
    /// widget's Paste button, where the intent is unambiguous.
    var startWithClipboard: Bool = false
    /// Called once the text has been handed to the server.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.paper.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    if let errorMessage {
                        StatusNotice(
                            message: "That didn't send",
                            detail: errorMessage,
                            tone: .warning,
                            systemImage: "exclamationmark.triangle",
                            actionTitle: "Try again",
                            action: { Task { await send() } }
                        )
                        .screenPadding()
                        .padding(.bottom, Theme.Metrics.md)
                    }

                    TextEditor(text: $text)
                        .rambleType(Theme.Text.reading)
                        .foregroundStyle(Theme.Palette.ink)
                        .scrollContentBackground(.hidden)
                        .background(Theme.Palette.paper)
                        .focused($focused)
                        .screenPadding()
                        .overlay(alignment: .topLeading) {
                            // TextEditor has no placeholder of its own, and an
                            // empty page with no prompt reads as broken.
                            if text.isEmpty {
                                Text("What's on your mind?")
                                    .rambleType(Theme.Text.reading)
                                    .foregroundStyle(Theme.Palette.secondary.opacity(0.7))
                                    .screenPadding()
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }

                    footer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.secondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Write it down")
                        .rambleType(Theme.Text.eyebrow)
                        .foregroundStyle(Theme.Palette.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Done")
                        }
                    }
                    .disabled(!canSend)
                    .foregroundStyle(canSend ? Theme.Palette.action : Theme.Palette.secondary)
                }
            }
        }
        .onAppear {
            if startWithClipboard, text.isEmpty, let pasted = UIPasteboard.general.string {
                text = pasted
            }
            focused = true
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Metrics.md) {
            Button {
                // Pasting is the whole reason a lot of people will open this:
                // something they read elsewhere and want kept.
                if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                    text += text.isEmpty ? pasted : "\n\n\(pasted)"
                }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: Theme.Metrics.minimumTouchTarget)

            Spacer()

            Text("Ramble will work out what this was.")
                .rambleType(Theme.Text.meta)
                .foregroundStyle(Theme.Palette.secondary)
        }
        .screenPadding()
        .padding(.bottom, Theme.Metrics.md)
        .overlay(alignment: .top) { Hairline() }
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await APIClient.shared.createTextRamble(
                clientId: UUID().uuidString,
                text: body
            )
            errorMessage = nil
            onFinish()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
