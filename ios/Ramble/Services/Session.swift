import Foundation
import Observation
import SwiftUI

/// App-wide state: who is signed in, and whether the backend is running real
/// models or stand-ins.
@MainActor
@Observable
final class Session {
    enum Phase: Equatable {
        case loading
        case signedOut
        case onboarding
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var account: Account?
    private(set) var health: HealthReport?
    var errorMessage: String?

    /// True when the server is producing sample output rather than real
    /// understanding, so the UI can label it honestly.
    var isSampleMode: Bool { health?.isUsingMockUnderstanding ?? false }

    func restore() async {
        // Health is unauthenticated, so it also tells us whether the server is
        // reachable at all before we try to use a stored token.
        health = try? await APIClient.shared.health()

        #if DEBUG
        // Lets a local build be launched straight into the seeded account:
        //   SIMCTL_CHILD_RAMBLE_DEMO_LOGIN=1 xcrun simctl launch <device> app.ramble.Ramble
        if ProcessInfo.processInfo.environment["RAMBLE_DEMO_LOGIN"] == "1" {
            await signIn(email: "demo@ramble.app", password: "rambledemo")
            // If it failed, fall through to the normal path rather than
            // leaving the app on the launch screen.
            if phase != .loading { return }
        }
        #endif

        guard await APIClient.shared.isSignedIn else {
            phase = .signedOut
            return
        }
        do {
            let account = try await APIClient.shared.me()
            self.account = account
            phase = account.onboarded ? .ready : .onboarding
            await afterSignIn()
        } catch APIError.notAuthenticated {
            await APIClient.shared.setToken(nil)
            phase = .signedOut
        } catch {
            // The token may still be good and the server merely unreachable;
            // let the person in and let individual screens report failures.
            phase = .ready
        }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        do {
            let account = try await APIClient.shared.login(email: email, password: password)
            self.account = account
            phase = account.onboarded ? .ready : .onboarding
            await afterSignIn()
        } catch {
            errorMessage = error.localizedDescription
            // A failed sign-in from the launch path must still resolve to a
            // screen the person can act on.
            if phase == .loading { phase = .signedOut }
        }
    }

    func register(email: String, password: String) async {
        errorMessage = nil
        do {
            account = try await APIClient.shared.register(email: email, password: password)
            phase = .onboarding
            await afterSignIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeOnboarding(profile: UserProfile) async {
        do {
            account = try await APIClient.shared.updateProfile(profile, onboarded: true)
        } catch {
            // Onboarding is a preference, not a gate: never trap someone here.
            errorMessage = error.localizedDescription
        }
        phase = .ready
    }

    func signOut() async {
        await APIClient.shared.logout()
        account = nil
        phase = .signedOut
    }

    private func afterSignIn() async {
        // Anything recorded while signed out or offline can now be sent.
        CaptureQueue.shared.sync()
        await DeviceActionRunner.shared.runPendingActions()
        // Fills in vectors for anything extracted while this device was away.
        EmbeddingSync.shared.sync()

        // Downloading the transcription model can take a while and needs a
        // connection, so it is started now rather than when the user is
        // standing there having just stopped a recording.
        if #available(iOS 26.0, *) {
            Task.detached(priority: .utility) {
                try? await OnDeviceTranscriber.prepare()
            }
        }
    }
}
