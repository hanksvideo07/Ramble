import SwiftUI

@main
struct RambleApp: App {
    @State private var session = Session()
    @State private var appearance = AppearanceSetting.current

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Theme.Palette.action)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { DeepLink.shared.handle($0) }
                .task { CrashReporter.shared.start() }
                .onReceive(NotificationCenter.default.publisher(for: .appearanceChanged)) { _ in
                    appearance = AppearanceSetting.current
                }
        }
    }
}

/// Decides what the person sees: sign-in, onboarding, or the app itself.
struct RootView: View {
    @Environment(Session.self) private var session
    @State private var hasSeenWelcome = Welcome.hasSeen

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                LaunchView()
            case .signedOut:
                if hasSeenWelcome {
                    AuthView()
                } else {
                    WelcomeView {
                        Welcome.hasSeen = true
                        hasSeenWelcome = true
                    }
                }
            case .onboarding:
                OnboardingView()
            case .ready:
                AppShell()
            }
        }
        .background(Theme.Palette.paper)
        .task { await session.restore() }
        .animation(.ramble(0.25), value: session.phase)
        .animation(.ramble(0.25), value: hasSeenWelcome)
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.Palette.paper.ignoresSafeArea()
            Text("ramble")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Palette.ink)
        }
    }
}
