import Foundation

struct PortableSSHHostRecord: Codable, Equatable, Sendable {
    let id: String
    var name: String
    let connection: GitSSHConnection
    var endpoint: String?
    var fromConfiguration: Bool?
    var autoInstallRuntime: Bool?
    var autoInstallHooks: Bool?

    init(from host: RegisteredSSHHost) {
        self.id = host.id
        self.name = host.name
        self.connection = host.connection
        self.endpoint = host.endpoint
        self.fromConfiguration = host.fromConfiguration
        self.autoInstallRuntime = host.autoInstallRuntime
        self.autoInstallHooks = host.autoInstallHooks
    }

    init(
        id: String,
        name: String,
        connection: GitSSHConnection,
        endpoint: String? = nil,
        fromConfiguration: Bool? = nil,
        autoInstallRuntime: Bool? = nil,
        autoInstallHooks: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.endpoint = endpoint
        self.fromConfiguration = fromConfiguration
        self.autoInstallRuntime = autoInstallRuntime
        self.autoInstallHooks = autoInstallHooks
    }

    func merged(into existing: RegisteredSSHHost?) -> RegisteredSSHHost {
        RegisteredSSHHost(
            id: id,
            name: name,
            connection: connection,
            snapshot: existing?.snapshot ?? .init(),
            capturedAt: existing?.capturedAt ?? .distantPast,
            endpoint: endpoint,
            fromConfiguration: fromConfiguration,
            autoInstallRuntime: autoInstallRuntime,
            autoInstallHooks: autoInstallHooks
        )
    }
}

struct PortableSSHRegistrySection: Codable, Equatable, Sendable {
    var automaticallyRegister: Bool
    var excluded: [String]
    var hosts: [PortableSSHHostRecord]

    init(
        automaticallyRegister: Bool = false,
        excluded: [String] = [],
        hosts: [PortableSSHHostRecord] = []
    ) {
        self.automaticallyRegister = automaticallyRegister
        self.excluded = excluded.sorted()
        self.hosts = hosts
    }
}

struct PortableAgentPolicyRecord: Codable, Equatable, Sendable {
    var checkAutomatically: Bool
    var updateHooksAutomatically: Bool
    var automaticallyUpdatedAgents: [String]
    var intervalHours: Int
    var updateAllCLIsAutomatically: Bool?
    var checkOnConnection: Bool?

    init(from policy: AgentIntegrationPolicy) {
        self.checkAutomatically = policy.checkAutomatically
        self.updateHooksAutomatically = policy.updateHooksAutomatically
        self.automaticallyUpdatedAgents = policy.automaticallyUpdatedAgents.map(\.rawValue).sorted()
        self.intervalHours = policy.intervalHours
        self.updateAllCLIsAutomatically = policy.updateAllCLIsAutomatically
        self.checkOnConnection = policy.checkOnConnection
    }

    init(
        checkAutomatically: Bool = true,
        updateHooksAutomatically: Bool = true,
        automaticallyUpdatedAgents: [String] = [],
        intervalHours: Int = 24,
        updateAllCLIsAutomatically: Bool? = nil,
        checkOnConnection: Bool? = nil
    ) {
        self.checkAutomatically = checkAutomatically
        self.updateHooksAutomatically = updateHooksAutomatically
        self.automaticallyUpdatedAgents = automaticallyUpdatedAgents.sorted()
        self.intervalHours = intervalHours
        self.updateAllCLIsAutomatically = updateAllCLIsAutomatically
        self.checkOnConnection = checkOnConnection
    }

    func merged(into existing: AgentIntegrationPolicy?) -> AgentIntegrationPolicy {
        var result = existing ?? AgentIntegrationPolicy()
        result.checkAutomatically = checkAutomatically
        result.updateHooksAutomatically = updateHooksAutomatically
        result.automaticallyUpdatedAgents = Set(automaticallyUpdatedAgents.compactMap(SupportedAgent.init(rawValue:)))
        result.intervalHours = intervalHours
        result.updateAllCLIsAutomatically = updateAllCLIsAutomatically
        result.checkOnConnection = checkOnConnection
        return result
    }
}

struct PortableGitDiffSection: Codable, Equatable, Sendable {
    var viewMode: String
    var review: Bool
    var wordWrap: Bool

    init(viewMode: GitDiffViewMode, review: Bool, wordWrap: Bool) {
        self.viewMode = viewMode.rawValue
        self.review = review
        self.wordWrap = wordWrap
    }

    init(viewMode: String, review: Bool, wordWrap: Bool) {
        self.viewMode = GitDiffViewMode(storedValue: viewMode).rawValue
        self.review = review
        self.wordWrap = wordWrap
    }
}

@MainActor
final class OMGPortableSettingsBinding {
    static let sshHostsKey = "sshHosts"
    static let agentPoliciesKey = "agentPolicies"
    static let gitDiffKey = "gitDiff"

    static let legacySSHDefaultsKey = "OMG.SSH.Registry.v1"
    static let legacyAgentPoliciesDefaultsKey = "OMG.AgentIntegration.Policies.v1"

