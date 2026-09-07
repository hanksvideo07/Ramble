import SwiftUI

/// The first thing anyone sees, before there is an account to sign into.
///
/// One idea, stated once. Asking someone to create an account before they know
/// what the app is for gets the order backwards — the promise comes first, and
/// the door comes after it.
struct WelcomeView: View {
    let begin: () -> Void

    var body: some View {
        ZStack {
            Theme.Palette.paper.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                        Text("ramble")
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(Theme.Palette.secondary)
                            .padding(.top, Theme.Metrics.xxl)

                        Spacer(minLength: Theme.Metrics.xxl)

                        Text("Start talking.\nWe'll find the shape.")
                            .rambleType(Theme.Text.screenTitle)
                            .foregroundStyle(Theme.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("No folders. No categories. No titles. Just whatever is on your mind \u{2014} Ramble works out afterwards what was a task, a decision, an idea, or something you meant to remember.")
                            .rambleType(Theme.Text.supporting)
                            .foregroundStyle(Theme.Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        WelcomeExtraction()
                            .padding(.top, Theme.Metrics.xl)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .screenPadding()
                    .padding(.bottom, Theme.Metrics.xl)
                }
                .scrollIndicators(.hidden)

                Button("Get started", action: begin)
                    .buttonStyle(PrimaryButtonStyle())
                    .screenPadding()
                    .padding(.bottom, Theme.Metrics.xxl)
            }
        }
    }
}

/// The whole promise in one block: a messy sentence, and the structure it
/// becomes. Teaches faster than any explanation of it would.
struct WelcomeExtraction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
            Text("\u{201C}I need to finish the pricing page by Thursday. Remind me tomorrow to ask Maya about the trial. And we're going with one plan at $29.\u{201D}")
                .rambleType(Theme.Text.quote)
                .italic()
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Metrics.sm) {
                Rectangle().fill(Theme.Palette.divider).frame(height: 1)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                Rectangle().fill(Theme.Palette.divider).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                row(.task, "Finish the pricing page", "Thursday")
                row(.reminder, "Ask Maya about the trial", "Tomorrow")
                row(.decision, "One plan at $29 a month", nil)
            }
        }
        .padding(Theme.Metrics.lg)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.surfaceRadius, style: .continuous))
    }

    private func row(_ kind: ItemKind, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.sm) {
            ExtractionLabel(kind: kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .rambleType(Theme.Text.meta)
                        .foregroundStyle(Theme.Palette.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Whether the person has been told what the app is for. Device-local: it
/// describes this install, not the account.
enum Welcome {
    private static let key = "app.ramble.seenWelcome"

    static var hasSeen: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
