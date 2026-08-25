import AppKit
import Foundation

enum SupportedAgent: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case pi

    var id: String { rawValue }
    var definition: AgentDefinition { AgentCatalog.shared.definition(for: self) }
    var displayName: String { definition.displayName }
    var assetName: String { definition.iconAsset }
    var icon: PluginTabIcon { .init(kind: .bundledAsset, name: assetName) }

    func normalizedTitle(_ title: String) -> String {
        switch self {
        case .codex:
            return title
        case .claude:
            guard title.contains("Claude Code") else { return title }
            let trimmed = title.drop(while: { character in
                character.isWhitespace || character == "✳" || character == "✻" ||
                    character == "✶" || character == "*"
            })
            return trimmed.isEmpty ? displayName : String(trimmed)
        case .pi:
            let prefixes = ["π - ", "Pi - ", "pi - "]
            guard let prefix = prefixes.first(where: { title.hasPrefix($0) }) else {
                return title
            }
            let normalized = title.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            return normalized.isEmpty ? displayName : normalized
        }
    }
}

struct AgentConversationID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value) ||
                      (65...90).contains(value) ||
                      (97...122).contains(value) ||
                      scalar == "." || scalar == "_" || scalar == "-"
              }) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let validated = Self(value) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid agent conversation ID"
            ))
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentExecutionScope: String, Codable, Sendable {
    case local
    case remote
}

struct AgentResumeDescriptor: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let agent: SupportedAgent
    var conversationID: AgentConversationID?
    let scope: AgentExecutionScope
    var workingDirectory: String?
    var sshReplay: SSHReplayDescriptor?

    init(
        agent: SupportedAgent,
        conversationID: AgentConversationID? = nil,
        scope: AgentExecutionScope,
        workingDirectory: String?,
        sshReplay: SSHReplayDescriptor? = nil
    ) {
        self.version = Self.currentVersion
        self.agent = agent
        self.conversationID = conversationID
        self.scope = scope
        self.workingDirectory = workingDirectory
        self.sshReplay = sshReplay
    }

    var isValid: Bool {
        version == Self.currentVersion &&
            workingDirectory.map { !$0.contains("\0") && $0.utf8.count <= 4_096 } ?? true
    }

    func restorationCommand(
        executablePath: String,
        verifyLocalStore: Bool = true
    ) -> String? {
        guard isValid else { return nil }
        switch scope {
        case .local:
            return localCommand(verifyStore: verifyLocalStore)
        case .remote:
            guard let sshReplay else { return nil }
            return sshReplay.command(
                executablePath: executablePath,
                remoteWorkingDirectory: workingDirectory,
                remoteAgent: agent,
                conversationID: conversationID
            )
        }
    }

    private func localCommand(verifyStore: Bool) -> String? {
        guard scope == .local else { return nil }
        let definition = agent.definition
        var argv = [definition.command]
        if let conversationID,
           !verifyStore || definition.resume.discover != nil ||
           AgentConversationStore.contains(
               agent: agent,
               conversationID: conversationID
           ) {
            argv.append(contentsOf: definition.resume.resumeArguments.map {
                $0.replacingOccurrences(of: "{id}", with: conversationID.rawValue)
            })
        }
        guard argv.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
            return nil
        }
        let invocation = argv.map(Self.shellQuote).joined(separator: " ")
        return "\(invocation); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AgentDefinition: Codable, Equatable, Sendable {
    struct ProcessSpec: Codable, Equatable, Sendable {
        let executables: [String]
        let runtimeMarkers: [String]
    }

    struct ResumeSpec: Codable, Equatable, Sendable {
        struct Store: Codable, Equatable, Sendable {
            let root: String
            let entryPattern: String
        }

        struct Discovery: Codable, Equatable, Sendable {
            enum Format: String, Codable, Sendable {
                case json
                case jsonl
            }

            let root: String
            let format: Format
            let idKeyPath: String
            let cwdKeyPath: String
        }

        let createArguments: [String]?
        let resumeArguments: [String]
        let store: Store?
        let discover: Discovery?
        let seed: String?
    }

    struct HookSpec: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case json
            case plugin
        }

        struct Event: Codable, Equatable, Sendable {
            let name: String
            let state: TabActivityState?
            let matcher: String?
        }

        let kind: Kind
        let path: String
        let conversationField: String?
        let transcriptField: String?
        let toolField: String?
        let promptTitleField: String?
        let events: [Event]
    }

    let id: String
    let displayName: String
    let command: String
    let iconAsset: String
    let process: ProcessSpec
    let resume: ResumeSpec
    let hook: HookSpec

    var expandedHookURL: URL {
        URL(fileURLWithPath: (hook.path as NSString).expandingTildeInPath)
    }

    static func fallback(_ agent: SupportedAgent) -> AgentDefinition {
        AgentDefinition(
            id: agent.rawValue,
            displayName: agent.rawValue.capitalized,
            command: agent.rawValue,
            iconAsset: "AgentOpenAI",
            process: .init(executables: [agent.rawValue], runtimeMarkers: []),
            resume: .init(
                createArguments: nil,
                resumeArguments: [],
                store: nil,
                discover: nil,
                seed: nil
            ),
            hook: .init(
                kind: .json,
                path: "",
                conversationField: nil,
                transcriptField: nil,
                toolField: nil,
                promptTitleField: nil,
                events: []
            )
        )
    }
}

final class AgentCatalog: @unchecked Sendable {
    static let shared = AgentCatalog()

    private let definitions: [SupportedAgent: AgentDefinition]

    init(bundle: Bundle = .main) {
        let assetNames: [SupportedAgent: String] = [
            .codex: "AgentCodexManifest",
            .claude: "AgentClaudeManifest",
            .pi: "AgentPiManifest",
        ]
        definitions = Dictionary(uniqueKeysWithValues: SupportedAgent.allCases.map { agent in
            guard let assetName = assetNames[agent],
                  let data = NSDataAsset(name: assetName, bundle: bundle)?.data,
                  let definition = try? JSONDecoder().decode(AgentDefinition.self, from: data),
                  definition.id == agent.rawValue else {
                return (agent, .fallback(agent))
            }
            return (agent, definition)
        })
    }

    func definition(for agent: SupportedAgent) -> AgentDefinition {
        definitions[agent] ?? .fallback(agent)
    }
}
