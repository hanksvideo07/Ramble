import AVFoundation
import Foundation

/// Captures audio to a local file.
///
/// The recording is the source of truth and must survive anything: no network
/// call, transcription, or UI state is allowed to affect whether audio reaches
/// disk. The file is written directly by AVAudioRecorder and only read again
/// once the user has stopped.
@MainActor
@Observable
final class Recorder {
    enum State: Equatable {
        case idle
        case recording
        case finished(URL, duration: TimeInterval)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Normalized 0...1 levels driving the waveform, newest last.
    private(set) var levels: [CGFloat] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    /// Number of bars the waveform keeps on screen.
    private let levelWindow = 48

    var isRecording: Bool { state == .recording }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func start() {
        guard state != .recording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .record rather than .playAndRecord: nothing plays while capturing,
            // and this keeps the session simple and reliable.
            try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetooth])
            try session.setActive(true)

            let url = Self.newRecordingURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                // 64 kbps mono keeps an hour under 30 MB while staying clearly
                // intelligible for transcription.
                AVEncoderBitRateKey: 64_000,
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .failed("Couldn't start recording.")
                return
            }

            self.recorder = recorder
            startedAt = Date()
            elapsed = 0
            levels = []
            state = .recording
            startMetering()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard let recorder, state == .recording else { return }
        let url = recorder.url
        let duration = recorder.currentTime
        recorder.stop()
        stopMetering()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        self.recorder = nil
        // A tap that lands before any audio is written should not create an
        // empty ramble.
        state = duration < 0.4 ? .idle : .finished(url, duration: duration)
    }

    func cancel() {
        recorder?.stop()
        if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        stopMetering()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        elapsed = 0
        levels = []
    }

    func reset() {
        state = .idle
        elapsed = 0
        levels = []
    }

    // MARK: - Metering

    private func startMetering() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopMetering() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime

        // Average power is in dBFS, roughly -60 (silence) to 0 (peak). Map it
        // onto a curve that makes speech visibly lively without clipping.
        let decibels = recorder.averagePower(forChannel: 0)
        let floor: Float = -55
        let normalized = decibels < floor ? 0 : (decibels - floor) / -floor
        let shaped = CGFloat(pow(normalized, 0.6))

        levels.append(max(0.04, min(1, shaped)))
        if levels.count > levelWindow { levels.removeFirst(levels.count - levelWindow) }
    }

    // MARK: - Files

    /// Recordings live in Application Support, which is backed up and not
    /// purged by the system, so an unsent recording survives.
    static func recordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func newRecordingURL() -> URL {
        recordingsDirectory().appending(path: "\(UUID().uuidString).m4a")
    }
}
