import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var integrations: [APIClient.IntegrationList.Item] = []
    @State private var showingAdvanced = false
    @State private var confirmSignOut = false
    @State private var transcriptionQuality = TranscriptionQuality.preferred

    var body: some View {
        NavigationStack {
            List {
                if session.isSampleMode {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                MockBadge()
                                Text("Sample understanding")
                                    .font(Theme.Typography.body.weight(.medium))
                            }
                            Text("The server has no AI key configured, so extraction is a simple stand-in rather than real understanding. Search and everything else work normally.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.muted)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("You") {
                    if let account = session.account {
                        LabeledContent("Account", value: account.email)
                        Picker("I'm a", selection: profileBinding) {
                            ForEach(UserProfile.allCases, id: \.self) { profile in
                                Text(profile.label).tag(profile)
                            }
                        }
                    }
                }

                Section {
                    ForEach(integrations) { integration in
                        IntegrationRow(integration: integration) {
                            await toggle(integration)
                        }
                    }
                } header: {
                    Text("Connections")
                } footer: {
                    Text("Calendar and reminders happen on this device. Nothing about your calendar is sent to Ramble's servers.")
                }

                Section {
                    NavigationLink("Waiting to upload") { PendingUploadsView() }
                    if session.health?.hasCloudTranscription == true {
                        Picker("Transcription", selection: $transcriptionQuality) {
                            ForEach(TranscriptionQuality.allCases) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    if session.health?.hasCloudTranscription == true {
                        Text(transcriptionQuality.detail)
                    }
                }

                Section {
                    NavigationLink("Privacy and data") { PrivacyView() }
                    Toggle("Developer options", isOn: $showingAdvanced)
                    if showingAdvanced {
                        NavigationLink("Webhooks") { WebhooksView() }
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { integrations = (try? await APIClient.shared.integrations()) ?? [] }
            .onChange(of: transcriptionQuality) { _, quality in
                TranscriptionQuality.preferred = quality
            }
            .confirmationDialog("Sign out of Ramble?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await session.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("Recordings that haven't uploaded yet will stay on this device.")
            }
        }
    }

    private var profileBinding: Binding<UserProfile> {
        Binding(
            get: { session.account?.profile ?? .other },
            set: { profile in Task { _ = try? await APIClient.shared.updateProfile(profile) } }
        )
    }

    private func toggle(_ integration: APIClient.IntegrationList.Item) async {
        if integration.status == "connected" {
            try? await APIClient.shared.disconnectIntegration(integration.provider)
        } else {
            // Device integrations need the OS permission before the server is
            // told they are connected, or the first action would fail.
            switch integration.provider {
            case "apple_calendar":
                guard await DeviceActionRunner.shared.requestCalendarAccess() else { return }
            case "apple_reminders":
                guard await DeviceActionRunner.shared.requestRemindersAccess() else { return }
            default: break
            }
            try? await APIClient.shared.connectIntegration(integration.provider)
        }
        integrations = (try? await APIClient.shared.integrations()) ?? []
    }
}

private struct IntegrationRow: View {
    let integration: APIClient.IntegrationList.Item
    let toggle: () async -> Void

    @State private var isWorking = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                Text(integration.category)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            } else if !integration.available {
                Text("Soon")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            } else {
                Button(integration.status == "connected" ? "Disconnect" : "Connect") {
                    isWorking = true
                    Task {
                        await toggle()
                        isWorking = false
                    }
                }
                .font(Theme.Typography.secondary)
                .buttonStyle(.plain)
                .foregroundStyle(integration.status == "connected" ? Theme.Palette.muted : Theme.Palette.accent)
            }
        }
        .disabled(!integration.available)
    }
}

/// What is still on the device and hasn't reached the server.
private struct PendingUploadsView: View {
    @State private var queue = CaptureQueue.shared

    var body: some View {
        List {
            if queue.pending.isEmpty {
                Text("Everything's uploaded.")
                    .foregroundStyle(Theme.Palette.muted)
            } else {
                ForEach(queue.pending) { capture in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(capture.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text("\(capture.duration.durationLabel) · \(capture.lastError ?? "Waiting")")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                }
            }
        }
        .navigationTitle("Waiting to upload")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Retry now") { queue.sync() }
                .disabled(queue.pending.isEmpty)
        }
    }
}

private struct PrivacyView: View {
    @Environment(Session.self) private var session

    var body: some View {
        List {
            Section {
                Text("Ramble stores your recordings, transcripts, and everything extracted from them. Only you can read them.")
                    .font(Theme.Typography.secondary)
            }
            Section("How it works") {
                privacyRow("Your audio", "Stored privately. Played back through links that expire.")
                privacyRow("Transcription", session.isSampleMode
                    ? "Currently a local stand-in — no audio leaves the server."
                    : "Sent to a transcription provider to be turned into text.")
                privacyRow("Understanding", session.isSampleMode
                    ? "Currently a local stand-in rather than a real model."
                    : "Your transcript is sent to an AI provider to be structured.")
                privacyRow("Calendar and reminders", "Handled entirely on this device. Never sent to our servers.")
            }
            Section {
                Text("Nothing you record is used to train anyone's models.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .navigationTitle("Privacy and data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Typography.body)
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.vertical, 2)
    }
}

/// Advanced only. Most people should never see this screen.
private struct WebhooksView: View {
    var body: some View {
        List {
            Section {
                Text("Send an HTTP request whenever something happens in Ramble — a recording is processed, a task is created, an action runs.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Section("Events") {
                ForEach([
                    "ramble.created", "ramble.transcribed", "ramble.processed",
                    "task.created", "action.requested", "action.completed",
                ], id: \.self) { event in
                    Text(event)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Section {
                Text("Manage endpoints through the API: POST /v1/webhooks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.inline)
    }
}
