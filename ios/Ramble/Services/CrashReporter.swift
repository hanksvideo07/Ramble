import Foundation
import MetricKit
import Observation

/// Reports crashes and hangs using Apple's own diagnostics.
///
/// There is deliberately no third-party crash SDK in this app. Ramble is built
/// around people's private thoughts, and linking a library with permission to
/// read the app's memory and inspect its network traffic is not a trade worth
/// making for stack traces. MetricKit is already on the device, already
/// sanctioned by Apple, and already collecting exactly this — so the app reads
/// what MetricKit gives it and posts that on.
///
/// The catch, stated plainly: MetricKit delivers on Apple's schedule, usually
/// once every 24 hours and only after the app is relaunched. A crash is
/// therefore visible tomorrow, not now. That is the cost of not shipping an
/// SDK, and it is the right side of the trade for this app.
@MainActor
@Observable
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    /// Reports seen but not yet accepted by the server, so a failed send is
    /// retried rather than lost.
    private(set) var pending: [Report] = []
    private(set) var lastSentAt: Date?

    struct Report: Codable, Identifiable, Hashable {
        let kind: String
        let signature: String
        let frames: [String]
        let appVersion: String?
        let osVersion: String?
        let deviceModel: String?
        let occurredAt: String?

        var id: String { "\(kind)-\(signature)-\(occurredAt ?? "")" }

        enum CodingKeys: String, CodingKey {
            case kind, signature, frames
            case appVersion = "app_version"
            case osVersion = "os_version"
            case deviceModel = "device_model"
            case occurredAt = "occurred_at"
        }
    }

    private let storeURL = URL.documentsDirectory.appending(path: "crash-reports.json")

    private override init() {
        super.init()
        load()
    }

    /// Called once at launch. Subscribing is all that is needed; the system
    /// delivers whatever it has accumulated.
    func start() {
        MXMetricManager.shared.add(self)
        Task { await flush() }
    }

    // MARK: - MetricKit

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics, not crashes. Ramble measures its own latency
        // where it matters, so there is nothing to do with these.
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { Self.reports(from: $0) }
        guard !reports.isEmpty else { return }
        Task { @MainActor in
            self.accept(reports)
            await self.flush()
        }
    }

    nonisolated private static func reports(from payload: MXDiagnosticPayload) -> [Report] {
        var found: [Report] = []
        let occurred = ISO8601DateFormatter().string(from: payload.timeStampEnd)

        for crash in payload.crashDiagnostics ?? [] {
            found.append(
                Report(
                    kind: "crash",
                    // The termination reason is the most human part of a crash
                    // report; the exception codes alone say very little.
                    signature: crash.terminationReason
                        ?? "exception \(crash.exceptionType?.intValue ?? -1)."
                        + "\(crash.exceptionCode?.intValue ?? -1)",
                    frames: frames(from: crash.callStackTree),
                    appVersion: crash.applicationVersion,
                    osVersion: crash.metaData.osVersion,
                    deviceModel: crash.metaData.deviceType,
                    occurredAt: occurred
                )
            )
        }

        for hang in payload.hangDiagnostics ?? [] {
            found.append(
                Report(
                    kind: "hang",
                    signature: "main thread blocked for \(hang.hangDuration.value)s",
                    frames: frames(from: hang.callStackTree),
                    appVersion: hang.applicationVersion,
                    osVersion: hang.metaData.osVersion,
                    deviceModel: hang.metaData.deviceType,
                    occurredAt: occurred
                )
            )
        }

        for exception in payload.cpuExceptionDiagnostics ?? [] {
            found.append(
                Report(
                    kind: "cpu-exception",
                    signature: "sustained CPU for \(exception.totalCPUTime.value)s",
                    frames: frames(from: exception.callStackTree),
                    appVersion: exception.applicationVersion,
                    osVersion: exception.metaData.osVersion,
                    deviceModel: exception.metaData.deviceType,
                    occurredAt: occurred
                )
            )
        }

        return found
    }

    /// MetricKit hands back a JSON call-stack tree. Only the frame lines are
    /// wanted; the rest is structure that means nothing off-device.
    nonisolated private static func frames(from tree: MXCallStackTree) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()),
            let root = object as? [String: Any],
            let stacks = root["callStacks"] as? [[String: Any]]
        else { return [] }

        var lines: [String] = []
        for stack in stacks {
            guard let roots = stack["callStackRootFrames"] as? [[String: Any]] else { continue }
            var queue = roots
            while let frame = queue.first, lines.count < 120 {
                queue.removeFirst()
                let binary = frame["binaryName"] as? String ?? "?"
                let offset = frame["offsetIntoBinaryTextSegment"] as? Int ?? 0
                lines.append("\(binary) +\(offset)")
                if let children = frame["subFrames"] as? [[String: Any]] {
                    queue.append(contentsOf: children)
                }
            }
        }
        return lines
    }

    // MARK: - Delivery

    private func accept(_ reports: [Report]) {
        // The same crash can appear in more than one payload; sending it twice
        // would make one bug look like several.
        let known = Set(pending.map(\.id))
        pending.append(contentsOf: reports.filter { !known.contains($0.id) })
        save()
    }

    /// Sends anything outstanding. Kept for the next attempt if it fails —
    /// a crash report that is lost because the network was down is a crash
    /// nobody ever hears about.
    func flush() async {
        guard !pending.isEmpty, await APIClient.shared.isSignedIn else { return }
        let sending = pending
        do {
            try await APIClient.shared.reportCrashes(sending)
            pending.removeAll { report in sending.contains(report) }
            lastSentAt = Date()
            save()
        } catch {
            // Silent on purpose: a failed diagnostic upload is not something to
            // interrupt someone about.
        }
    }

    // MARK: - Persistence

    private func save() {
        try? JSONEncoder().encode(pending).write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Report].self, from: data)
        else { return }
        pending = saved
    }
}
