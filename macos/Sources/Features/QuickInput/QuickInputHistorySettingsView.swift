import SwiftUI

struct QuickInputHistorySettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @ObservedObject private var store = QuickInputHistoryStore.shared
    @State private var confirmingClear = false
    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }

    var body: some View {
        OMGSettingsRow(strings.quickInputHistoryScopeLabel) {
            OMGSettingsPicker(title: strings.quickInputHistoryScopeLabel, selection: $settings.quickInputHistoryScope,
                              options: QuickInputHistoryScope.allCases.map { .init($0, strings.quickInputHistoryScopeName($0)) }, showsTitle: false)
        }
        Divider()
        OMGSettingsRow(strings.quickInputHistoryInsertionLabel) {
            OMGSettingsPicker(title: strings.quickInputHistoryInsertionLabel, selection: $settings.quickInputHistoryInsertionMode,
                              options: QuickInputHistoryInsertionMode.allCases.map { .init($0, strings.quickInputHistoryInsertionName($0)) }, showsTitle: false)
        }
        Divider()
        OMGSettingsRow(strings.quickInputHistoryRetentionLabel) {
            OMGSettingsNumberControl(title: strings.quickInputHistoryRetentionLabel,
                                     value: $settings.quickInputHistoryRetentionDays, range: 1...365,
                                     suffix: strings.quickInputHistoryDayUnit)
        }
        Divider()
        OMGSettingsRow(strings.quickInputHistoryKeepLabel, subtitle: strings.quickInputHistoryPrivacyCaption) {
            Toggle(strings.quickInputHistoryKeepLabel, isOn: $settings.quickInputHistoryKeepAfterQuit)
                .labelsHidden().toggleStyle(.switch)
        }
        Button(strings.quickInputHistoryClearButton, role: .destructive) {
            confirmingClear = true
        }
        .disabled(store.entries.isEmpty)
        .alert(strings.quickInputHistoryClearTitle, isPresented: $confirmingClear) {
            Button(strings.quickInputHistoryClearConfirm, role: .destructive) { store.clear() }
            Button(strings.quickInputHistoryClearCancel, role: .cancel) {}
        } message: {
            Text(strings.quickInputHistoryClearMessage)
        }
        if store.storageError != nil {
            Label(strings.quickInputHistoryStorageError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
