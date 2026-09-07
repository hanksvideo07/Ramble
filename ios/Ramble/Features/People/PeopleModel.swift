import Foundation
import Observation

/// The people, companies, and projects Ramble has heard about, and nothing
/// else. Entities are discovered from recordings; there is no address book to
/// import and nothing to fill in.
@MainActor
@Observable
final class PeopleModel {
    enum Filter: String, CaseIterable, Identifiable {
        case everyone, people, companies, projects
        var id: String { rawValue }

        var label: String {
            switch self {
            case .everyone: "All"
            case .people: "People"
            case .companies: "Companies"
            case .projects: "Projects"
            }
        }

        /// The server's entity kinds this filter admits.
        func matches(_ kind: String) -> Bool {
            switch self {
            case .everyone: true
            case .people: kind == "person"
            case .companies: kind == "organization" || kind == "company"
            case .projects: kind == "project"
            }
        }
    }

    var query = "" {
        didSet { scheduleSearch() }
    }
    var filter: Filter = .everyone

    private(set) var entities: [EntitySummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    private var debounceTask: Task<Void, Never>?

    /// What the list shows, after the filter and with the most-mentioned first.
    var visible: [EntitySummary] {
        entities.filter { filter.matches($0.kind) }
    }

    /// Grouped by first letter, so a long list stays scannable.
    var sections: [(letter: String, entities: [EntitySummary])] {
        Dictionary(grouping: visible) { entity in
            String(entity.name.prefix(1)).uppercased()
        }
        .map { (letter: $0.key, entities: $0.value.sorted { $0.name < $1.name }) }
        .sorted { $0.letter < $1.letter }
    }

    func load() async {
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        await fetch()
    }

    func refresh() async {
        await fetch()
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.fetch()
        }
    }

    private func fetch() async {
        let current = query.trimmingCharacters(in: .whitespaces)
        do {
            let result = try await APIClient.shared.entities(matching: current.isEmpty ? nil : current)
            guard current == query.trimmingCharacters(in: .whitespaces) else { return }
            entities = result
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
