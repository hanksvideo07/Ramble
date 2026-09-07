import Foundation

/// How accurate a transcript the user wants, and what they are willing to
/// spend to get it.
///
/// On-device transcription is free, private, and works offline, and is right
/// for almost everything. Cloud transcription is measurably better on accents,
/// background noise, and unusual vocabulary — worth having, but not worth
/// making the default, since it costs money and sends the audio away.
enum TranscriptionQuality: String, CaseIterable, Identifiable {
    case onDevice
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: "On this iPhone"
        case .accurate: "Higher accuracy"
        }
    }

    var detail: String {
        switch self {
        case .onDevice:
            "Free, works offline, and your audio is never sent anywhere to be read."
        case .accurate:
            "Better with accents, background noise, and unusual words. Sends your audio to a transcription service, and costs about 26¢ an hour."
        }
    }

    private static let key = "app.ramble.transcription_quality"

    /// Defaults to on-device: it is the private, free option, and the one that
    /// works when there is no signal.
    static var preferred: TranscriptionQuality {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(TranscriptionQuality.init) ?? .onDevice
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
