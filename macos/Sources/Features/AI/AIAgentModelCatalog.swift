import Combine
import Foundation

/// The models each installed agent advertises over ACP, as last discovered. Discovery
/// starts an agent process, so it only runs on request; the last result is kept so the
/// AI page can show a count without starting anything.
@MainActor
final class AIAgentModelCatalog: ObservableObject {
    struct Entry: Equatable {
        /// Nil until the agent was asked once.
        var models: [String]?
        var checkedAt: Date?
        var isLoading = false
        /// Why the last discovery failed; nil after a success.
        var error: String?
    }

    typealias Loader = @Sendable (GitCommitAgent) async throws -> [String]

    static let defaultsKey = "OMGAIAgentModelCatalog"
    static let shared = AIAgentModelCatalog(
        defaults: OMGApplicationEnvironment.isRunningTests ? nil : .standard
    )

    @Published private(set) var entries: [GitCommitAgent: Entry] = [:]

    private let defaults: UserDefaults?
    private let load: Loader
    private var tasks: [GitCommitAgent: Task<Void, Never>] = [:]

    init(
        defaults: UserDefaults? = nil,
        load: @escaping Loader = { try await GitCommitAIService.models(agent: $0) }
    ) {
        self.defaults = defaults
        self.load = load
        let stored = defaults?.dictionary(forKey: Self.defaultsKey) ?? [:]
        for agent in GitCommitAgent.allCases {
            guard let record = stored[agent.rawValue] as? [String: Any],
                  let models = record["models"] as? [String] else { continue }
            entries[agent] = Entry(
                models: models.compactMap(AIModelID.normalized),
                checkedAt: (record["checkedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func entry(_ agent: GitCommitAgent) -> Entry {
        entries[agent] ?? Entry()
    }

    /// Asks the agent for its models unless a discovery is already running.
    func refresh(_ agent: GitCommitAgent) {
        guard tasks[agent] == nil else { return }
        var entry = entry(agent)
        entry.isLoading = true
        entry.error = nil
        entries[agent] = entry
        let load = load
        tasks[agent] = Task { @MainActor [weak self] in
            let result: Result<[String], Error>
            do {
                result = .success(try await load(agent))
            } catch {
                result = .failure(error)
            }
            self?.finish(agent, result)
        }
    }

    /// Refreshes and awaits discovery for `agent`, sharing any in-flight request and updating the catalog.
    func refreshAsync(_ agent: GitCommitAgent) async throws -> [String] {
        if let existingTask = tasks[agent] {
            await existingTask.value
            if let error = entry(agent).error {
                throw NSError(domain: "OMGAIAgentModelCatalog", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: error])
            }
            return entry(agent).models ?? []
        }
        refresh(agent)
        if let started = tasks[agent] {
            await started.value
        }
        if let error = entry(agent).error {
            throw NSError(domain: "OMGAIAgentModelCatalog", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        return entry(agent).models ?? []
    }

    /// Records externally loaded models so every picker and page observes one consistent list and order.
    func recordModels(_ models: [String], for agent: GitCommitAgent) {
        let normalized = models.compactMap(AIModelID.normalized)
        entries[agent] = Entry(models: normalized, checkedAt: Date(), isLoading: false, error: nil)
        save()
    }

    private func finish(_ agent: GitCommitAgent, _ result: Result<[String], Error>) {
        tasks[agent] = nil
        var entry = entry(agent)
        entry.isLoading = false
        switch result {
        case .success(let models):
            entry.models = models
            entry.checkedAt = Date()
            entry.error = nil
        case .failure(let error):
            // The list from an earlier success stays usable.
            entry.error = error.localizedDescription
        }
        entries[agent] = entry
        save()
    }

    private func save() {
        guard let defaults else { return }
        var stored: [String: Any] = [:]
        for (agent, entry) in entries {
            guard let models = entry.models else { continue }
            var record: [String: Any] = ["models": models]
            if let checkedAt = entry.checkedAt { record["checkedAt"] = checkedAt.timeIntervalSince1970 }
            stored[agent.rawValue] = record
        }
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}
