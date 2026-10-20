import SwiftUI

struct AgentHookSetupStatusView: View {
    let state: AgentHookSetupState
    let operation: AgentIntegrationOperation?
    let strings: SettingsStrings

    var body: some View {
        switch state {
        case .queued:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(strings.agentSetupQueued) }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text((operation?.kind == .hooks ? strings.agentInstallingHooks : strings.agentDiscovering) +
                     (operation?.agent.map { " · " + $0.displayName } ?? "") +
                     ((operation?.total ?? 0) > 0 ? " (\((operation?.completed ?? 0) + 1)/\(operation?.total ?? 0))" : ""))
            }
        case .finished(let result):
            if let error = result.error {
                AgentIntegrationErrorView(title: strings.agentSetupIncomplete, message: error, strings: strings)
            } else {
                Label(result.detected == 0 ? strings.agentSetupNoneFound : strings.agentSetupComplete,
                      systemImage: result.detected == 0 ? "info.circle" : "checkmark.circle")
                    .foregroundStyle(.secondary)
                if result.installed > 0 { Text(strings.agentRestartBrief).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Short, actionable first line. Technical output remains available on demand;
/// Python tracebacks and native-updater logs do not dominate the setup controls.
struct AgentIntegrationErrorView: View {
    let title: String
    let message: String
    let strings: SettingsStrings
    var cli = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            let affected = AgentIntegrationErrorHint.affectedAgents(message)
            if !affected.isEmpty {
                Text(affected.map(\.displayName).joined(separator: " · ")).foregroundStyle(.secondary)
            }
            if cli {
                Text(strings.agentCLIErrorIndependent).foregroundStyle(.secondary)
                if AgentIntegrationErrorHint.isAuthenticationFailure(message) {
                    Text(strings.agentCLIAuthenticationHint).foregroundStyle(.secondary)
                } else if AgentIntegrationErrorHint.isPackageManagerFailure(message) {
                    Text(strings.agentCLIPackageManagerHint).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(strings.agentTechnicalDetails, isExpanded: $expanded) {
                Text(message).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.font(.caption)
    }
}

enum AgentIntegrationErrorHint {
    static func affectedAgents(_ message: String) -> [SupportedAgent] {
        SupportedAgent.allCases.filter { message.contains($0.displayName + ":") }
    }

    static func isAuthenticationFailure(_ message: String) -> Bool {
        let value = message.lowercased()
        return ["unauthenticated", "unauthorized", "authentication", "not logged in"].contains { value.contains($0) }
    }

    static func isPackageManagerFailure(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("npm install") || value.contains("package manager") || value.contains("包管理器")
    }
}
