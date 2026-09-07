import AVFoundation
import Foundation
import Speech

/// Captures audio to a local file, and — where the device supports it — shows
/// the words as they are spoken.
///
/// One engine tap does both jobs, in a deliberate order: the buffer is written
/// to disk first, then metered, then handed to the transcriber. The recording
/// is the source of truth, so nothing downstream of the write is allowed to
/// affect whether the audio reaches disk. Live transcription is best-effort
/// and is dropped silently if it cannot keep up or is unavailable.
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

    /// Words confirmed so far. Grows as the person speaks.
    private(set) var transcribedText: String = ""
    /// The tail the recognizer is still revising. Shown dimmer than the rest.
    private(set) var volatileText: String = ""
    /// True once live transcription is actually producing words, so the view
    /// can show the waveform alone rather than an empty transcript pane.
    private(set) var isTranscribing = false

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var startedAt: Date?
    private var displayTimer: Timer?

    // Live transcription. All optional — recording works without any of it.
    //
    // Held as plain closures rather than typed properties because the analyzer
    // types are iOS 26 only, and this class has to compile for iOS 18.
    private var feedAnalyzer: ((AVAudioPCMBuffer) -> Void)?
    private var finishAnalyzer: (() -> Void)?
    private var transcriptionTask: Task<Void, Never>?

    /// How fast the meter falls after a sound stops.
    ///
    /// A slow fall leaves a long ramp behind every syllable, which reads as a
    /// row of triangles rather than a voice. Decaying by this factor each
    /// frame drops a peak to near nothing in about a fifth of a second, so
    /// bars snap down while still looking smooth.
    private let levelDecay: CGFloat = 0.62

    /// Meter frames per second. Also the waveform's scroll speed.
    private let meterInterval: TimeInterval = 0.05

    private let levelWindow = 48
    private var displayedLevel: CGFloat = 0
    /// Written on the audio thread, read on the main actor.
    private let levelBox = LevelBox()

    var isRecording: Bool { state == .recording }

    // MARK: - Permissions

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

    // MARK: - Lifecycle

    func start() {
        guard state != .recording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP])
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 else {
                state = .failed("No microphone input is available.")
                return
            }

            let url = Self.newRecordingURL()
            // 64 kbps mono AAC keeps an hour under 30 MB while staying clearly
            // intelligible for transcription.
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: inputFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
            )
            audioFile = file

            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.handle(buffer: buffer)
            }

            engine.prepare()
            try engine.start()

            startedAt = Date()
            elapsed = 0
            levels = []
            displayedLevel = 0
            transcribedText = ""
            volatileText = ""
            state = .recording

            startDisplayTimer()
            startLiveTranscription(inputFormat: inputFormat)
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard state == .recording else { return }
        let url = audioFile?.url
        let duration = elapsed
        teardown()

        guard let url else {
            state = .failed("The recording could not be saved.")
            return
        }
        // A tap that lands before any audio is written should not create an
        // empty ramble.
        state = duration < 0.4 ? .idle : .finished(url, duration: duration)
    }

    func cancel() {
        let url = audioFile?.url
        teardown()
        if let url { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    func reset() {
        state = .idle
        elapsed = 0
        levels = []
        displayedLevel = 0
        transcribedText = ""
        volatileText = ""
        isTranscribing = false
    }

    private func teardown() {
        displayTimer?.invalidate()
        displayTimer = nil

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        finishAnalyzer?()
        finishAnalyzer = nil
        feedAnalyzer = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Closing the file flushes the encoder's remaining frames.
        audioFile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio thread

    /// Runs on the realtime audio thread. Deliberately does no main-actor work:
    /// the level is dropped into a lock-protected box and picked up by the
    /// display timer instead.
    private nonisolated func handle(buffer: AVAudioPCMBuffer) {
        // The write comes first and is never conditional on anything below it.
        if let file = audioFileForWriting() {
            try? file.write(from: buffer)
        }
        levelBox.store(Self.peakLevel(of: buffer))
        yieldToAnalyzer(buffer)
    }

    private nonisolated func audioFileForWriting() -> AVAudioFile? {
        MainActor.assumeIsolated { audioFile }
    }

    private nonisolated func yieldToAnalyzer(_ buffer: AVAudioPCMBuffer) {
        MainActor.assumeIsolated {
            feedAnalyzer?(buffer)
        }
    }

    /// Peak amplitude, which tracks speech far more responsively than an
    /// average and is what makes the waveform feel connected to the voice.
    private nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(channel[index]))
        }
        return CGFloat(peak)
    }

    // MARK: - Display

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: meterInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        guard state == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)

        let incoming = levelBox.take()

        // Rise instantly to a new peak, fall exponentially away from it. The
        // asymmetry is what makes speech look like speech: attacks are sharp,
        // and silence returns to flat quickly instead of trailing off.
        displayedLevel = incoming > displayedLevel
            ? incoming
            : displayedLevel * levelDecay

        // A gentle curve keeps ordinary speech visible without lifting the
        // noise floor into a permanent shimmer.
        let shaped = min(1, pow(max(0, displayedLevel), 0.7) * 1.6)
        levels.append(max(0.02, shaped))
        if levels.count > levelWindow { levels.removeFirst(levels.count - levelWindow) }
    }

    // MARK: - Live transcription

    private func startLiveTranscription(inputFormat: AVAudioFormat) {
        guard #available(iOS 26.0, *) else { return }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            guard
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
                await SpeechTranscriber.installedLocales.contains(where: {
                    $0.identifier(.bcp47) == locale.identifier(.bcp47)
                })
            else { return }

            // volatileResults is what makes words appear as they are said,
            // rather than a sentence at a time once each is finished.
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            guard
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber],
                    considering: inputFormat
                ),
                let converter = AVAudioConverter(from: inputFormat, to: format)
            else { return }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])

            await MainActor.run {
                self.feedAnalyzer = { buffer in
                    guard let converted = Self.convert(buffer, using: converter, to: format) else { return }
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                self.finishAnalyzer = { continuation.finish() }
            }

            do {
                try await analyzer.start(inputSequence: stream)
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        self.isTranscribing = true
                        if result.isFinal {
                            // Confirmed text accumulates; the volatile tail is
                            // cleared because it has just been superseded.
                            self.transcribedText = (self.transcribedText + " " + text)
                                .trimmingCharacters(in: .whitespaces)
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                    }
                }
            } catch {
                // Live text is a convenience. Losing it must never affect the
                // recording, so this ends quietly.
                await MainActor.run { self.isTranscribing = false }
            }
        }
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
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

/// Carries the newest level from the audio thread to the display timer.
/// A lock rather than an actor because the audio thread must never await.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CGFloat = 0

    func store(_ level: CGFloat) {
        lock.lock()
        value = max(value, level)
        lock.unlock()
    }

    /// Reads and clears, so a frame with no audio decays instead of repeating
    /// the last peak forever.
    func take() -> CGFloat {
        lock.lock()
        defer { value = 0; lock.unlock() }
        return value
    }
}
