import SwiftUI

/// Sign in or create an account. Deliberately plain: this screen is a door,
/// not a destination.
struct AuthView: View {
    @Environment(Session.self) private var session
    @State private var isRegistering = false
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 8 && !isWorking
    }

    var body: some View {
        ZStack {
            Theme.Palette.paper.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ramble")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.Palette.secondary)
                        .padding(.top, Theme.Metrics.xxl)

                    Text(isRegistering ? "Somewhere to\nthink out loud." : "Welcome back.")
                        .rambleType(Theme.Text.screenTitle)
                        .foregroundStyle(Theme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Metrics.xl)

                    Text(isRegistering
                         ? "Your recordings are yours. Nothing you say is used to train anyone's models."
                         : "Everything you've said is still here.")
                        .rambleType(Theme.Text.supporting)
                        .foregroundStyle(Theme.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Metrics.md)

                    VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                        field("Email") {
                            TextField("you@example.com", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                        }
                        field("Password") {
                            SecureField("At least 8 characters", text: $password)
                                .textContentType(isRegistering ? .newPassword : .password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { if canSubmit { submit() } }
                        }
                    }
                    .padding(.top, Theme.Metrics.xxl)

                    if let error = session.errorMessage {
                        Text(error)
                            .rambleType(Theme.Text.supporting)
                            .foregroundStyle(Theme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Metrics.md)
                    }

                    Button(action: submit) {
                        HStack(spacing: Theme.Metrics.sm) {
                            if isWorking {
                                ProgressView().controlSize(.small).tint(Theme.Palette.onAction)
                            }
                            Text(isRegistering ? "Create account" : "Sign in")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(isEnabled: canSubmit))
                    .disabled(!canSubmit)
                    .padding(.top, Theme.Metrics.xl)

                    Button(isRegistering ? "I already have an account" : "Create an account") {
                        withAnimation(.ramble()) {
                            isRegistering.toggle()
                        }
                    }
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minimumTouchTarget)
                    .padding(.top, Theme.Metrics.md)

                    #if DEBUG
                    // Local development only: the account created by `npm run
                    // seed`, so a seeded history is one tap away.
                    Button("Use the demo account") {
                        email = "demo@ramble.app"
                        password = "rambledemo"
                        submit()
                    }
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minimumTouchTarget)
                    #endif
                }
                .screenPadding()
                .padding(.bottom, Theme.Metrics.xxl)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text(label)
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            content()
                .rambleType(Theme.Text.body)
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, Theme.Metrics.md)
                .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                .background(Theme.Palette.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.divider, lineWidth: 1)
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                )
        }
    }

    private func submit() {
        focus = nil
        isWorking = true
        Task {
            if isRegistering {
                await session.register(email: email, password: password)
            } else {
                await session.signIn(email: email, password: password)
            }
            isWorking = false
        }
    }
}
