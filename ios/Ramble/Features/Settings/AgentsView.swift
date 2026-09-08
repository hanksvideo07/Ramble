import SwiftUI

/// Connecting Ramble to other software: an AI agent over MCP, or a webhook.
///
/// Deliberately tucked behind Settings rather than given a place in the main
/// navigation. The guide is explicit that this stays an advanced setting and
/// must not complicate the ordinary flow, and almost nobody needs it.
struct AgentsView: View {
    @State private var webhooks: [APIClient.WebhookList.Webhook] = []
    @State private var availableEvents: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingNew = false
    @State private var createdSecret: CreatedSecret?
    @State private var copiedEndpoint = false
    @State private var revealToken = false
    @State private var token: String?

    struct CreatedSecret: Identifiable {
        let url: String
        let secret: String
        var id: String { url }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.xxl) {
                header
                mcp
                webhookSection
            }
            .screenPadding()
            .padding(.bottom, Theme.Metrics.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showingNew) {
            NewWebhookSheet(availableEvents: availableEvents) { url, events in
                await create(url: url, events: events)
            }
        }
        .sheet(item: $createdSecret) { created in
            SecretSheet(created: created)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            Text("Advanced")
                .rambleType(Theme.Text.eyebrow)
                .foregroundStyle(Theme.Palette.secondary)
            Text("Let other software in.")
                .rambleType(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text("Almost nobody needs this. It's here for connecting an AI assistant or your own tools.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Metrics.sm)
    }

    private var mcp: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            SectionHeading("For an AI assistant")
            Text("Point an MCP client at this address and it can search your recordings and ask questions about them. It can also add a thought on your behalf.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(APIClient.shared.mcpEndpoint)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.Palette.ink)
                .textSelection(.enabled)
                .padding(Theme.Metrics.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.subtle)
                .clipShape(
                    RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                )

            Button(copiedEndpoint ? "Copied" : "Copy address") {
                UIPasteboard.general.string = APIClient.shared.mcpEndpoint
                copiedEndpoint = true
            }
            .buttonStyle(SecondaryButtonStyle())

            tokenRow

            // The one thing a person should understand before doing this.
            StatusNotice(
                message: "It can read, and it can add. It cannot approve.",
                detail: "An assistant connected here can see everything you've recorded. It can never approve an action, send anything, or delete anything — those still need you, in this app.",
                systemImage: "hand.raised"
            )
        }
    }

    /// The access token, hidden until asked for.
    ///
    /// It is the key to everything this account holds, so it is not printed on
    /// a screen someone might be showing to a room. Revealing it is a
    /// deliberate act, and what it can do is stated next to it.
    @ViewBuilder
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
            SectionHeading("Access token")
            if revealToken, let token {
                Text(token)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.Palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(Theme.Metrics.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.subtle)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                    )
                Button("Copy token") { UIPasteboard.general.string = token }
                    .buttonStyle(SecondaryButtonStyle())
                Text("Anything holding this can read everything you have recorded. Treat it like a password.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Show my token") {
                    Task {
                        token = await APIClient.shared.currentToken
                        revealToken = true
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading("Webhooks")
                Button("Add") { showingNew = true }
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.Metrics.minimumTouchTarget)
            }

            Text("Ramble will POST to an address of yours whenever something happens — a recording is processed, a task is created, an action runs. Each delivery is signed.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                StatusNotice(
                    message: "Couldn't load these",
                    detail: errorMessage,
                    tone: .warning,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    action: { Task { await load() } }
                )
            } else if isLoading {
                StatusNotice(message: "Loading\u{2026}", tone: .working)
            } else if webhooks.isEmpty {
                Text("None yet.")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(webhooks) { hook in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hook.url)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(hook.events.joined(separator: ", "))
                                    .rambleType(Theme.Text.meta)
                                    .foregroundStyle(Theme.Palette.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: Theme.Metrics.md)
                            Button("Remove") {
                                Task { await remove(hook) }
                            }
                            .rambleType(Theme.Text.meta)
                            .foregroundStyle(Theme.Palette.warning)
                            .buttonStyle(.plain)
                            .frame(minHeight: Theme.Metrics.minimumTouchTarget)
                        }
                        .padding(.vertical, Theme.Metrics.md)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.webhooks()
            webhooks = result.webhooks
            availableEvents = result.availableEvents
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create(url: String, events: [String]) async {
        do {
            let created = try await APIClient.shared.createWebhook(url: url, events: events)
            // Shown once and never again, so it is put in front of the person
            // immediately rather than mentioned in passing.
            createdSecret = CreatedSecret(url: created.url, secret: created.secret)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ hook: APIClient.WebhookList.Webhook) async {
        do {
            try await APIClient.shared.deleteWebhook(id: hook.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewWebhookSheet: View {
    let availableEvents: [String]
    let create: (String, [String]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var selected: Set<String> = []
    @State private var isSaving = false

    private var canSave: Bool {
        URL(string: url)?.scheme?.hasPrefix("http") == true && !selected.isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.xl) {
                    VStack(alignment: .leading, spacing: Theme.Metrics.sm) {
                        SectionHeading("Where to send it")
                        TextField("https://example.com/hooks/ramble", text: $url)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Theme.Palette.ink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(Theme.Metrics.md)
                            .background(Theme.Palette.raised)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                                    .strokeBorder(Theme.Palette.divider, lineWidth: 1)
                            )
                            .clipShape(
                                RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                            )
                    }

                    VStack(alignment: .leading, spacing: Theme.Metrics.md) {
                        SectionHeading("When to send it")
                        FlowLayout(spacing: 6) {
                            ForEach(availableEvents, id: \.self) { event in
                                let on = selected.contains(event)
                                Button {
                                    if on { selected.remove(event) } else { selected.insert(event) }
                                } label: {
                                    Text(event)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(on ? Theme.Palette.onAction : Theme.Palette.secondary)
                                        .padding(.horizontal, Theme.Metrics.md)
                                        .padding(.vertical, 7)
                                        .background(on ? Theme.Palette.action : Theme.Palette.subtle)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: Theme.Metrics.labelRadius,
                                                style: .continuous
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .screenPadding()
                .padding(.vertical, Theme.Metrics.lg)
            }
            .background(Theme.Palette.paper)
            .navigationTitle("New webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isSaving = true
                        Task {
                            await create(url, Array(selected))
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? Theme.Palette.action : Theme.Palette.secondary)
                }
            }
        }
    }
}

/// The signing secret, shown once because that is the only time it exists in
/// readable form.
private struct SecretSheet: View {
    let created: AgentsView.CreatedSecret
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
                Text("Copy this now.")
                    .rambleType(Theme.Text.pageTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Text("It's how you'll check a delivery really came from Ramble. It is not stored in readable form and cannot be shown again.")
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(created.secret)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.Palette.ink)
                    .textSelection(.enabled)
                    .padding(Theme.Metrics.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.subtle)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Metrics.inputRadius, style: .continuous)
                    )

                Button("Copy") { UIPasteboard.general.string = created.secret }
                    .buttonStyle(PrimaryButtonStyle())
                Spacer()
            }
            .screenPadding()
            .padding(.top, Theme.Metrics.xl)
            .background(Theme.Palette.paper)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#if canImport(UIKit)
import UIKit
#endif
