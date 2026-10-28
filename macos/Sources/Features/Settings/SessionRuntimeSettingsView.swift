import SwiftUI

struct SessionRuntimeSettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @State private var host = ""
    let strings: SettingsStrings
    @State private var error: String?
    private func text(_ english: String, _ chinese: String) -> String { strings.t(english, chinese) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.runtimeTitle).font(.headline)
            HStack {
                TextField(strings.runtimeHostPlaceholder, text: $host)
                Button(strings.runtimeConnect) { connect() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(strings.runtimeConnectCaption)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(strings.runtimeDetachedHours)
                Spacer()
                TextField("72", value: $settings.runtimeDetachedHours, format: .number).frame(width: 80)
            }
            Text(strings.runtimeDetachedCaption)
                .font(.caption).foregroundStyle(.secondary)
            TextField(strings.runtimeExpirationPlaceholder, text: $settings.runtimeExpiration)
            Toggle(strings.runtimeCloseOnDone, isOn: $settings.runtimeCloseOnAgentDone)
            Text(strings.runtimeCloseOnDoneCaption)
                .font(.caption).foregroundStyle(.secondary)
            if settings.runtimeCloseOnAgentDone {
                HStack {
                    Text(strings.runtimeDoneGrace)
                    Spacer()
                    TextField("60", value: $settings.runtimeDoneGraceSeconds, format: .number).frame(width: 80)
                }
                Text(strings.runtimeDoneGraceCaption)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(strings.runtimeIdleCaption)
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func connect() {
        do {
            if !settings.runtimeExpiration.isEmpty && settings.runtimePolicy.expiresAt == nil {
                error = strings.runtimeInvalidDeadline
                return
            }
            let connection = try GitSSHConnection(destination: host.trimmingCharacters(in: .whitespacesAndNewlines))
            try SessionRuntimeConnections.shared.open(connection: connection, policy: settings.runtimePolicy)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
