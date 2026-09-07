import AVFoundation
import Observation
import SwiftUI

/// Playback for one recording.
///
/// Held by the detail screen rather than by the player bar, because the
/// transcript and the approval cards both need to seek into it: a quote you
/// cannot listen back to is not really a source.
@MainActor
@Observable
final class AudioPlayerModel {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double
    private(set) var isUnavailable = false

    private var player: AVPlayer?
    private var observer: Any?
    private var url: URL?

    init(duration: Double) {
        self.duration = duration
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    /// Called when the detail loads or reloads. Replacing the URL mid-playback
    /// would restart the audio under the listener, so an unchanged URL is a
    /// no-op.
    func prepare(url: URL?) {
        guard let url else {
            isUnavailable = true
            return
        }
        guard url != self.url else { return }
        teardown()
        self.url = url
        isUnavailable = false

        let player = AVPlayer(url: url)
        // A periodic observer is enough to drive a progress bar, and does not
        // run a timer while nothing is playing.
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if self.duration > 0, time.seconds >= self.duration {
                    self.isPlaying = false
                }
            }
        }
        self.player = player
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration { seek(to: 0) }
            configureSessionForPlayback()
            player.play()
        }
        isPlaying.toggle()
    }

    /// Jumps to a moment and starts playing, which is what someone tapping a
    /// timestamp is asking for.
    func play(from seconds: Double) {
        guard player != nil else { return }
        seek(to: seconds)
        if !isPlaying {
            configureSessionForPlayback()
            player?.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Recording leaves the session configured for capture; playing back
    /// through the earpiece instead of the speaker would look like a bug.
    private func configureSessionForPlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func teardown() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        isPlaying = false
    }
}

/// The player bar. The audio is the source of truth for everything else on the
/// screen, so it sits directly under the summary rather than at the bottom.
struct AudioPlayerBar: View {
    @Bindable var player: AudioPlayerModel

    var body: some View {
        if player.isUnavailable {
            StatusNotice(
                message: "This recording's audio isn't available",
                detail: "The transcript and everything below it are still here.",
                systemImage: "waveform.slash"
            )
        } else {
            HStack(spacing: Theme.Metrics.md) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(
                            width: Theme.Metrics.minimumTouchTarget,
                            height: Theme.Metrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Scrubber(player: player)

                Text("\(player.currentTime.durationLabel) / \(player.duration.durationLabel)")
                    .rambleType(Theme.Text.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.secondary)
            }
            .padding(.vertical, Theme.Metrics.sm)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
        }
    }
}

/// A draggable progress line. Thin, because it is a control the person rarely
/// touches — most listening is from a timestamp, not a scrub.
private struct Scrubber: View {
    @Bindable var player: AudioPlayerModel
    @State private var dragProgress: Double?

    var body: some View {
        GeometryReader { geometry in
            let shown = dragProgress ?? player.progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Palette.divider)
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.Palette.action)
                    .frame(width: max(0, geometry.size.width * shown), height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = min(1, max(0, value.location.x / geometry.size.width))
                    }
                    .onEnded { _ in
                        if let dragProgress { player.seek(to: dragProgress * player.duration) }
                        dragProgress = nil
                    }
            )
        }
        .frame(height: Theme.Metrics.minimumTouchTarget)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(player.currentTime.durationLabel)
        .accessibilityAdjustableAction { direction in
            let step: Double = 10
            player.seek(to: direction == .increment
                ? min(player.duration, player.currentTime + step)
                : max(0, player.currentTime - step))
        }
    }
}
