import Foundation
import Observation

@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { scheduleSearch() }
    }
    private(set) var hits: [SearchHit] = []
    private(set) var answer: AskAnswer?
    private(set) var isWorking = false
    private(set) var hasSearched = false

    private var debounceTask: Task<Void, Never>?

    /// A question gets an answer; a keyword gets a list. Deciding from the text
    /// avoids making the person choose a mode before they know what they want.
    private var looksLikeQuestion: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("?") { return true }
        let starters = ["what", "when", "who", "why", "how", "did i", "have i", "where"]
        return starters.contains { trimmed.hasPrefix($0) } && trimmed.split(separator: " ").count > 3
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        let current = query.trimmingCharacters(in: .whitespaces)
        guard current.count >= 2 else {
            hits = []
            answer = nil
            hasSearched = false
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

    /// Called on submit. Asks when the text reads as a question.
    func run() {
        debounceTask?.cancel()
        Task {
            if looksLikeQuestion {
                await performAsk()
            } else {
                await performSearch()
            }
        }
    }

    func clear() {
        debounceTask?.cancel()
        query = ""
        hits = []
        answer = nil
        hasSearched = false
    }

    private func performSearch() async {
        let current = query
        isWorking = true
        defer { isWorking = false }
        do {
            // Embedded here, with the same model that embedded everything it
            // will be compared against.
            let vector = await EmbeddingSync.shared.embedQuery(current)
            let results = try await APIClient.shared.search(current, vector: vector)
            // Discard a response whose query the user has already moved past.
            guard current == query else { return }
            hits = results
            answer = nil
            hasSearched = true
        } catch {
            hits = []
            hasSearched = true
        }
    }

    private func performAsk() async {
        let current = query
        isWorking = true
        defer { isWorking = false }
        do {
            let vector = await EmbeddingSync.shared.embedQuery(current)
            let result = try await APIClient.shared.ask(current, vector: vector)
            guard current == query else { return }
            answer = result
            // The citations double as the "where this came from" list.
            hits = try await APIClient.shared.search(current, vector: vector)
            hasSearched = true
        } catch {
            answer = nil
            hasSearched = true
        }
    }
}
