import Foundation
import Observation

/// Uploads recordings through a background URLSession, so locking the phone
/// does not stop them.
///
/// This is the piece that makes "just talk and forget it" literally true. A
/// normal URLSession is suspended along with the app: lock the screen mid-upload
/// and the transfer pauses until someone reopens Ramble. A background session is
/// handed to the system daemon instead, which finishes the transfer whether the
/// app is running, suspended, or terminated, and relaunches it to deliver the
/// result.
///
/// Three constraints follow from that and shape everything here:
///
///  1. A background session cannot upload from memory. `httpBody` is ignored
///     and data tasks are unavailable, so the multipart envelope has to be
///     written to a file and handed over as a file.
///  2. The app may be a different process by the time a transfer finishes, so
///     the mapping from task to recording lives on disk, not in memory.
///  3. Completion arrives on a delegate, not from an `await`. The upload loop
///     therefore hands work over and returns rather than waiting.
@MainActor
@Observable
final class BackgroundUploader: NSObject {
    static let shared = BackgroundUploader()

    /// Set by the app hook so the system knows when it is safe to suspend us
    /// again after delivering background events.
    @ObservationIgnored var systemCompletionHandler: (() -> Void)?

    private(set) var inFlight: Set<String> = []

    /// What each transfer has actually done, and when it last did it.
    ///
    /// This exists because "is it uploading in the background?" is otherwise
    /// unanswerable from the outside. A transfer that the system is genuinely
    /// carrying and one that is simply stalled look identical — both show
    /// "Sending…". The only honest way to tell them apart is a timestamp on
    /// the last byte that moved, compared against when the app was last on
    /// screen. Persisted, because the whole question is about what happened
    /// while this process was not running.
    private(set) var progress: [String: Progress] = [:]

    struct Progress: Codable, Hashable {
        var bytesSent: Int64
        var totalBytes: Int64
        var startedAt: Date
        var lastActivityAt: Date
        /// Whether the app was in the foreground the last time bytes moved.
        /// False here is the proof that background transfer works.
        var lastActivityInForeground: Bool

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(bytesSent) / Double(totalBytes)) : 0
        }
    }

    /// Identifier is stable across launches — that is how the system reunites
    /// a relaunched app with transfers it started in a previous life.
    static let sessionIdentifier = "app.ramble.upload"

    @ObservationIgnored private let mapURL = Recorder.recordingsDirectory().appending(path: "uploads.json")
    @ObservationIgnored private let progressURL = Recorder.recordingsDirectory()
        .appending(path: "upload-progress.json")
    /// URLSession task identifier to capture id. On disk because the process
    /// that started a transfer is often not the one that sees it finish.
    @ObservationIgnored private var taskToCapture: [Int: String] = [:]

    // Not observed: the macro rewrites stored properties, and a lazily
    // constructed session is not something a view should ever depend on.
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The whole point is that these keep going. Waiting for connectivity is
        // the system's job, and it is better at it than a retry loop.
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        loadMap()
        loadProgress()
    }

    /// Reconnects to transfers already in flight. Called at launch, before any
    /// new work is queued, so a recording is never uploaded twice.
    func resume() async {
        let tasks = await session.allTasks
        inFlight = Set(tasks.compactMap { taskToCapture[$0.taskIdentifier] })
        if !tasks.isEmpty {
            print("[BackgroundUploader] resumed \(tasks.count) transfer(s) from a previous launch")
        }
    }

    func isUploading(_ captureId: String) -> Bool {
        inFlight.contains(captureId)
    }

    /// Hands one recording to the system and returns immediately.
    func upload(capture: CaptureQueue.PendingCapture, rambleId: String, token: String) throws {
        guard !inFlight.contains(capture.id) else { return }

        let boundary = "ramble.\(UUID().uuidString)"
        var request = URLRequest(url: try APIClient.audioUploadURL(rambleId: rambleId))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Written to disk rather than held in memory: a background session
        // ignores httpBody entirely, and a long recording should not be
        // resident anyway.
        let bodyURL = try writeMultipartBody(
            fileURL: capture.fileURL,
            boundary: boundary,
            to: capture.id
        )

        let size = ((try? FileManager.default.attributesOfItem(atPath: bodyURL.path))?[.size] as? Int64) ?? 0

        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = capture.id
        taskToCapture[task.taskIdentifier] = capture.id
        saveMap()
        inFlight.insert(capture.id)
        progress[capture.id] = Progress(
            bytesSent: 0,
            totalBytes: size,
            startedAt: Date(),
            lastActivityAt: Date(),
            lastActivityInForeground: true
        )
        saveProgress()
        task.resume()
    }

    private func writeMultipartBody(fileURL: URL, boundary: String, to captureId: String) throws -> URL {
        let bodyURL = Recorder.recordingsDirectory().appending(path: "upload-\(captureId).multipart")
        // A retry rebuilds it; a stale envelope from a failed attempt must not
        // be sent in place of the real one.
        try? FileManager.default.removeItem(at: bodyURL)
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        var header = ""
        header += "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        header += "Content-Type: audio/m4a\r\n\r\n"
        try handle.write(contentsOf: Data(header.utf8))

        // Streamed in chunks so a long recording never has to fit in memory.
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }

        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    /// Records that bytes moved, and whether the app was on screen at the time.
    fileprivate func note(bytesSent: Int64, total: Int64, for captureId: String) {
        var entry = progress[captureId] ?? Progress(
            bytesSent: 0,
            totalBytes: total,
            startedAt: Date(),
            lastActivityAt: Date(),
            lastActivityInForeground: true
        )
        entry.bytesSent = bytesSent
        if total > 0 { entry.totalBytes = total }
        entry.lastActivityAt = Date()
        entry.lastActivityInForeground = UIApplication.shared.applicationState == .active
        progress[captureId] = entry
        saveProgress()
    }

    private func cleanUp(captureId: String, taskIdentifier: Int) {
        inFlight.remove(captureId)
        taskToCapture.removeValue(forKey: taskIdentifier)
        progress.removeValue(forKey: captureId)
        saveMap()
        saveProgress()
        try? FileManager.default.removeItem(
            at: Recorder.recordingsDirectory().appending(path: "upload-\(captureId).multipart")
        )
    }

    // MARK: - Persistence

    private func saveMap() {
        let encodable = taskToCapture.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }
        try? JSONEncoder().encode(encodable).write(to: mapURL, options: .atomic)
    }

    private func loadMap() {
        guard let data = try? Data(contentsOf: mapURL),
              let saved = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        taskToCapture = saved.reduce(into: [Int: String]()) {
            if let key = Int($1.key) { $0[key] = $1.value }
        }
    }

    private func saveProgress() {
        try? JSONEncoder().encode(progress).write(to: progressURL, options: .atomic)
    }

    private func loadProgress() {
        guard let data = try? Data(contentsOf: progressURL),
              let saved = try? JSONDecoder().decode([String: Progress].self, from: data)
        else { return }
        progress = saved
    }
}

