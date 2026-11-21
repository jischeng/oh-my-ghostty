import Foundation

enum InspectorPortForwardStatus: Equatable, Sendable {
    case starting
    case active
    case failed(String)
}

struct InspectorPortForwardItem: Identifiable, Equatable, Sendable {
    let id: String
    let remoteHost: String
    let remotePort: Int
    let localPort: Int?
    let processName: String?
    let status: InspectorPortForwardStatus
}

struct InspectorPortForwardList: Equatable, Sendable {
    let hostAlias: String
    let items: [InspectorPortForwardItem]
    var canCreate = true
}

struct PortForwardTarget: Equatable, Sendable {
    static let loopbackHost = "127.0.0.1"

    let host: String
    let port: Int

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    var sshHost: String { host.contains(":") ? "[\(host)]" : host }
    var displayValue: String {
        host == Self.loopbackHost ? String(port) : "\(sshHost):\(port)"
    }

    static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(value), validPort(port) {
            return .init(host: loopbackHost, port: port)
        }

        let host: String
        let portText: String
        if value.hasPrefix("["), let closing = value.lastIndex(of: "]"),
           value.index(after: closing) < value.endIndex,
           value[value.index(after: closing)] == ":" {
            host = String(value[value.index(after: value.startIndex)..<closing])
            portText = String(value[value.index(closing, offsetBy: 2)...])
        } else if let separator = value.lastIndex(of: ":"),
                  !value[..<separator].contains(":") {
            host = String(value[..<separator])
            portText = String(value[value.index(after: separator)...])
        } else {
            return nil
        }
        guard validHost(host), let port = Int(portText), validPort(port) else {
            return nil
        }
        return .init(host: host, port: port)
    }

    private static func validPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_:%")
        )
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// The Agent conversation running in a pane, as the Info pane presents it.
struct InspectorInfoAgent: Equatable, Sendable {
    let agent: SupportedAgent
    let conversationID: String
    /// Transcript file on this Mac. Nil for a remote conversation, and until
    /// a local one has been located.
    let sessionPath: String?
    /// SSH target for a conversation running on a remote host.
    let remoteHost: String?
}

struct InspectorInfoContent: Equatable, Sendable {
    /// Reserved for a future machine-status summary. Nil keeps the section hidden.
    let status: InspectorField?
    let fields: [InspectorField]
    let portForwards: InspectorPortForwardList
    let historyItems: [InspectorHistoryItem]
    let agent: InspectorInfoAgent?
    let isAgentSession: Bool
    let agentName: String?
    let historyState: PaneAgentHistoryService.State

    init(
        status: InspectorField? = nil,
        fields: [InspectorField] = [],
        portForwards: InspectorPortForwardList = .init(hostAlias: "", items: []),
        historyItems: [InspectorHistoryItem] = [],
        agent: InspectorInfoAgent? = nil,
        isAgentSession: Bool = false,
        agentName: String? = nil,
        historyState: PaneAgentHistoryService.State = .ready
    ) {
        self.status = status
        self.fields = fields
        self.portForwards = portForwards
        self.historyItems = historyItems
        self.agent = agent
        self.isAgentSession = isAgentSession
        self.agentName = agentName
        self.historyState = historyState
    }
}
