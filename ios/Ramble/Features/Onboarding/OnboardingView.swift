import SwiftUI

/// What is left to settle once there is an account: what kind of work this is
/// for, and the microphone. The idea itself was made before sign-in, in
/// `WelcomeView` — repeating it here would just be a wall between the person
/// and the record button.
struct OnboardingView: View {
    @Environment(Session.self) private var session
    @State private var step = 0
    @State private var profile: UserProfile = .other

    var body: some View {
        ZStack {
            Theme.Palette.paper.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                progress
                    .padding(.top, Theme.Metrics.lg)
                    .screenPadding()

                TabView(selection: $step) {
                    work.tag(0)
                    microphone.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.Palette.ink : Theme.Palette.divider)
                    .frame(height: 2)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Work type

    private var work: some View {
        step(
            title: "What kind of work is this for?",
            body: "It only changes what Ramble pays attention to when it reads a recording back. It is not a folder, and you can change it whenever.",
            action: "Continue"
        ) {
            step = 1
        } content: {
            VStack(spacing: 0) {
                ForEach(UserProfile.allCases, id: \.self) { option in
                    Button { profile = option } label: {
                        HStack(alignment: .top, spacing: Theme.Metrics.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .rambleType(Theme.Text.body)
                                    .foregroundStyle(Theme.Palette.ink)
                                Text(option.blurb)
                                    .rambleType(Theme.Text.meta)
                                    .foregroundStyle(Theme.Palette.secondary)
                            }
                            Spacer(minLength: Theme.Metrics.sm)
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.Palette.action)
                                .frame(width: 16)
                                .opacity(profile == option ? 1 : 0)
                        }
                        .padding(.vertical, Theme.Metrics.md)
                        .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(profile == option ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.top, Theme.Metrics.lg)
        }
    }

    // MARK: - Microphone

    private var microphone: some View {
        step(
            title: "One thing to allow.",
            body: "Ramble needs your microphone \u{2014} it's the only thing the app does. Calendar and reminders are asked for later, and only when you approve something that needs them.",
            action: "Allow microphone and finish"
        ) {
            Task {
                _ = await Recorder.requestPermission()
                await session.completeOnboarding(profile: profile)
            }
        } content: {
            EmptyView()
        }
    }

    // MARK: - Layout

    private func step(
        title: String,
        body: String,
        action: String,
        perform: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                    Text("ramble")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.Palette.secondary)
                        .padding(.top, Theme.Metrics.xxl)

                    Text(title)
                        .rambleType(Theme.Text.screenTitle)
                        .foregroundStyle(Theme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(body)
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .screenPadding()
                .padding(.bottom, Theme.Metrics.xl)
            }
            .scrollIndicators(.hidden)

            Button(action, action: perform)
                .buttonStyle(PrimaryButtonStyle())
                .screenPadding()
                .padding(.bottom, Theme.Metrics.xxl)
        }
    }
}