// MARK: - Delegate

extension BackgroundUploader: URLSessionDataDelegate {
    /// Bytes moving. The only evidence that a transfer is alive, and — because
    /// it records whether the app was on screen — the only evidence that it is
    /// alive while the app is not.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let captureId = task.taskDescription
        Task { @MainActor in
            guard let captureId else { return }
            BackgroundUploader.shared.note(
                bytesSent: totalBytesSent,
                total: totalBytesExpectedToSend,
                for: captureId
            )
        }
    }

    /// The server's reply. Only consulted for its status code; the body is a
    /// small acknowledgement.
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let identifier = task.taskIdentifier
        let captureId = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode

        Task { @MainActor in
            guard let captureId = captureId ?? BackgroundUploader.shared.taskToCapture[identifier] else { return }
            BackgroundUploader.shared.cleanUp(captureId: captureId, taskIdentifier: identifier)

            if let error {
                CaptureQueue.shared.uploadFailed(captureId, reason: error.localizedDescription)
                return
            }
            guard let status, (200..<300).contains(status) else {
                // A 401 will not fix itself by retrying, and a 4xx means the
                // server rejected this specific upload. Both are reported as
                // they are rather than retried forever.
                CaptureQueue.shared.uploadFailed(
                    captureId,
                    reason: status == 401
                        ? "Sign in to sync"
                        : "The server refused the upload (\(status ?? 0))."
                )
                return
            }
            await CaptureQueue.shared.uploadSucceeded(captureId)
        }
    }

    /// Every transfer the system had for us has been delivered. Calling the
    /// handler is what allows the app to be suspended again.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            BackgroundUploader.shared.systemCompletionHandler?()
            BackgroundUploader.shared.systemCompletionHandler = nil
        }
    }
}


#if canImport(UIKit)
import UIKit
#endif
