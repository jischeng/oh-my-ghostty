import SwiftUI

/// A cached inventory is a hint, not permission to write to an SSH account.
/// Unknown inventories invite an explicit check; known inventories only flag
/// installed CLIs with missing/outdated Hooks (never detector-only Agents).
enum SSHAgentHookOnboarding: Equatable {
    case checkRequired
    case setupRequired([SupportedAgent])

    static func prompt(snapshot: AgentIntegrationSnapshot?) -> Self? {
        guard let snapshot, snapshot.error == nil, !snapshot.cli.isEmpty else { return .checkRequired }
        let installed = SupportedAgent.allCases.filter {
            $0.definition.hook.kind != .none && snapshot.cli[$0]?.path != nil
        }
        let needed = installed.filter {
            snapshot.hooks[$0] == .missing || snapshot.hooks[$0] == .updateAvailable
        }
        if !needed.isEmpty { return .setupRequired(needed) }
        if installed.contains(where: { snapshot.hooks[$0] == nil }) { return .checkRequired }
        return nil
    }
}

/// Does not connect, register, or install merely because a pane became ready.
/// Checking/registering is an explicit click; installation remains per-Agent in Settings.
struct SSHAgentHookOnboardingBanner: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var registry: SSHHostRegistry = .shared
    @ObservedObject var manager: AgentIntegrationManager = .shared
    @ObservedObject var settings: OhMyGhosttySettings = .shared
    @State private var dismissed: Set<String> = []
    @State private var checking: Set<String> = []
    @State private var sessionRevision: UInt64 = 0

    private var strings: SettingsStrings { .init(language: settings.language) }

    private var connection: GitSSHConnection? {
        _ = sessionRevision
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        guard let session = controller.paneSessionContext(for: surface),
              case .sshReady = session.state else { return nil }
        return try? GitSSHConnection(session: session)
    }

    var body: some View {
        Group {
            if settings.agentStatusHooksEnabled, let connection {
                let target = registry.targetID(for: connection)
                let snapshot = registry.host(target)?.snapshot
                if !dismissed.contains(target), let prompt = SSHAgentHookOnboarding.prompt(snapshot: snapshot) {
                    banner(connection: connection, target: target, prompt: prompt)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalPaneSessionContextsDidChange)) { _ in
            sessionRevision &+= 1
        }
    }

    private func banner(connection: GitSSHConnection, target: String, prompt: SSHAgentHookOnboarding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(strings.sshAgentHookTitle + " · " + connection.destination).fontWeight(.medium)
                Text(strings.sshAgentHookPrompt).foregroundStyle(.secondary)
                if case .setupRequired(let agents) = prompt {
                    Text(strings.sshAgentHooksNeeded(agents.map(\.displayName).joined(separator: ", ")))
                        .foregroundStyle(.secondary)
                }
                if let error = registry.errors[target] {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Button(strings.sshAgentHookCheck) { check(connection, target: target) }
                    .disabled(checking.contains(target) || registry.isCollecting(target) || manager.busy.contains(target))
            }
            Spacer(minLength: 0)
            if checking.contains(target) { ProgressView().controlSize(.small) }
            Button { dismissed.insert(target) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain).help(strings.sshAgentHookDismiss)
            .accessibilityLabel(strings.sshAgentHookDismiss)
        }
        .font(.caption).controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func check(_ captured: GitSSHConnection, target: String) {
        checking.insert(target)
        Task {
            defer { checking.remove(target) }
            // Uses the pane's exact SSH options, including configured target mapping.
            await registry.register(captured, targetID: target)
            guard registry.errors[target] == nil, registry.host(target) != nil,
                  connection == captured, !dismissed.contains(target) else { return }
            manager.loadCached(target: target)
            SettingsNavigation.openAgentIntegration(target: target)
        }
    }
}
