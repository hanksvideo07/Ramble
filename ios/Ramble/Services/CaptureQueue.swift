import Foundation
import Network
import Observation

/// Tracks every recording from the moment it stops until the server has it.
///
/// The queue is written to disk on every change, so a crash, a force-quit, or
/// a week offline never costs a recording. Audio files are deleted only after
/// the server confirms the upload.
@MainActor
@Observable
final class CaptureQueue {
    static let shared = CaptureQueue()

    struct PendingCapture: Codable, Identifiable, Hashable {
        let id: String
        let fileURL: URL
        let recordedAt: Date
        let duration: TimeInterval
        let source: String
        /// Filled in once the server has accepted the metadata.
        var rambleId: String?
        var attempts: Int = 0
        var lastError: String?

        /// Audio can be lost if the user clears storage; the queue drops
        /// entries whose file no longer exists rather than retrying forever.
        var fileExists: Bool {
            FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    private(set) var pending: [PendingCapture] = []
    private(set) var isSyncing = false
    private(set) var isOnline = true

    private let storeURL = Recorder.recordingsDirectory().appending(path: "queue.json")
    private let monitor = NWPathMonitor()
    private var syncTask: Task<Void, Never>?

    private init() {
        load()
        startMonitoring()
    }

    var hasPending: Bool { !pending.isEmpty }

    /// How far a queued recording has got, in the terms the history shows.
    /// The audio is already safe in every one of these states; only its
    /// journey to the server differs.
    func state(for capture: PendingCapture) -> UploadState {
        // A transfer the system is carrying is uploading even when this app is
        // idle — which is the whole point of it being a background transfer.
        if BackgroundUploader.shared.isUploading(capture.id) { return .uploading }
        if let error = capture.lastError, capture.attempts > 0 { return .failed(error) }
        if !isOnline { return .waitingForConnection }
        if isSyncing { return .uploading }
        return .storedLocally
    }

    // MARK: - Enqueue

    /// Adds a finished recording. Called the moment the user stops, before any
    /// network work, so the recording is durable immediately.
    func enqueue(fileURL: URL, recordedAt: Date, duration: TimeInterval, source: String = "ios") {
        let capture = PendingCapture(
            id: UUID().uuidString,
            fileURL: fileURL,
            recordedAt: recordedAt,
            duration: duration,
            source: source
        )
        pending.append(capture)
        save()
        sync()
    }

    // MARK: - Sync

    func sync() {
        guard !isSyncing, !pending.isEmpty, isOnline else { return }
        syncTask?.cancel()
        syncTask = Task {
            // Reconnect to anything the system is still carrying from a
            // previous launch first, or it would be started a second time.
            await BackgroundUploader.shared.resume()
            await performSync()
        }
    }

    private func performSync() async {
        isSyncing = true
        defer { isSyncing = false }

        // Oldest first, so a backlog uploads in the order it was spoken.
        for capture in pending.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            if Task.isCancelled { return }

            guard capture.fileExists else {
                remove(capture.id)
                continue
            }

            // Already handed to the system daemon, possibly by a previous
            // launch. Starting it again would upload the same recording twice.
            if BackgroundUploader.shared.isUploading(capture.id) { continue }

            do {
                // The metadata call is idempotent on client_id, so a retry
                // after a failed upload reuses the same ramble. Small enough
                // to go on the ordinary session.
                let rambleId: String
                if let existing = capture.rambleId {
                    rambleId = existing
                } else {
                    rambleId = try await APIClient.shared.createRamble(
                        clientId: capture.id,
                        recordedAt: capture.recordedAt,
                        duration: capture.duration,
                        source: capture.source
                    )
                    update(capture.id) { $0.rambleId = rambleId }
                }

                guard let token = await APIClient.shared.currentToken else {
                    update(capture.id) { $0.lastError = "Sign in to sync" }
                    return
                }

                // Hand the audio to the system and move on. It finishes whether
                // or not this app is still running, which is the entire point;
                // the result arrives on the uploader's delegate.
                try BackgroundUploader.shared.upload(
                    capture: capture,
                    rambleId: rambleId,
                    token: token
                )
                update(capture.id) { $0.lastError = nil }
            } catch APIError.offline {
                isOnline = false
                update(capture.id) { $0.lastError = "Waiting for a connection" }
                return
            } catch APIError.notAuthenticated {
                // Nothing will succeed until the user signs in again; stop
                // rather than burning attempts.
                update(capture.id) { $0.lastError = "Sign in to sync" }
                return
            } catch {
                update(capture.id) {
                    $0.attempts += 1
                    $0.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Upload outcomes

    /// The system finished a transfer. Everything that used to follow the
    /// upload inline now happens here, because the upload no longer completes
    /// inside the loop that started it.
    func uploadSucceeded(_ captureId: String) async {
        guard let capture = pending.first(where: { $0.id == captureId }),
              let rambleId = capture.rambleId
        else { return }

        remove(captureId)
        NotificationCenter.default.post(name: .rambleUploaded, object: rambleId)

        // The server has the audio and is already processing it, so a local
        // transcript is a bonus rather than a dependency.
        await transcribeOnDevice(capture: capture, rambleId: rambleId)

        // Only now is the local copy redundant.
        try? FileManager.default.removeItem(at: capture.fileURL)

        // Newly extracted items need vectors before semantic search can find them.
        EmbeddingSync.shared.sync()

        // The on-device transcript is already good enough to use, so the
        // upgrade runs afterwards and quietly replaces it.
        if TranscriptionQuality.preferred == .accurate {
            try? await APIClient.shared.upgradeTranscript(rambleId: rambleId)
        }
    }

    /// A transfer failed. The recording stays queued — it is still on the
    /// phone, and nothing about a failed upload endangers it.
    func uploadFailed(_ captureId: String, reason: String) {
        update(captureId) {
            $0.attempts += 1
            $0.lastError = reason
        }
    }

    /// Transcribes on the device and sends the result up.
    ///
    /// Doing this here rather than at capture time means it also covers a
    /// recording made offline days ago, and keeps the record screen free to
    /// dismiss the instant the user stops.
    private func transcribeOnDevice(capture: PendingCapture, rambleId: String) async {
        guard #available(iOS 26.0, *) else { return }
        guard await OnDeviceTranscriber.isReady() else { return }

        // Skip it entirely when the server transcribes better than the phone
        // can. Re-transcribing locally only to have the server's own result
        // supersede it wastes battery for nothing.
        if TranscriptionQuality.preferred == .accurate { return }

        do {
            let transcript = try await withTimeout(seconds: 120) {
                try await OnDeviceTranscriber.shared.transcribe(fileURL: capture.fileURL)
            }
            try await APIClient.shared.uploadTranscript(
                rambleId: rambleId,
                text: transcript.text,
                locale: transcript.locale,
                segments: transcript.segments.map {
                    OnDeviceTranscriptSegment(
                        index: $0.index,
                        startSeconds: $0.startSeconds,
                        endSeconds: $0.endSeconds,
                        text: $0.text
                    )
                }
            )
        } catch {
            // The server still has the audio and its own providers, so a
            // failure here costs quality, not the recording.
            print("[CaptureQueue] On-device transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connectivity

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let reconnected = online && !self.isOnline
                self.isOnline = online
                // Uploading the moment connectivity returns is the whole point
                // of recording offline in the first place.
                if reconnected { self.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.ramble.network"))
    }

    // MARK: - Persistence

    private func update(_ id: String, _ change: (inout PendingCapture) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
        save()
    }

    private func remove(_ id: String) {
        pending.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(pending)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // A failed write must not lose the in-memory queue; the audio file
            // itself is still on disk either way.
            print("[CaptureQueue] Could not persist queue: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([PendingCapture].self, from: data)
        else { return }
        // Drop anything whose audio is gone so the queue cannot stall forever.
        pending = saved.filter(\.fileExists)
        if pending.count != saved.count { save() }
    }
}

/// Runs `work`, giving up after `seconds`.
///
/// Anything awaited inside the upload loop needs a bound. A system framework
/// that never returns is indistinguishable from one that is slow, and the
/// queue stops moving either way.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CaptureTimeout.expired
        }
        guard let first = try await group.next() else { throw CaptureTimeout.expired }
        group.cancelAll()
        return first
    }
}

private enum CaptureTimeout: Error { case expired }

extension Notification.Name {
    /// Posted with the new ramble's id once the server has its audio.
    static let rambleUploaded = Notification.Name("app.ramble.uploaded")
}
