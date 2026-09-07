import Foundation
import NaturalLanguage

/// Turns text into vectors on the device, using Apple's contextual embedding
/// model.
///
/// Two things about embeddings drive this design. Vectors are only comparable
/// within one model, so the query and everything it searches must be embedded
/// by the same model at the same revision — which is why the server stores
/// chunks and this embeds them, rather than each side embedding its own half.
/// And the model produces one vector per token, so they are mean-pooled and
/// normalized into a single vector per chunk.
@MainActor
final class OnDeviceEmbedder {
    static let shared = OnDeviceEmbedder()

    enum EmbedderError: LocalizedError {
        case unavailable
        case assetsMissing

        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device search isn't supported on this device."
            case .assetsMissing: "The on-device search model hasn't finished downloading."
            }
        }
    }

    private var embedding: NLContextualEmbedding?

    private init() {}

    /// Dimension of the vectors this device produces. The server's pgvector
    /// column has to match, so it is reported on first sync.
    var dimension: Int { embedding?.dimension ?? 0 }

    /// The model revision. Vectors from different revisions are not
    /// comparable, so a change here means everything must be re-embedded.
    var revision: Int { embedding?.revision ?? 0 }

    var isReady: Bool { embedding != nil }

    /// Loads the model, downloading assets if the system does not have them.
    func prepare(language: NLLanguage = .english) async throws {
        if embedding != nil { return }

        guard let model = NLContextualEmbedding(language: language) else {
            throw EmbedderError.unavailable
        }

        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else { throw EmbedderError.assetsMissing }
        }

        try model.load()
        embedding = model
    }

    /// Embeds one piece of text into a single normalized vector.
    ///
    /// Returns nil for text the model cannot place — an empty chunk, or one
    /// whose tokens all pool to zero — so callers can skip it rather than
    /// storing a meaningless vector.
    func embed(_ text: String, language: NLLanguage = .english) throws -> [Float]? {
        guard let embedding else { throw EmbedderError.unavailable }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let result = try embedding.embeddingResult(for: trimmed, language: language)

        var pooled = [Double](repeating: 0, count: embedding.dimension)
        var tokens = 0

        // Mean-pool the token vectors. Averaging is the standard way to turn
        // contextual token embeddings into one sentence vector, and it keeps
        // short and long chunks on the same scale once normalized.
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for (index, value) in vector.enumerated() where index < pooled.count {
                pooled[index] += value
            }
            tokens += 1
            return true
        }

        guard tokens > 0 else { return nil }

        var magnitude = 0.0
        for index in pooled.indices {
            pooled[index] /= Double(tokens)
            magnitude += pooled[index] * pooled[index]
        }
        magnitude = magnitude.squareRoot()
        guard magnitude > 0 else { return nil }

        // Normalizing means cosine similarity is a plain dot product, which is
        // what pgvector's cosine operator expects anyway.
        return pooled.map { Float($0 / magnitude) }
    }

    /// Frees the model. Worth calling after a large batch so the memory is not
    /// held for the life of the app.
    func unload() {
        embedding?.unload()
        embedding = nil
    }
}
