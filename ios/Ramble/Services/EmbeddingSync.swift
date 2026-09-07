import Foundation
import Observation

/// Keeps the server's semantic index filled in.
///
/// The server decides what should be searchable — it owns chunking, so there is
/// one definition of a unit rather than two that can drift — and marks each row
/// with no vector. This asks what is outstanding, embeds it on the device, and
/// posts the vectors back. Until that happens, lexical and structured search
/// still work; only the fuzzy "that insurance company I was pitching" case has
/// to wait.
@MainActor
@Observable
final class EmbeddingSync {
    static let shared = EmbeddingSync()

    private(set) var isSyncing = false
    private(set) var pendingCount = 0
    private(set) var lastError: String?
    /// True once the device and server agree on vector width and revision.
    private(set) var isHandshakeComplete = false

    /// Embedding a large backlog is slow and warms the phone, so each pass is
    /// bounded and the rest is picked up next time.
    private let batchSize = 25

    private init() {}

    /// Runs a sync pass. Safe to call often; overlapping calls are ignored.
    func sync() {
        guard !isSyncing else { return }
        Task { await performSync() }
    }

    private func performSync() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await OnDeviceEmbedder.shared.prepare()

            if !isHandshakeComplete {
                // Establishes that this device's vectors are comparable with
                // what the server already holds. A revision bump means the old
                // vectors were made by a different model, and the server
                // clears them rather than mixing the two.
                let result = try await APIClient.shared.embeddingHandshake(
                    dimension: OnDeviceEmbedder.shared.dimension,
                    revision: OnDeviceEmbedder.shared.revision
                )
                isHandshakeComplete = true
                if result.reindexing > 0 {
                    print("[EmbeddingSync] Model revision changed; re-embedding \(result.reindexing) units.")
                }
            }

            var processed = 0
            while processed < batchSize {
                let pending = try await APIClient.shared.pendingEmbeddings(limit: batchSize)
                pendingCount = pending.units.count
                if pending.units.isEmpty { break }

                var vectors: [(id: String, vector: [Float])] = []
                for unit in pending.units {
                    // A unit that cannot be embedded is left with a NULL
                    // vector rather than retried forever; lexical search still
                    // finds it.
                    if let vector = try OnDeviceEmbedder.shared.embed(unit.content) {
                        vectors.append((id: unit.id, vector: vector))
                    }
                }

                guard !vectors.isEmpty else { break }
                try await APIClient.shared.uploadEmbeddings(
                    vectors: vectors,
                    revision: OnDeviceEmbedder.shared.revision
                )
                processed += vectors.count
                if pending.units.count < batchSize { break }
            }

            pendingCount = max(0, pendingCount - processed)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Embeds a search query so the server can run semantic search against
    /// vectors made by this same model.
    func embedQuery(_ text: String) async -> [Float]? {
        do {
            try await OnDeviceEmbedder.shared.prepare()
            return try OnDeviceEmbedder.shared.embed(text)
        } catch {
            // Losing the semantic third of search is worth far less than
            // losing the search, so this fails quietly.
            return nil
        }
    }
}
