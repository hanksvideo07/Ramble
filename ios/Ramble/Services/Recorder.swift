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

    /// Why live text is or is not appearing.
    ///
    /// This used to fail silently: if the speech model had not been downloaded
    /// the whole feature just did nothing, which is indistinguishable from it
    /// being broken.
    enum LiveTranscription: Equatable {
        case off
        case downloadingModel
        case running
        case unavailable(String)
    }
    private(set) var liveTranscription: LiveTranscription = .off

    /// Built fresh for each recording. A reused engine can carry state from a
    /// failed or interrupted session, and the resulting start() failure gives
    /// no hint that a previous attempt is the reason.
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    /// All state the realtime audio thread touches.
    private let sink = Sink()
    private var startedAt: Date?
    private var displayTimer: Timer?

    // Live transcription. All optional — recording works without any of it.
    //
    // Held as plain closures rather than typed properties because the analyzer
    // types are iOS 26 only, and this class has to compile for iOS 18.
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
            try Self.configureSession()

            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode

            // A zero here means the session has not really given us the
            // microphone — usually another app holding it, or a simulator with
            // no input device. Reported plainly rather than as an OSStatus from
            // whatever fails next.
            let reportedFormat = input.outputFormat(forBus: 0)
            guard reportedFormat.sampleRate > 0, reportedFormat.channelCount > 0 else {
                teardown()
                state = .failed(
                    "No microphone is available. Another app may be using it, "
                        + "or this device has no audio input."
                )
                return
            }

            let url = Self.newRecordingURL()

            // The file's format is fixed rather than copied from the hardware.
            // Input can arrive stereo, at 16 kHz over Bluetooth, or at rates
            // the AAC encoder rejects, and AVAudioFile.write refuses any buffer
            // whose format differs from its own — which is what produced
            // "OSStatus error: -50" when these were assumed to match. Writing a
            // known-good format and converting into it removes the entire class
            // of failure.
            let file: AVAudioFile
            do {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 64_000,
                    ]
                )
            } catch {
                throw RecorderError.cannotCreateFile(error)
            }
            audioFile = file
            sink.begin(file: file)
            // Live transcription needs the real input format, which is only
            // known once buffers start arriving.
            sink.onFirstBuffer = { [weak self] format in
                Task { @MainActor in self?.startLiveTranscription(inputFormat: format) }
            }

            // A nil format means "whatever this node is actually running at".
            // Passing a format read beforehand is the usual cause of
            // engine.start() failing: activating the session can renegotiate
            // the hardware, leaving the value stale and the tap mismatched.
            // The tap talks only to the sink: no actor isolation is involved,
            // because a realtime thread cannot participate in it.
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [sink] buffer, _ in
                sink.accept(buffer)
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw RecorderError.engineFailed(error)
            }

            startedAt = Date()
            elapsed = 0
            levels = []
            displayedLevel = 0
            transcribedText = ""
            volatileText = ""
            state = .recording

            startDisplayTimer()
        } catch let error as RecorderError {
            teardown()
            state = .failed(error.localizedDescription)
        } catch {
            teardown()
            state = .failed(RecorderError.engineFailed(error).localizedDescription)
        }
    }

    /// Puts the audio session into a state that can record.
    ///
    /// Configurations are tried from most preferred to most permissive. Modes
    /// and options are not universally supported — they vary by device, by
    /// route, and by what else is playing — and a rejected combination surfaces
    /// as an opaque Core Audio failure from `engine.start()` rather than from
    /// the call that actually caused it. Falling back is far better than
    /// refusing to record because a headset dislikes one option.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // `.measurement` disables the system's automatic gain and filtering,
        // which is what transcription wants. `.default` is the fallback that
        // every route accepts.
        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.record, .measurement, [.allowBluetoothHFP]),
            (.record, .default, [.allowBluetoothHFP]),
            (.record, .default, []),
            (.playAndRecord, .default, [.allowBluetoothHFP, .defaultToSpeaker]),
        ]

        var lastError: Error?
        for (category, mode, options) in attempts {
            do {
                try session.setCategory(category, mode: mode, options: options)
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let lastError { throw RecorderError.sessionFailed(lastError) }

        // Requests, not guarantees. A Bluetooth headset will refuse and force
        // 16 kHz mono; the converter handles whatever we actually get.
        try? session.setPreferredSampleRate(44_100)
        try? session.setPreferredInputNumberOfChannels(1)

        do {
            try session.setActive(true)
        } catch {
            throw RecorderError.sessionFailed(error)
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
        liveTranscription = .off
    }

    private func teardown() {
        displayTimer?.invalidate()
        displayTimer = nil

        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        engine = nil

        sink.setFeed(nil)
        finishAnalyzer?()
        finishAnalyzer = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Closing the file flushes the encoder's remaining frames.
        sink.onFirstBuffer = nil
        sink.finish()
        audioFile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio thread

    /// Everything the realtime audio thread touches.
    ///
    /// Deliberately not actor-isolated. A realtime thread cannot hop to an
    /// actor, and `MainActor.assumeIsolated` is a precondition rather than a
    /// hop — calling it from here traps the process instantly, which is
    /// exactly what it did. State the audio thread needs therefore lives
    /// behind a plain lock, and the main actor reads from it on a timer.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()

        private var file: AVAudioFile?
        private var converter: AVAudioConverter?
        private var fileFormat: AVAudioFormat?
        private var failure: String?
        private var peak: CGFloat = 0
        private var feed: ((AVAudioPCMBuffer) -> Void)?
        private var sawFirstBuffer = false

        /// Called once, on the main actor, with the format buffers actually
        /// arrive in — the only point where it is known for certain.
        var onFirstBuffer: (@Sendable (AVAudioFormat) -> Void)?

        func begin(file: AVAudioFile) {
            lock.lock()
            self.file = file
            self.fileFormat = file.processingFormat
            lock.unlock()
        }

        func setFeed(_ feed: ((AVAudioPCMBuffer) -> Void)?) {
            lock.lock()
            self.feed = feed
            lock.unlock()
        }

        /// The tap's entry point. Writing comes first and is never conditional
        /// on anything after it.
        func accept(_ buffer: AVAudioPCMBuffer) {
            lock.lock()

            guard let file, let fileFormat else {
                lock.unlock()
                return
            }

            if converter == nil {
                guard let made = AVAudioConverter(from: buffer.format, to: fileFormat) else {
                    failure = RecorderError.unsupportedInput(buffer.format).localizedDescription
                    lock.unlock()
                    return
                }
                converter = made
            }
            let activeConverter = converter!

            if let converted = Recorder.convert(buffer, using: activeConverter, to: fileFormat) {
                do {
                    try file.write(from: converted)
                } catch {
                    // A failed write means the recording is being lost right
                    // now. Reported rather than swallowed.
                    if failure == nil { failure = error.localizedDescription }
                }
            } else if failure == nil {
                failure = "The microphone's audio could not be converted for saving."
            }

            peak = max(peak, Recorder.peakLevel(of: buffer))

            let feedNow = feed
            let notifyFormat = sawFirstBuffer ? nil : buffer.format
            sawFirstBuffer = true
            lock.unlock()

            // Outside the lock: neither of these should block the audio thread
            // holding it.
            feedNow?(buffer)
            if let notifyFormat, let onFirstBuffer {
                onFirstBuffer(notifyFormat)
            }
        }

        /// Reads and clears, so a frame with no audio decays instead of
        /// repeating the last peak forever.
        func takePeak() -> CGFloat {
            lock.lock()
            defer { peak = 0; lock.unlock() }
            return peak
        }

        func takeFailure() -> String? {
            lock.lock()
            defer { failure = nil; lock.unlock() }
            return failure
        }

        func finish() {
            lock.lock()
            file = nil
            converter = nil
            fileFormat = nil
            feed = nil
            lock.unlock()
        }
    }

    /// Peak amplitude, which tracks speech far more responsively than an
    /// average and is what makes the waveform feel connected to the voice.
    fileprivate nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> CGFloat {
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

        // Stop immediately if audio has stopped reaching disk. Continuing to
        // show a running timer over a broken recording is the worst outcome
        // available.
        if let failure = sink.takeFailure() {
            teardown()
            state = .failed(failure)
            return
        }

        elapsed = Date().timeIntervalSince(startedAt)

        let incoming = sink.takePeak()

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
        guard transcriptionTask == nil else { return }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }

            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
                await MainActor.run {
                    self.liveTranscription = .unavailable("\(Locale.current.identifier) isn't supported yet.")
                }
                return
            }

            // The model is a one-time download. Previously this checked
            // whether it was installed and gave up when it wasn't — which is
            // why no words ever appeared. It now installs it.
            let installed = await SpeechTranscriber.installedLocales.contains {
                $0.identifier(.bcp47) == locale.identifier(.bcp47)
            }
            if !installed {
                await MainActor.run { self.liveTranscription = .downloadingModel }
                do {
                    try await OnDeviceTranscriber.prepare(locale: locale)
                } catch {
                    await MainActor.run {
                        self.liveTranscription = .unavailable(error.localizedDescription)
                    }
                    return
                }
            }

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
                self.sink.setFeed { buffer in
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
                        self.liveTranscription = .running
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
                // recording — but it should still say what happened rather
                // than leaving a blank pane.
                await MainActor.run {
                    self.isTranscribing = false
                    self.liveTranscription = .unavailable(error.localizedDescription)
                }
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

/// Failures that need to be explained in the person's terms rather than as a
/// Core Audio status code.
enum RecorderError: LocalizedError {
    case cannotCreateFile(Error)
    case unsupportedInput(AVAudioFormat)
    case sessionFailed(Error)
    case engineFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile:
            "Ramble couldn't create a file to record into. Check that there's free space on your iPhone."
        case .unsupportedInput(let format):
            "This microphone's format isn't supported (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch). Try disconnecting Bluetooth audio."
        case .sessionFailed(let underlying):
            {
                let ns = underlying as NSError
                return "Ramble couldn't get access to the microphone. "
                    + "[\(ns.domain) \(ns.code)\(ns.localizedDescription.isEmpty ? "" : ": \(ns.localizedDescription)")]"
            }()
        case .engineFailed(let underlying):
            // Core Audio's localizedDescription is frequently empty or generic,
            // so the domain and code are included — they are what actually
            // identifies the fault when this needs diagnosing.
            {
                let ns = underlying as NSError
                return "Ramble couldn't start the microphone. Another app may be using it. "
                    + "[\(ns.domain) \(ns.code)\(ns.localizedDescription.isEmpty ? "" : ": \(ns.localizedDescription)")]"
            }()
        }
    }
}

