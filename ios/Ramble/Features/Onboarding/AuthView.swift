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
            Theme.Palette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Text("Ramble")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.Palette.text)
                Text("Just ramble.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .fieldStyle()

                    SecureField("Password", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }
                        .fieldStyle()
                }
                .padding(.top, 32)

                if isRegistering && !password.isEmpty && password.count < 8 {
                    Text("At least 8 characters.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.muted)
                        .padding(.top, 6)
                }

                if let error = session.errorMessage {
                    Text(error)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.top, 10)
                }

                Button(action: submit) {
                    HStack {
                        if isWorking { ProgressView().controlSize(.small).tint(.white) }
                        Text(isRegistering ? "Create account" : "Sign in")
                    }
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSubmit ? Theme.Palette.accent : Theme.Palette.muted.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
                }
                .disabled(!canSubmit)
                .padding(.top, 20)

                Button(isRegistering ? "I already have an account" : "Create an account") {
                    withAnimation { isRegistering.toggle() }
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .onTapGesture { focus = nil }
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

private extension View {
    func fieldStyle() -> some View {
        self
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            )
    }
}
