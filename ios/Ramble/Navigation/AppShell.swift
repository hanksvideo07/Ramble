import SwiftUI

/// Where a push can go. One enum shared by every stack, so a citation, an
/// entity chip, and a deep link all resolve to the same screens.
enum AppDestination: Hashable {
    case ramble(String)
    /// A recording opened at a particular passage — how a citation and a
    /// source quote get you to the exact words rather than the top of a page.
    case rambleQuoting(id: String, quote: String)
    case entity(String)
    case inbox
    case activity
    case agents
    case settings
}

extension View {
    /// Installs the shared destinations on a stack. Every screen that can push
    /// uses this rather than declaring its own, which is what previously let a
    /// person open an entity from one screen but not another.
    func rambleDestinations() -> some View {
        navigationDestination(for: AppDestination.self) { destination in
            switch destination {
            case .ramble(let id): RambleDetailView(rambleId: id)
            case .rambleQuoting(let id, let quote):
                RambleDetailView(rambleId: id, highlighting: quote)
            case .entity(let id): EntityDetailView(entityId: id)
            case .inbox: InboxView()
            case .activity: ActivityView()
            case .agents: AgentsView()
            case .settings: SettingsView()
            }
        }
    }
}

/// The three places you can be, plus recording — which is not a place but an
/// action, and so lives above the bar rather than in it.
enum Tab: Hashable, CaseIterable {
    case rambles, ask, people

    var title: String {
        switch self {
        case .rambles: "Rambles"
        case .ask: "Ask"
        case .people: "People"
        }
    }

    var systemImage: String {
        switch self {
        case .rambles: "list.bullet"
        case .ask: "magnifyingglass"
        case .people: "person.2"
        }
    }
}

/// The app shell.
///
/// All three destinations stay alive behind the scenes rather than being torn
/// down on every switch, so scroll position, a half-typed question, and an
/// open navigation stack survive a trip to another tab. Processing arriving in
/// the background must never move the page under someone's thumb.
struct AppShell: View {
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: Tab = .rambles
    @State private var showingRecorder = false
    @State private var showingCompose = false
    @State private var composeWithClipboard = false
    @State private var deepLink = DeepLink.shared

    // Held here so the models and their navigation stacks outlive a tab switch.
    @State private var timeline = TimelineModel()
    @State private var ask = AskModel()
    @State private var people = PeopleModel()
    @State private var ramblesPath = NavigationPath()
    @State private var askPath = NavigationPath()
    @State private var peoplePath = NavigationPath()

    var body: some View {
        ZStack {
            Theme.Palette.paper.ignoresSafeArea()

            pane(.rambles) {
                NavigationStack(path: $ramblesPath) {
                    RamblesView(model: timeline, startRecording: { showingRecorder = true })
                        .rambleDestinations()
                }
            }
            pane(.ask) {
                NavigationStack(path: $askPath) {
                    AskView(model: ask)
                        .rambleDestinations()
                }
            }
            pane(.people) {
                NavigationStack(path: $peoplePath) {
                    PeopleView(model: people)
                        .rambleDestinations()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(
                tab: $tab,
                startRecording: { showingRecorder = true },
                startWriting: {
                    composeWithClipboard = false
                    showingCompose = true
                }
            )
        }
        .background(Theme.Palette.paper)
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordView {
                // Stopping always lands you back in the history, wherever you
                // pressed record from. The new entry is the thing you want to
                // see, not whatever screen you happened to be on.
                tab = .rambles
                CaptureQueue.shared.sync()
                Task { await timeline.refresh() }
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(startWithClipboard: composeWithClipboard) {
                tab = .rambles
                Task { await timeline.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rambleUploaded)) { _ in
            Task { await timeline.refresh() }
        }
        .onChange(of: deepLink.pending, initial: true) { _, destination in
            guard let destination else { return }
            handle(destination)
            deepLink.pending = nil
        }
    }

    /// Keeps a tab in the hierarchy but out of the way when it isn't showing.
    /// Hidden panes are also hidden from VoiceOver, which would otherwise read
    /// three screens' worth of content at once.
    @ViewBuilder
    private func pane(_ which: Tab, @ViewBuilder content: () -> some View) -> some View {
        let isActive = tab == which
        content()
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }

    private func handle(_ destination: DeepLink.Destination) {
        switch destination {
        case .record:
            showingRecorder = true
        case .compose(let paste):
            tab = .rambles
            composeWithClipboard = paste
            showingCompose = true
        case .search:
            tab = .ask
        case .ask(let question):
            tab = .ask
            ask.submit(question)
        case .ramble(let id):
            tab = .rambles
            ramblesPath.append(AppDestination.ramble(id))
        case .entity(let id):
            tab = .people
            peoplePath.append(AppDestination.entity(id))
        }
    }
}

// MARK: - Bottom bar

/// The record button, then the three destinations. Nothing else on the home
/// screen is allowed to compete with the button, so the bar under it is drawn
/// as quietly as it can be while still being legible.
private struct BottomBar: View {
    @Binding var tab: Tab
    let startRecording: () -> Void
    let startWriting: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RecordDock(record: startRecording, write: startWriting)
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 17, weight: .regular))
                            Text(item.title)
                                .rambleType(Theme.Text.meta)
                        }
                        .foregroundStyle(tab == item ? Theme.Palette.ink : Theme.Palette.secondary)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.top, Theme.Metrics.sm)
            .padding(.bottom, Theme.Metrics.xs)
        }
        // Fades the content out behind the dock so text scrolling under the
        // record button never becomes unreadable.
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Theme.Palette.paper.opacity(0), Theme.Palette.paper],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)
                Theme.Palette.paper
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// The primary action, and the only sentence on the home screen that tells
/// you what to do with it.
struct RecordDock: View {
    let record: () -> Void
    let write: () -> Void

    var body: some View {
        VStack(spacing: Theme.Metrics.sm) {
            RecordingControl(action: record)

            // Speaking stays the headline; writing is offered beside it rather
            // than as an equal, so the button still reads as the one thing to
            // press.
            HStack(spacing: 6) {
                Text("Just talk.")
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.Palette.secondary)
                Text("or")
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.secondary.opacity(0.7))
                Button("write it", action: write)
                    .rambleType(Theme.Text.meta)
                    .foregroundStyle(Theme.Palette.action)
                    .buttonStyle(.plain)
            }
            .frame(minHeight: 28)
        }
        .padding(.top, Theme.Metrics.sm)
    }
}

/// The record button: a forest-green circle inside a soft halo.
struct RecordingControl: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.recordHalo)
                    .frame(
                        width: Theme.Metrics.recordButton + 18,
                        height: Theme.Metrics.recordButton + 18
                    )
                Circle()
                    .fill(Theme.Palette.action)
                    .frame(width: Theme.Metrics.recordButton, height: Theme.Metrics.recordButton)
                Image(systemName: "mic")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.Palette.onAction)
            }
        }
        .buttonStyle(PressScale(reduceMotion: reduceMotion))
        .accessibilityLabel("Start recording")
        .accessibilityHint("Records what you say. Nothing to choose first.")
    }
}

/// A press should feel physical without being loud.
struct PressScale: ButtonStyle {
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
