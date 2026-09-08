import SwiftUI

/// Capture.
///
/// A timer, a waveform, and one control. Nothing to choose, nothing to read,
/// nothing to navigate — the whole promise of the product is that this screen
/// asks nothing of you.
///
/// Stopping dismisses immediately. The recording is durable on the device
/// before anything is sent, and the new entry appears in the history in its
/// processing state.
struct RecordView: View {
    /// Called once the recording has been handed to the upload queue.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder = Recorder()
    @State private var permissionDenied = false
    @State private var hasStarted = false
    /// The beat between stopping and leaving. Nil while recording.
    @State private var captured: TimeInterval?

    var body: some View {
        ZStack {
            Theme.Palette.captureSurface.ignoresSafeArea()

            if let captured {
                CapturedMoment(duration: captured)
            } else if permissionDenied {
                micDenied
            } else if case .failed(let message) = recorder.state {
                // Audio is the source of truth. A capture that never started
                // has to say so loudly rather than sitting on a timer while
                // the person talks to nothing.
                captureFailed(message)
            } else {
                capturing
            }
        }
        .task { await begin() }
        // Stopping on disappear guarantees the audio session is released even
        // if the view goes away unexpectedly.
        .onDisappear { if recorder.isRecording { finish() } }
    }

    // MARK: - Recording

    private var capturing: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(recorder.elapsed.durationLabel)
                .rambleType(Theme.Text.timer)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.ink)
                .contentTransition(.numericText())
                .accessibilityLabel("Recording, \(Int(recorder.elapsed)) seconds")

            RecordingWaveform(levels: recorder.levels, isActive: recorder.isRecording)
                .frame(height: 96)
                .padding(.horizontal, Theme.Metrics.xxl)
                .padding(.top, Theme.Metrics.xxl)

            Spacer()

            Button { finish() } label: {
                ZStack {
                    Circle()
                        .fill(Theme.Palette.paper.opacity(0.7))
                        .frame(width: 66, height: 66)
                        .overlay(Circle().strokeBorder(Theme.Palette.divider, lineWidth: 1))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.Palette.ink)
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(PressScale(reduceMotion: reduceMotion))
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Saves this and takes you back.")
            .padding(.bottom, 72)
        }
    }

    // MARK: - Recovery states

    private func captureFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.Palette.warning)
            Text("Couldn't start recording.")
                .rambleType(Theme.Text.pageTitle)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Metrics.sm) {
                Button("Try again") {
                    recorder.reset()
                    recorder.start()
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Not now") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, Theme.Metrics.sm)
        }
        .screenPadding()
    }

    private var micDenied: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.lg) {
            Image(systemName: "mic.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.Palette.secondary)
            Text("Ramble needs your microphone.")
                .rambleType(Theme.Text.pageTitle)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("It's the only thing the app does. Turn it on in Settings under Ramble \u{203A} Microphone, then come back and press record.")
                .rambleType(Theme.Text.supporting)
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Metrics.sm) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Not now") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, Theme.Metrics.sm)
        }
        .screenPadding()
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
    /// after this happens without the person waiting on it.
    /// Hands the file to the upload queue and leaves.
    ///
    /// The dismissal waits about a second on a beat that says the recording
    /// exists. Stopping used to drop straight back to the list, which after
    /// speaking for two minutes felt like the app had shrugged. The work is
    /// already queued before the beat starts, so nothing waits on it — if the
    /// view goes away early the recording is still safe.
    private func finish() {
        guard captured == nil else { return }
        recorder.stop()

        guard case .finished(let url, let duration) = recorder.state else {
            dismiss()
            return
        }

        CaptureQueue.shared.enqueue(
            fileURL: url,
            recordedAt: Date().addingTimeInterval(-duration),
            duration: duration
        )
        onFinish()

        if reduceMotion {
            dismiss()
            return
        }

        withAnimation(.easeOut(duration: 0.28)) { captured = duration }
        Task {
            try? await Task.sleep(for: .milliseconds(1_150))
            dismiss()
        }
    }
}

/// Live audio levels, drawn from the microphone and nothing else.
///
/// Bars scroll in from the right so the newest sound is nearest the eye, and
/// older bars fall away exponentially rather than linearly. A linear falloff
/// leaves a long straight ramp behind every syllable — the shape reads as a
/// row of triangles instead of a voice — whereas an exponential one collapses
/// the tail quickly and keeps the leading edge sharp.
struct RecordingWaveform: View {
    let levels: [CGFloat]
    var isActive: Bool

    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 3
    /// Per-bar decay across the visible window, newest to oldest.
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
                    bar(height: 2, opacity: 0.15)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { index, level in
                    // Age measured from the newest bar, so index 0 of the
                    // visible window is the oldest and fades most.
                    let age = shown.count - 1 - index
                    let falloff = pow(trailDecay, CGFloat(age))
                    bar(
                        height: max(2, level * geometry.size.height * falloff),
                        opacity: Double(max(0.12, falloff))
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            .animation(.linear(duration: 0.05), value: levels.count)
        }
        .accessibilityHidden(true)
    }

    private func bar(height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(isActive ? Theme.Palette.action : Theme.Palette.secondary)
            .frame(width: barWidth, height: height)
            .opacity(opacity)
    }
}

#if canImport(UIKit)
import UIKit
#endif


/// The beat after stopping.
///
/// Not a screen and not a confirmation to dismiss — just long enough to
/// register that something was kept. It says what was captured and what
/// happens next, then gets out of the way on its own.
private struct CapturedMoment: View {
    let duration: TimeInterval

    @State private var settled = false

    var body: some View {
        VStack(spacing: Theme.Metrics.lg) {
            ZStack {
                Circle()
                    .stroke(Theme.Palette.action.opacity(0.25), lineWidth: 1)
                    .frame(width: settled ? 96 : 56, height: settled ? 96 : 56)
                    .opacity(settled ? 0 : 1)
                Circle()
                    .fill(Theme.Palette.action)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.Palette.onAction)
            }
            .scaleEffect(settled ? 1 : 0.7)

            VStack(spacing: Theme.Metrics.xs) {
                Text("Kept \u{00B7} \(duration.durationLabel)")
                    .rambleType(Theme.Text.sectionSerif)
                    .foregroundStyle(Theme.Palette.ink)
                    .monospacedDigit()
                Text("Finding the shape of it\u{2026}")
                    .rambleType(Theme.Text.supporting)
                    .foregroundStyle(Theme.Palette.secondary)
            }
            .opacity(settled ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { settled = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording kept, \(Int(duration)) seconds. Finding the shape of it.")
    }
}
