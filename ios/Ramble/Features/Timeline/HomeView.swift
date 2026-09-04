import SwiftUI

/// The home screen: a chronological timeline with the record button floating
/// above it. Search and settings sit in the top bar so the record button is
/// the only thing competing for attention.
struct HomeView: View {
    @Environment(Session.self) private var session
    @State private var model = TimelineModel()
    @State private var showingRecorder = false
    @State private var showingSearch = false
    @State private var showingSettings = false
    @State private var selectedRamble: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.Palette.background.ignoresSafeArea()
                timeline
                // Fades the timeline out behind the floating button so text
                // scrolling underneath it never becomes unreadable.
                LinearGradient(
                    colors: [Theme.Palette.background.opacity(0), Theme.Palette.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
                .allowsHitTesting(false)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                recordButton
            }
            .navigationTitle("")
            .toolbar { toolbar }
            .toolbarBackground(Theme.Palette.background, for: .navigationBar)
            .navigationDestination(item: $selectedRamble) { id in
                RambleDetailView(rambleId: id)
            }
        }
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordView { CaptureQueue.shared.sync(); Task { await model.refresh() } }
        }
        .sheet(isPresented: $showingSearch) { SearchView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .task { await model.load() }
        // A ramble that finishes uploading should appear without a pull.
        .onReceive(NotificationCenter.default.publisher(for: .rambleUploaded)) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if CaptureQueue.shared.hasPending {
                    PendingUploadsBanner(queue: CaptureQueue.shared)
                        .padding(.horizontal, Theme.Metrics.screenPadding)
                        .padding(.bottom, 12)
                }

                if model.isLoading && model.days.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if model.days.isEmpty, let error = model.errorMessage {
                    // A failed load is not an empty account. Saying "nothing
                    // here yet" when the request failed would be a lie, and
                    // would hide a real problem behind a friendly screen.
                    EmptyStateView(
                        title: "Couldn't load your rambles",
                        message: error,
                        systemImage: "exclamationmark.triangle"
                    )
                    .padding(.top, 60)
                } else if model.days.isEmpty {
                    EmptyStateView(
                        title: "Nothing here yet",
                        message: "Press the button and start talking. Don't organize it — that's the point."
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.rambles) { ramble in
                                Button {
                                    selectedRamble = ramble.id
                                } label: {
                                    RambleCardView(ramble: ramble)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, Theme.Metrics.screenPadding)
                                .padding(.bottom, 10)
                            }
                        } header: {
                            DayHeader(label: day.label)
                        }
                    }

                    if model.canLoadMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .task { await model.loadMore() }
                    }
                }
            }
            .padding(.top, 8)
            // Clears the floating record button.
            .padding(.bottom, Theme.Metrics.recordButtonSize + 48)
        }
        .refreshable { await model.refresh() }
        .scrollIndicators(.hidden)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingSearch = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.muted)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            showingRecorder = true
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent)
                    .frame(width: Theme.Metrics.recordButtonSize, height: Theme.Metrics.recordButtonSize)
                    .shadow(color: Theme.Palette.accent.opacity(0.25), radius: 16, y: 6)
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(RecordButtonStyle())
        .padding(.bottom, 28)
        .accessibilityLabel("Start recording")
    }
}

/// A press should feel physical without being loud.
private struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct DayHeader: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .background(Theme.Palette.background)
    }
}

/// Shown while recordings are still on the device. Reassurance, not an error:
/// nothing is lost, it just hasn't been sent yet.
private struct PendingUploadsBanner: View {
    let queue: CaptureQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: queue.isOnline ? "arrow.up.circle" : "wifi.slash")
                .foregroundStyle(Theme.Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.pending.count == 1 ? "1 recording waiting" : "\(queue.pending.count) recordings waiting")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.text)
                Text(queue.isOnline ? "Uploading now" : "They'll send when you're back online")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer()
            if queue.isSyncing {
                ProgressView().controlSize(.small)
            }
        }
        .rambleCard()
    }
}
