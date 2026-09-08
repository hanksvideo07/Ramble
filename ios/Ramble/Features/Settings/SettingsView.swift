import SwiftUI

/// Settings, written as a page rather than a control panel. Everything here
/// describes what the app actually does — nothing claims a behaviour the
/// implementation doesn't have.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var integrations: [APIClient.IntegrationList.Item] = []
    @State private var integrationsError: String?
    @State private var confirmSignOut = false
    @State private var transcriptionQuality = TranscriptionQuality.preferred
    @State private var appearance = AppearanceSetting.current
    @State private var queue = CaptureQueue.shared
    @State private var legal: APIClient.LegalLinks?
    @State private var exportedFile: ExportedData?
    @State private var isExporting = false
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @State private var diagnostics = EmbeddingDiagnostics.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xxl) {
                header
                if session.isSampleMode { sampleNotice }
                account
                work
                connections
                recording
                waysToStart
                onDeviceSearch
                appearanceSection
                privacy
                yourData
                signOut
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadIntegrations()
            legal = try? await APIClient.shared.legal()
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(url: file.url)
        }
        .onChange(of: transcriptionQuality) { _, quality in
            TranscriptionQuality.preferred = quality
        }
        .onChange(of: appearance) { _, value in value.apply() }
        .confirmationDialog(
            "Sign out of Ramble?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task {
                    await session.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Recordings that haven't uploaded yet stay on this device and will send when you sign back in.")
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task {
                    do {
                        try await APIClient.shared.deleteAccount()
                        await session.signOut()
                        dismiss()
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Every recording, every audio file, and everything found in them goes with it. This is immediate and cannot be undone.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text("Settings")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("How this works.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
        }
        .padding(.top, Theme.Metrics.sm)
    }

    private var sampleNotice: some View {
        StatusNotice(
            message: "Understanding is a stand-in right now",
            detail: "No model is configured on the server, so titles and extracted items are produced by a simple rule-based fallback. Your recordings, transcripts, and search are real.",
            systemImage: "flask"
        )
    }

    private var account: some View {
        Group {
            if let account = session.account {
                settingsSection("Account") {
                    row(label: "Signed in as", value: account.email)
                }
            }
        }
    }

    private var work: some View {
        settingsSection("Type of work") {
            VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                Text("This changes what Ramble pays attention to when it reads a recording back. It is not a folder, and nothing is filed under it.")
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: 6) {
                    ForEach(UserProfile.allCases, id: \.self) { option in
                        let selected = session.account?.profile == option
                        Button {
                            Task { _ = try? await APIClient.shared.updateProfile(option) }
                        } label: {
                            Text(option.label)
                                .rambleType(Theme.Text.chip)
                                .foregroundStyle(selected ? Theme.Palette.onAction : Theme.Palette.ink)
                                .padding(.horizontal, Theme.Metrics.md)
                                .padding(.vertical, 8)
                                .background(selected ? Theme.Palette.action : Theme.Palette.subtle)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: Theme.Metrics.labelRadius,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private var connections: some View {
        settingsSection("Connected services") {
            VStack(alignment: .leading, spacing: 0) {
                if let integrationsError {
                    StatusNotice(
                        message: "Couldn't load your connections",
                        detail: integrationsError,
                        tone: .warning,
                        systemImage: "exclamationmark.triangle",
                        actionTitle: "Retry",
                        action: { Task { await loadIntegrations() } }
                    )
                }

                ForEach(available) { integration in
                    IntegrationRow(integration: integration) { await toggle(integration) }
                }

                if !unavailable.isEmpty {
                    Text("Not available yet")
                        .rambleType(Theme.Text.eyebrow)
                        .foregroundStyle(Theme.Palette.secondary)
                        .padding(.top, Theme.Metrics.xl)
                        .padding(.bottom, Theme.Metrics.sm)
                    ForEach(unavailable) { integration in
                        HStack {
                            Text(integration.name)
                                .rambleType(Theme.Text.body)
                                .foregroundStyle(Theme.Palette.secondary)
                            Spacer()
                            Text("Soon")
                                .rambleType(Theme.Text.meta)
                                .foregroundStyle(Theme.Palette.secondary)
                        }
                        .padding(.vertical, Theme.Metrics.md)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                }

                Text("Calendar and reminders happen on this device through Apple's own frameworks. Nothing about your calendar is sent to Ramble's servers.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Metrics.md)
            }
        }
    }

    private var recording: some View {
        settingsSection("Recording") {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
NavigationLink(value: AppDestination.uploads) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waiting to upload")
                                .rambleType(Theme.Text.body)
                                .foregroundStyle(Theme.Palette.ink)
                            Text(queue.pending.isEmpty
                                 ? "Everything's uploaded."
                                 : queue.pending.count == 1
                                   ? "1 recording is still on this phone."
                                   : "\(queue.pending.count) recordings are still on this phone.")
                                .rambleType(Theme.Text.meta)
                                .foregroundStyle(Theme.Palette.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.secondary)
                    }
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if session.health?.hasCloudTranscription == true {
                    VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                        Text("Transcription")
                            .rambleType(Theme.Text.body)
                            .foregroundStyle(Theme.Palette.ink)
                        Picker("Transcription", selection: $transcriptionQuality) {
                            ForEach(TranscriptionQuality.allCases) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(transcriptionQuality.detail)
                            .rambleType(Theme.Text.meta)
                            .foregroundStyle(Theme.Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var appearanceSection: some View {
        settingsSection("Appearance") {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceSetting.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var privacy: some View {
        settingsSection("Your voice and your data") {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                privacyRow(
                    "Your recordings",
                    "The audio is uploaded and stored on Ramble's server so you can play it back. Playback goes through links that expire."
                )
                privacyRow(
                    "Turning speech into text",
                    session.isSampleMode
                        ? "Currently a local stand-in \u{2014} no audio leaves the server for transcription."
                        : "Your phone transcribes when it can. Otherwise the audio goes to a transcription provider to be turned into text."
                )
                privacyRow(
                    "Making sense of it",
                    session.isSampleMode
                        ? "Currently a rule-based stand-in rather than a real model."
                        : "Your transcript is sent to a language model to be structured. Ramble asks its providers not to retain or train on it."
                )
                privacyRow(
                    "Calendar and reminders",
                    "Handled entirely on this device through Apple's frameworks. Your calendar is never sent to Ramble's servers."
                )
                privacyRow(
                    "Actions that reach other people",
                    "Always require you to say yes first, every single time. Nothing is ever sent on your behalf without that."
                )
            }
        }
    }

    /// Where the record button can live besides inside the app.
    ///
    /// All three already work the moment the app is installed — they are
    /// system settings, not app settings — which is exactly why they need
    /// saying. Nobody goes looking in iOS Settings for a button they don't
    /// know exists.
    private var waysToStart: some View {
        settingsSection("Other ways to start") {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                wayRow(
                    "The Action Button",
                    "iOS Settings \u{203A} Action Button, swipe to Controls, tap the control and choose Ramble. Then a long press on the side of the phone starts recording.",
                    systemImage: "button.horizontal.top.press"
                )
                wayRow(
                    "Control Centre",
                    "Swipe down from the top-right, press and hold, Add a Control, then search for Ramble.",
                    systemImage: "switch.2"
                )
                wayRow(
                    "Siri and Shortcuts",
                    "Say \u{201C}Start a Ramble\u{201D}, or use the Start a ramble action in the Shortcuts app.",
                    systemImage: "waveform"
                )
                wayRow(
                    "Your Home and Lock Screen",
                    "Long-press the wallpaper to add the Ramble widget. The Lock Screen one records with a single tap, without unlocking.",
                    systemImage: "square.grid.2x2"
                )
            }
        }
    }

    private func wayRow(_ title: String, _ detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.Palette.action)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .rambleType(Theme.Text.bodyStrong)
                    .foregroundStyle(Theme.Palette.ink)
                Text(detail)
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether this phone can do semantic search itself.
    ///
    /// It was built, wired, and never run on real hardware — a simulator
    /// cannot answer the question. This is the button that does.
    private var onDeviceSearch: some View {
        settingsSection("Search on this device") {
            VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                Text("Ramble prefers to work out what your words mean on the phone itself, so nothing has to be sent anywhere. This checks whether that actually works here.")
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = diagnostics.summary {
                    StatusNotice(
                        message: summary,
                        tone: {
                            switch diagnostics.state {
                            case .failed: .warning
                            case .downloading, .running: .working
                            case .passed(let r): r.isUsable ? .neutral : .warning
                            case .idle: .neutral
                            }
                        }(),
                        systemImage: {
                            switch diagnostics.state {
                            case .failed: "exclamationmark.triangle"
                            case .passed(let r): r.isUsable ? "checkmark.circle" : "exclamationmark.triangle"
                            default: nil
                            }
                        }()
                    )
                }

                if case .passed(let result) = diagnostics.state {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.dimension) dimensions \u{00B7} revision \(result.revision)")
                        if !result.isUsable {
                            Text("Set EMBEDDING_PROVIDER=openrouter on the server to have it embed instead.")
                        }
                    }
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                let busy = diagnostics.state == .downloading || diagnostics.state == .running
                Button(busy ? "Checking\u{2026}" : "Check it") {
                    Task { await diagnostics.run() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(busy)
            }
        }
    }

    /// The promises the privacy policy makes, made real. A policy that says
    /// your data is exportable and deletable from inside the app is only true
    /// if these are here.
    private var yourData: some View {
        settingsSection("Your data") {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                if let deleteError {
                    StatusNotice(
                        message: "Couldn't delete the account",
                        detail: deleteError,
                        tone: .warning,
                        systemImage: "exclamationmark.triangle"
                    )
                }

                dataRow(
                    title: "Export everything",
                    detail: "Every recording, transcript, and extracted item, as JSON.",
                    action: isExporting ? nil : "Export"
                ) {
                    Task { await export() }
                }

                if let legal {
                    if !legal.complete {
                        StatusNotice(
                            message: "These documents aren't finished",
                            detail: "The publisher name, contact address, and governing law are still placeholders. Fill them in before submitting to the App Store.",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    linkRow("Privacy policy", legal.privacyURL)
                    linkRow("Terms of service", legal.termsURL)
                }

                NavigationLink(value: AppDestination.agents) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Let other software in")
                                .rambleType(Theme.Text.body)
                                .foregroundStyle(Theme.Palette.ink)
                            Text("Connect an AI assistant, or send events to your own tools.")
                                .rambleType(Theme.Text.meta)
                                .foregroundStyle(Theme.Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.secondary)
                    }
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                dataRow(
                    title: "Delete your account",
                    detail: "Removes everything, immediately and permanently.",
                    action: "Delete",
                    destructive: true
                ) {
                    confirmDelete = true
                }
            }
        }
    }

    private func dataRow(
        title: String,
        detail: String,
        action: String?,
        destructive: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                Text(detail)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Metrics.md)
            if let action {
                Button(action, action: perform)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(destructive ? Theme.Palette.warning : Theme.Palette.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func linkRow(_ title: String, _ urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack {
                        Text(title)
                            .rambleType(Theme.Text.body)
                            .foregroundStyle(Theme.Palette.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.secondary)
                    }
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await APIClient.shared.exportEverything()
            let url = FileManager.default.temporaryDirectory
                .appending(path: "ramble-export-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url)
            exportedFile = ExportedData(url: url)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private var signOut: some View {
        Button("Sign out") { confirmSignOut = true }
            .buttonStyle(SecondaryButtonStyle())
    }

    // MARK: - Building blocks

    private func settingsSection(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
            SectionHeading(title)
            content()
        }
        .padding(.top, Theme.Metrics.lg)
        .overlay(alignment: .top) { Hairline() }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .rambleType(Theme.Text.body)
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: Theme.Metrics.md)
            Text(value)
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.xs) {
            Text(title)
                .rambleType(Theme.Text.bodyStrong)
                .foregroundStyle(Theme.Palette.ink)
            Text(detail)
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Data

    private var available: [APIClient.IntegrationList.Item] {
        integrations.filter(\.available)
    }

    private var unavailable: [APIClient.IntegrationList.Item] {
        integrations.filter { !$0.available }
    }

    private func loadIntegrations() async {
        do {
            integrations = try await APIClient.shared.integrations()
            integrationsError = nil
        } catch {
            integrationsError = error.localizedDescription
        }
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
        await loadIntegrations()
    }
}

private struct IntegrationRow: View {
    let integration: APIClient.IntegrationList.Item
    let toggle: () async -> Void

    @State private var isWorking = false

    private var isConnected: Bool { integration.status == "connected" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .rambleType(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.ink)
                Text(isConnected ? "Connected" : integration.category)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Button(isConnected ? "Disconnect" : "Connect") {
                    isWorking = true
                    Task {
                        await toggle()
                        isWorking = false
                    }
                }
                .rambleType(Theme.Text.meta)
                .foregroundStyle(isConnected ? Theme.Palette.secondary : Theme.Palette.action)
                .buttonStyle(.plain)
                .frame(minHeight: Theme.Metrics.minimumTouchTarget)
            }
        }
        .padding(.vertical, Theme.Metrics.sm)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Light, dark, or whatever the phone is doing. Stored on the device, since it
/// is a property of this screen and not of the account.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private static let key = "app.ramble.appearance"

    static var current: AppearanceSetting {
        UserDefaults.standard.string(forKey: key).flatMap(AppearanceSetting.init) ?? .system
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        NotificationCenter.default.post(name: .appearanceChanged, object: nil)
    }
}

extension Notification.Name {
    static let appearanceChanged = Notification.Name("app.ramble.appearanceChanged")
}


/// The exported archive, on its way to wherever the person wants to keep it.
struct ExportedData: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet, which is how a file leaves the app.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#if canImport(UIKit)
import UIKit
#endif
