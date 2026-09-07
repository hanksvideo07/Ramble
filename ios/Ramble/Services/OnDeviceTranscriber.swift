import AVFoundation
import Foundation
import Speech

/// Transcribes a finished recording on the device.
///
/// Using Apple's on-device analyzer rather than a cloud service means there is
/// no per-minute cost, no API key, it works with no signal, and the audio is
/// never sent anywhere to be turned into text. The recording itself still
/// uploads — it is the source of truth and has to be replayable — but the
/// transcript is produced here.
///
/// The server keeps its own transcription providers behind the same interface;
/// this simply means the client usually has an answer before the upload
/// finishes, and the server's transcribe stage is skipped.
@available(iOS 26.0, *)
actor OnDeviceTranscriber {
    static let shared = OnDeviceTranscriber()

    struct Segment: Codable, Sendable {
        let index: Int
        let startSeconds: Double
        let endSeconds: Double
        let text: String
    }

    struct Transcript: Codable, Sendable {
        let text: String
        let segments: [Segment]
        let locale: String
    }

    enum TranscriptionError: LocalizedError {
        case unsupportedLocale(String)
        case assetsUnavailable
        case noAudio

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id):
                "Ramble can't transcribe \(id) on this device yet."
            case .assetsUnavailable:
                "The language model needed for transcription couldn't be installed."
            case .noAudio:
                "That recording had no audio in it."
            }
        }
    }

    /// Whether transcription can run right now without downloading anything.
    static func isReady(for locale: Locale = .current) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return false
        }
        return await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == supported.identifier(.bcp47)
        }
    }

    /// Downloads the locale assets if needed. Safe to call repeatedly.
    static func prepare(locale: Locale = .current) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        // Reserving keeps the locale installed; the system may otherwise
        // reclaim assets for languages the user is not actively using.
        _ = try? await AssetInventory.reserve(locale: supported)
    }

    /// Transcribes a recorded file, with timings.
    func transcribe(fileURL: URL, locale: Locale = .current) async throws -> Transcript {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }

        // audioTimeRange is what makes an extracted item link back to a moment
        // in the recording, so it is requested explicitly.
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            try await Self.prepare(locale: supported)
        }

        let file = try AVAudioFile(forReading: fileURL)
        guard file.length > 0 else { throw TranscriptionError.noAudio }

        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: file.processingFormat
            )
        else { throw TranscriptionError.assetsUnavailable }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])

        // Collect results while the file is fed in, so a long recording is not
        // held entirely in memory as attributed strings.
        let collector = Task { () -> [Segment] in
            var segments: [Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let range = result.range
                segments.append(
                    Segment(
                        index: segments.count,
                        startSeconds: range.start.seconds.isFinite ? range.start.seconds : 0,
                        endSeconds: range.end.seconds.isFinite ? range.end.seconds : 0,
                        text: text
                    )
                )
            }
            return segments
        }

        try await analyzer.start(inputSequence: stream)
        try feed(file: file, into: continuation, converting: analyzerFormat)
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let segments = try await collector.value
        guard !segments.isEmpty else { throw TranscriptionError.noAudio }

        return Transcript(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            locale: supported.identifier(.bcp47)
        )
    }

    /// Reads the file in chunks, converting to whatever format the analyzer wants.
    private func feed(
        file: AVAudioFile,
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        converting analyzerFormat: AVAudioFormat
    ) throws {
        let sourceFormat = file.processingFormat
        let frameCount: AVAudioFrameCount = 8192

        guard let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else {
            throw TranscriptionError.assetsUnavailable
        }
        // Sample-rate conversion changes the frame count, so the output buffer
        // is sized by the ratio rather than assuming they match.
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate

        while file.framePosition < file.length {
            guard
                let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
            else { break }
            try file.read(into: input, frameCount: frameCount)
            if input.frameLength == 0 { break }

            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard
                let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
            else { break }

            var consumed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
        }
    }
}
