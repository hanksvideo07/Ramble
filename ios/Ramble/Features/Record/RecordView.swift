import SwiftUI

/// Full-screen capture. Nothing on this screen competes with speaking: a
/// timer, a waveform, and a stop button.
///
/// On stop it dismisses immediately — the guide is explicit that the user
/// should never wait on processing — and the new card appears in the timeline
/// already in its processing state.
struct RecordView: View {
    /// Called once the recording has been handed to the upload queue.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = Recorder()
    @State private var permissionDenied = false
    @State private var hasStarted = false

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer()

                if permissionDenied {
                    micDeniedState
                } else if case .failed(let message) = recorder.state {
                    // Audio is the source of truth, so a capture that never
                    // started must say so loudly rather than sitting on
                    // "Getting ready…" while the person talks to nothing.
                    recordingFailedState(message)
                } else {
                    Text(recorder.elapsed.durationLabel)
                        .font(Theme.Typography.timer)
                        .foregroundStyle(Theme.Palette.text)
                        .contentTransition(.numericText())

                    WaveformView(levels: recorder.levels, isActive: recorder.isRecording)
                        .frame(height: 72)
                        .padding(.horizontal, 32)
                        .padding(.top, 24)

                    if recorder.isTranscribing {
                        LiveTranscriptView(
                            settled: recorder.transcribedText,
                            volatile: recorder.volatileText
                        )
                        .padding(.top, 20)
                    } else {
                        Text(recorder.isRecording ? "Listening…" : "Getting ready…")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.muted)
                            .padding(.top, 20)
                    }
                }

                Spacer()

                if !permissionDenied, !isFailed {
                    stopButton
                        .padding(.bottom, 56)
                }
            }
        }
        .task { await begin() }
        // Stopping the recorder on disappear guarantees the audio session is
        // released even if the view goes away unexpectedly.
        .onDisappear { if recorder.isRecording { finish() } }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button("Cancel") {
                recorder.cancel()
                dismiss()
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.muted)

            Spacer()

            Button("Done") { finish() }
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.text)
                .opacity(recorder.isRecording ? 1 : 0.4)
                .disabled(!recorder.isRecording)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, 20)
    }

    private var stopButton: some View {
        Button { finish() } label: {
            ZStack {
                Circle()
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 2)
                    .frame(width: 84, height: 84)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Palette.accent)
                    .frame(width: 30, height: 30)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }

    private var isFailed: Bool {
        if case .failed = recorder.state { return true }
        return false
    }

    private func recordingFailedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
            Text("Couldn't start recording")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.text)
            Text(message)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
                .multilineTextAlignment(.center)
            Button("Try again") {
                recorder.reset()
                recorder.start()
            }
            .font(Theme.Typography.body.weight(.medium))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.top, 4)
            Button("Close") { dismiss() }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 40)
    }

    private var micDeniedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.Palette.muted)
            Text("Ramble needs your microphone")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.text)
            Text("Turn it on in Settings and come back.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(Theme.Typography.body)
            .padding(.top, 4)
            Button("Not now") { dismiss() }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Lifecycle

    private func begin() async {
        guard !hasStarted else { return }
        hasStarted = true

        if !Recorder.hasPermission {
            let granted = await Recorder.requestPermission()
            guard granted else {
                permissionDenied = true
                return
            }
        }
        recorder.start()
    }

    /// Hands the file to the upload queue and leaves immediately. Everything
    /// after this point happens without the user waiting.
    private func finish() {
        recorder.stop()
        if case .finished(let url, let duration) = recorder.state {
            CaptureQueue.shared.enqueue(
                fileURL: url,
                recordedAt: Date().addingTimeInterval(-duration),
                duration: duration
            )
            onFinish()
        }
        dismiss()
    }
}

/// Live audio levels.
///
/// Bars scroll in from the right so the newest sound is nearest the eye, and
/// older bars fall away exponentially rather than linearly. A linear falloff
/// leaves a long straight ramp behind every syllable — the shape reads as a
/// row of triangles instead of a voice — whereas an exponential one collapses
/// the tail quickly and keeps the leading edge sharp.
struct WaveformView: View {
    let levels: [CGFloat]
    var isActive: Bool

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3

    /// Per-bar decay applied across the visible window, newest to oldest.
    /// 0.90 leaves the newest third clearly lit and the oldest barely there.
    private let trailDecay: CGFloat = 0.90

    var body: some View {
        GeometryReader { geometry in
            let capacity = max(1, Int(geometry.size.width / (barWidth + spacing)))
            let shown = Array(levels.suffix(capacity))
            let padding = max(0, capacity - shown.count)

            HStack(alignment: .center, spacing: spacing) {
                // Leading blanks keep new bars entering from the right rather
                // than the whole waveform re-centring on every sample.
                ForEach(0..<padding, id: \.self) { _ in
                    bar(height: 2, opacity: 0.12, scale: 1)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { index, level in
                    // Age measured from the newest bar, so index 0 of the
                    // visible window is the oldest and fades most.
                    let age = shown.count - 1 - index
                    let falloff = pow(trailDecay, CGFloat(age))
                    bar(
                        height: max(2, level * geometry.size.height * falloff),
                        opacity: Double(max(0.10, falloff)),
                        scale: falloff
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            .animation(.linear(duration: 0.05), value: levels.count)
        }
    }

    private func bar(height: CGFloat, opacity: Double, scale: CGFloat) -> some View {
        Capsule()
            .fill(isActive ? Theme.Palette.accent : Theme.Palette.muted)
            .frame(width: barWidth, height: height)
            .opacity(opacity)
    }
}

/// The words as they are spoken.
///
/// Text scrolls up as it accumulates and fades toward the top, so the newest
/// line is always the clearest thing on screen. The tail the recognizer is
/// still revising is shown dimmer than settled text, which makes the
/// correcting-itself behaviour read as normal rather than as a glitch.
struct LiveTranscriptView: View {
    let settled: String
    let volatile: String

    private var combined: String {
        [settled, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Pushes the first words to the bottom so text rises into
                    // view rather than starting at the top and growing down.
                    Spacer(minLength: 0).frame(height: 60)

                    (Text(settled)
                        .foregroundStyle(Theme.Palette.text)
                     + Text(settled.isEmpty ? "" : " ")
                     + Text(volatile)
                        .foregroundStyle(Theme.Palette.muted))
                        .font(.system(size: 17, weight: .regular))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 160)
            // Fades the top of the scroll view so older lines dissolve rather
            // than being cut off by a hard edge.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.35), location: 0.28),
                        .init(color: .black, location: 0.6),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.horizontal, 28)
            .onChange(of: combined) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "live-transcript-bottom"
}

#if canImport(UIKit)
import UIKit
#endif
