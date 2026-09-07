import Foundation
import Observation

/// What the Ask screen is currently showing. Each state is distinct on
/// purpose: "nothing matched" and "the request failed" mean different things
/// to the person, and collapsing them would hide real problems.
enum AskPhase: Equatable {
    /// Nothing asked yet — suggestions are showing.
    case idle
    case searching
    case thinking
    /// Matching recordings, with no synthesized answer.
    case matches
    /// An answer with its sources.
    case answered
    case noResults
    case failed(String)
}

@MainActor
@Observable
final class AskModel {
    var query = "" {
        didSet { scheduleSearch() }
    }

    private(set) var phase: AskPhase = .idle
    private(set) var hits: [SearchHit] = []
    private(set) var answer: AskAnswer?
    /// The question the current results belong to, shown above the answer so a
    /// stale result can never be read as the answer to a newer question.
    private(set) var askedQuestion: String?

    private var debounceTask: Task<Void, Never>?

    let suggestions = [
        "What did I decide about pricing?",
        "What do I owe people right now?",
        "What have I been circling back to?",
        "What did I say I'd do this week?",
    ]

    /// A question gets an answer; a keyword gets a list. Deciding from the
    /// text avoids making the person choose a mode before they know what they
    /// want.
    private var looksLikeQuestion: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("?") { return true }
        let starters = ["what", "when", "who", "why", "how", "did i", "have i", "where", "am i", "do i"]
        return starters.contains { trimmed.hasPrefix($0) } && trimmed.split(separator: " ").count > 3
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        let current = query.trimmingCharacters(in: .whitespaces)
        guard current.count >= 2 else {
            reset()
            return
        }
        // Typing should feel live, but a question deserves to be finished
        // before it is sent, so only plain search runs while typing.
        guard !looksLikeQuestion else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    /// Called on submit, and by a suggestion or an Ask intent.
    func run() {
        debounceTask?.cancel()
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
        Task {
            if looksLikeQuestion {
                await performAsk()
            } else {
                await performSearch()
            }
        }
    }

    /// Puts a question in and runs it, for a suggestion tap or a deep link.
    func submit(_ question: String) {
        debounceTask?.cancel()
        query = question
        // Setting `query` schedules a live search; the question should be
        // asked whole instead.
        debounceTask?.cancel()
        run()
    }

    func clear() {
        debounceTask?.cancel()
        query = ""
        reset()
    }

    private func reset() {
        hits = []
        answer = nil
        askedQuestion = nil
        phase = .idle
    }

    private func performSearch() async {
        let current = query
        phase = .searching
        do {
            // Embedded here with the same model that embedded everything it
            // will be compared against.
            let vector = await EmbeddingSync.shared.embedQuery(current)
            let results = try await APIClient.shared.search(current, vector: vector)
            // Discard a response the person has already typed past.
            guard current == query else { return }
            hits = results
            answer = nil
            askedQuestion = current
            phase = results.isEmpty ? .noResults : .matches
        } catch {
            guard current == query else { return }
            hits = []
            answer = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func performAsk() async {
        let current = query
        phase = .thinking
        do {
            let vector = await EmbeddingSync.shared.embedQuery(current)
            let result = try await APIClient.shared.ask(current, vector: vector)
            guard current == query else { return }
            answer = result
            askedQuestion = current
            // The retrieved recordings double as "where this came from".
            hits = (try? await APIClient.shared.search(current, vector: vector)) ?? []
            phase = result.citations.isEmpty && hits.isEmpty ? .noResults : .answered
        } catch {
            guard current == query else { return }
            answer = nil
            hits = []
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        run()
    }
}
