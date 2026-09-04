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
                } else {
                    Text(recorder.elapsed.durationLabel)
                        .font(Theme.Typography.timer)
                        .foregroundStyle(Theme.Palette.text)
                        .contentTransition(.numericText())

                    WaveformView(levels: recorder.levels, isActive: recorder.isRecording)
                        .frame(height: 72)
                        .padding(.horizontal, 32)
                        .padding(.top, 28)

                    Text(recorder.isRecording ? "Listening…" : "Getting ready…")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.muted)
                        .padding(.top, 20)
                }

                Spacer()

                if !permissionDenied {
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

/// Live audio levels. Bars scroll from the right so the newest sound is
/// nearest the eye, and the whole thing settles to a flat line when silent.
struct WaveformView: View {
    let levels: [CGFloat]
    var isActive: Bool

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let capacity = max(1, Int(geometry.size.width / (barWidth + spacing)))
            let shown = Array(levels.suffix(capacity))
            let padding = max(0, capacity - shown.count)

            HStack(alignment: .center, spacing: spacing) {
                // Leading blanks keep new bars entering from the right rather
                // than the whole waveform re-centring on every sample.
                ForEach(0..<padding, id: \.self) { _ in
                    bar(height: 2, opacity: 0.25)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                    bar(height: max(2, level * geometry.size.height), opacity: 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            .animation(.linear(duration: 0.05), value: levels.count)
        }
    }

    private func bar(height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(isActive ? Theme.Palette.accent : Theme.Palette.muted)
            .frame(width: barWidth, height: height)
            .opacity(opacity)
    }
}

#if canImport(UIKit)
import UIKit
#endif
