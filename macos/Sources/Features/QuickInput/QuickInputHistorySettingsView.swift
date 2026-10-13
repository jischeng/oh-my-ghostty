import SwiftUI

struct QuickInputHistorySettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @ObservedObject private var store = QuickInputHistoryStore.shared
    @State private var confirmingClear = false
    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }

    var body: some View {
        Picker(strings.quickInputHistoryScopeLabel, selection: $settings.quickInputHistoryScope) {
            ForEach(QuickInputHistoryScope.allCases, id: \.self) { scope in
                Text(strings.quickInputHistoryScopeName(scope)).tag(scope)
            }
        }
        LabeledContent(strings.quickInputHistoryRetentionLabel) {
            HStack(spacing: 6) {
                TextField("", value: $settings.quickInputHistoryRetentionDays,
                          format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 48)
                    .accessibilityLabel(strings.quickInputHistoryRetentionLabel)
                Text(strings.quickInputHistoryDayUnit)
                Stepper("", value: $settings.quickInputHistoryRetentionDays, in: 1...365, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(strings.quickInputHistoryRetentionLabel)
            }
            .fixedSize()
        }
        Toggle(strings.quickInputHistoryKeepLabel, isOn: $settings.quickInputHistoryKeepAfterQuit)
        Text(strings.quickInputHistoryPrivacyCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
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
