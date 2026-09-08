import Foundation
import NaturalLanguage
import Observation

/// Proves — or disproves — that on-device semantic search actually works here.
///
/// Everything about the on-device path was written, wired, and never once run
/// against real hardware. A simulator cannot answer the question: the model
/// assets, the dimension, and whether the vectors mean anything are all
/// properties of the device.
///
/// So this does not report "available". It embeds three sentences and checks
/// that two which mean the same thing land closer together than two which do
/// not. A model that loads and returns noise would pass an availability check
/// and fail this one, and the failure mode it protects against — search that
/// silently returns nothing useful — is invisible from the outside.
@MainActor
@Observable
final class EmbeddingDiagnostics {
    static let shared = EmbeddingDiagnostics()

    enum State: Equatable {
        case idle
        case downloading
        case running
        case passed(Result)
        case failed(String)
    }

    struct Result: Equatable {
        let dimension: Int
        let revision: Int
        /// How close two sentences that mean the same thing landed. 1 is identical.
        let relatedScore: Double
        /// How close two unrelated sentences landed. Should be clearly lower.
        let unrelatedScore: Double
        /// What the server is building its index at.
        let serverDimension: Int

        /// The vectors carry meaning rather than noise.
        var isMeaningful: Bool { relatedScore > unrelatedScore + 0.05 }
        /// The device and server agree on width, or nothing can be compared.
        var matchesServer: Bool { dimension == serverDimension }
        var isUsable: Bool { isMeaningful && matchesServer }
    }

    private(set) var state: State = .idle

    private init() {}

    // Two ways of saying one thing, and one saying something else entirely.
    private let related = (
        "We decided to launch with a single plan at twenty nine dollars a month.",
        "The pricing choice was one tier, priced at $29 monthly."
    )
    private let unrelated = "Remember to water the plants before leaving on Friday."

    func run() async {
        state = .downloading
        do {
            // Downloading the assets is the slow part and the part most likely
            // to fail on a device that has never done it.
            try await OnDeviceEmbedder.shared.prepare()
            state = .running

            let embedder = OnDeviceEmbedder.shared
            guard
                let a = try embedder.embed(related.0),
                let b = try embedder.embed(related.1),
                let c = try embedder.embed(unrelated)
            else {
                state = .failed("The model loaded but produced no vector for ordinary text.")
                return
            }

            let serverDimension = (try? await APIClient.shared.pendingEmbeddings(limit: 1).dimension) ?? 0

            let result = Result(
                dimension: embedder.dimension,
                revision: embedder.revision,
                relatedScore: Self.similarity(a, b),
                unrelatedScore: Self.similarity(a, c),
                serverDimension: serverDimension
            )
            state = .passed(result)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Cosine similarity. Both vectors are already normalized, so this is a
    /// plain dot product.
    private static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        return Double(zip(a, b).reduce(Float.zero) { $0 + $1.0 * $1.1 })
    }

    /// What to tell the person, in their terms rather than the model's.
    var summary: String? {
        switch state {
        case .idle: return nil
        case .downloading: return "Downloading the model\u{2026} this only happens once."
        case .running: return "Checking whether it understands meaning\u{2026}"
        case .failed(let reason):
            return "This device can't do it: \(reason) Search still works by keyword, and the server can take over."
        case .passed(let result):
            if !result.matchesServer {
                return "This device makes \(result.dimension)-wide vectors and the server expects "
                    + "\(result.serverDimension). They can't be compared, so nothing would be found."
            }
            if !result.isMeaningful {
                return "The model runs but its vectors don't carry meaning here "
                    + "(\(Self.format(result.relatedScore)) vs \(Self.format(result.unrelatedScore))). "
                    + "The server should do the embedding instead."
            }
            return "Working. Two ways of saying the same thing scored "
                + "\(Self.format(result.relatedScore)), against "
                + "\(Self.format(result.unrelatedScore)) for something unrelated."
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
