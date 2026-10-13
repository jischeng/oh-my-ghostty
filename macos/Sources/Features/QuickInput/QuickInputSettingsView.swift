import SwiftUI

struct QuickInputSettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }

    var body: some View {
        Toggle(strings.openQuickInputOnAgentStartLabel, isOn: $settings.openQuickInputOnAgentStart)
        Text(strings.openQuickInputOnAgentStartCaption)
            .font(.caption).foregroundStyle(.secondary)
        Toggle(strings.openQuickInputOnAgentCompleteLabel, isOn: $settings.openQuickInputOnAgentComplete)
        Text(strings.openQuickInputOnAgentCompleteCaption)
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent(strings.quickInputShortcutLabel) {
            HStack(spacing: 8) {
                OMGShortcutRecorder(storageValue: $settings.quickInputShortcut)
                    .frame(width: 112, height: 24)
                Button(strings.resetShortcutButton) {
                    settings.quickInputShortcut = OMGKeyboardShortcut.defaultQuickInput.storageValue
                }
            }
        }
        Text(strings.quickInputShortcutCaption)
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Text(strings.quickInputHeightLabel)
            Slider(value: $settings.quickInputHeight,
                   in: Double(AgentQuickInputMetrics.minimumHeight)...Double(AgentQuickInputMetrics.maximumHeight),
                   step: 1)
            Text("\(Int(settings.quickInputHeight)) pt")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        Text(strings.quickInputHeightCaption)
            .font(.caption).foregroundStyle(.secondary)
        if let shortcut = OMGKeyboardShortcut(storageValue: settings.quickInputShortcut),
           let conflict = shortcut.conflictingMenuItemTitle() {
            Label(strings.shortcutConflictCaption(conflict), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        Divider()
        Text(strings.quickInputHistoryTitle).font(.headline)
        QuickInputHistorySettingsView(settings: settings)
    }
}
