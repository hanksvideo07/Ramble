import SwiftUI

/// Three screens, then they're recording. The guide is explicit that this
/// should teach one idea — don't organize, just talk — and get out of the way.
struct OnboardingView: View {
    @Environment(Session.self) private var session
    @State private var step = 0
    @State private var profile: UserProfile = .other

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                progress
                    .padding(.top, 16)

                TabView(selection: $step) {
                    ideaStep.tag(0)
                    profileStep.tag(1)
                    permissionStep.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.Palette.text : Theme.Palette.hairline)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Step 1: the idea

    private var ideaStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("Don't organize.\nJust ramble.")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)
                .lineSpacing(2)

            Text("Press the button and talk. Ramble works out what was a task, an idea, a decision, or something to remember — and files it for you.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.muted)
                .padding(.top, 16)

            DemoRambleCard()
                .padding(.top, 32)

            Spacer()
            continueButton("Continue") { step = 1 }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Step 2: profile

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("What best describes you?")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)
            Text("This only changes what Ramble pays attention to. You can change it later.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
                .padding(.top, 8)

            VStack(spacing: 8) {
                ForEach(UserProfile.allCases, id: \.self) { option in
                    Button {
                        profile = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(Theme.Typography.body.weight(.medium))
                                    .foregroundStyle(Theme.Palette.text)
                                Text(option.blurb)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.muted)
                            }
                            Spacer()
                            if profile == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                                .strokeBorder(
                                    profile == option ? Theme.Palette.accent.opacity(0.5) : Theme.Palette.hairline,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 24)

            Spacer()
            continueButton("Continue") { step = 2 }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Step 3: microphone

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("One thing to allow")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)
            Text("Ramble needs your microphone. Calendar and reminders are asked for later, only when you actually approve something.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.muted)
                .padding(.top, 12)

            Spacer()
            continueButton("Allow microphone and finish") {
                Task {
                    _ = await Recorder.requestPermission()
                    await session.completeOnboarding(profile: profile)
                }
            }
        }
        .padding(.horizontal, 28)
    }

    private func continueButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.Palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
        }
        .padding(.bottom, 40)
    }
}

/// Shows the product's whole promise in one card: a messy sentence on top,
/// the structure it becomes underneath. Teaches faster than explaining.
private struct DemoRambleCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\"I need to finish the history paper by Thursday. Remind me tomorrow to ask Ben about the startup competition. And put practice on my calendar Wednesday at four.\"")
                .font(Theme.Typography.secondary)
                .italic()
                .foregroundStyle(Theme.Palette.muted)

            HStack(spacing: 6) {
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 1)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                demoRow(.task, "Finish the history paper", "Thursday")
                demoRow(.reminder, "Ask Ben about the startup competition", "Tomorrow")
                demoRow(.commitment, "Practice", "Wednesday 4:00 PM")
            }
        }
        .rambleCard()
    }

    private func demoRow(_ kind: ItemKind, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.kind(kind))
                .frame(width: 16)
            Text(title)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(1)
        }
    }
}
