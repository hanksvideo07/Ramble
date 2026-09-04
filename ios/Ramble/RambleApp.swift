import SwiftUI

@main
struct RambleApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Theme.Palette.accent)
                .preferredColorScheme(nil) // follow the system
        }
    }
}

/// Decides what the person sees: sign-in, onboarding, or the app itself.
struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                LaunchView()
            case .signedOut:
                AuthView()
            case .onboarding:
                OnboardingView()
            case .ready:
                HomeView()
            }
        }
        .background(Theme.Palette.background)
        .task { await session.restore() }
        .animation(.easeInOut(duration: 0.25), value: session.phase)
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            Text("Ramble")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)
        }
    }
}