    weak var settings: OhMyGhosttySettings?
    let sshRegistry: SSHHostRegistry
    let agentManager: AgentIntegrationManager
    let gitDiff: GitDiffPreferences
    let defaults: UserDefaults
    private var isSynchronizing = false

    init(
        settings: OhMyGhosttySettings,
        sshRegistry: SSHHostRegistry,
        agentManager: AgentIntegrationManager,
        gitDiff: GitDiffPreferences,
        defaults: UserDefaults
    ) {
        self.settings = settings
        self.sshRegistry = sshRegistry
        self.agentManager = agentManager
        self.gitDiff = gitDiff
        self.defaults = defaults

        sshRegistry.onPortableStateDidChange = { [weak self] in
            self?.mirrorSSHHostsToSettings()
        }
        agentManager.onPortableStateDidChange = { [weak self] in
            self?.mirrorAgentPoliciesToSettings()
        }
        gitDiff.onPortableStateDidChange = { [weak self] in
            self?.mirrorGitDiffToSettings()
        }
    }

    /// Synchronizes portable sections between `settings.json` (`chosen`) and live stores.
    /// Returns `true` when non-destructive migration from `UserDefaults` populated missing
    /// portable sections in `chosen` and `settings.json` should be written.
    func synchronize(chosen: inout [String: Any]) -> Bool {
        guard !isSynchronizing else { return false }
        isSynchronizing = true
        defer { isSynchronizing = false }

        var migrated = false

        // 1. sshHosts
        if let rawSSH = chosen[Self.sshHostsKey] {
            if let decoded: PortableSSHRegistrySection = Self.decodeJSONObject(rawSSH) {
                sshRegistry.applyPortableSection(decoded)
            }
        } else if hasLegacySSHDefaults() {
            if let encoded = Self.encodeJSONObject(sshRegistry.portableSection()) {
                chosen[Self.sshHostsKey] = encoded
                migrated = true
            }
        }

        // 2. agentPolicies
        if let rawPolicies = chosen[Self.agentPoliciesKey] {
            if let decoded: [String: PortableAgentPolicyRecord] = Self.decodeJSONObject(rawPolicies) {
                agentManager.applyPortablePolicies(decoded)
            }
        } else if hasLegacyAgentPolicyDefaults() {
            if let encoded = Self.encodeJSONObject(agentManager.portablePolicies()) {
                chosen[Self.agentPoliciesKey] = encoded
                migrated = true
            }
        }

        // 3. gitDiff
        if let rawGitDiff = chosen[Self.gitDiffKey] {
            if let decoded: PortableGitDiffSection = Self.decodeJSONObject(rawGitDiff) {
                gitDiff.applyPortableSection(decoded)
            }
        } else if hasLegacyGitDiffDefaults() {
            if let encoded = Self.encodeJSONObject(gitDiff.portableSection()) {
                chosen[Self.gitDiffKey] = encoded
                migrated = true
            }
        }

        return migrated
    }

    private func hasLegacySSHDefaults() -> Bool {
        defaults.object(forKey: Self.legacySSHDefaultsKey) != nil
            || !sshRegistry.hosts.isEmpty
            || sshRegistry.automaticallyRegister
            || !sshRegistry.excludedIDs.isEmpty
    }

    private func hasLegacyAgentPolicyDefaults() -> Bool {
        defaults.object(forKey: Self.legacyAgentPoliciesDefaultsKey) != nil
            || !agentManager.policies.isEmpty
    }

    private func hasLegacyGitDiffDefaults() -> Bool {
        defaults.object(forKey: GitDiffPreferences.viewModeKey) != nil
            || defaults.object(forKey: GitDiffPreferences.reviewKey) != nil
            || defaults.object(forKey: GitDiffPreferences.wordWrapKey) != nil
    }

    private func mirrorSSHHostsToSettings() {
        guard !isSynchronizing, let settings else { return }
        let section = sshRegistry.portableSection()
        guard settings.portableSSHHosts != section,
              let object = Self.encodeJSONObject(section) else { return }
        settings.persistPortableSection(Self.sshHostsKey, value: object)
    }

    private func mirrorAgentPoliciesToSettings() {
        guard !isSynchronizing, let settings else { return }
        let policies = agentManager.portablePolicies()
        guard settings.portableAgentPolicies != policies,
              let object = Self.encodeJSONObject(policies) else { return }
        settings.persistPortableSection(Self.agentPoliciesKey, value: object)
    }

    private func mirrorGitDiffToSettings() {
        guard !isSynchronizing, let settings else { return }
        let section = gitDiff.portableSection()
        guard settings.portableGitDiff != section,
              let object = Self.encodeJSONObject(section) else { return }
        settings.persistPortableSection(Self.gitDiffKey, value: object)
    }

    static func encodeJSONObject<T: Encodable>(_ value: T) -> Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func decodeJSONObject<T: Decodable>(_ rawObject: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(rawObject),
              let data = try? JSONSerialization.data(withJSONObject: rawObject) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
