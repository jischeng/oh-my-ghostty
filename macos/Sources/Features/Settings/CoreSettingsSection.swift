import SwiftUI

struct CoreSettingsSection: View {
    let group: CoreSetting.Group
    @ObservedObject var settings: OhMyGhosttySettings
    private var strings: SettingsStrings { .init(language: settings.language) }

    var body: some View {
        OMGSettingsSection(group.title(strings)) {
            let fields = CoreSetting.all.filter { $0.group == group }
            ForEach(fields) { field in
                if field.id != fields.first?.id { Divider() }
                OMGSettingsRow(field.title(strings), subtitle: field.help(strings) +
                    (field.requiresNewTerminal ? " · " + strings.newTerminalRequired : "")) {
                    Picker(field.title(strings), selection: Binding(
                        get: { settings.coreOverrides[field.key] ?? "" },
                        set: { settings.setCoreOverride(field.key, value: $0) }
                    )) {
                        Text(strings.inheritCoreSetting).tag("")
                        ForEach(field.values, id: \.self) { value in
                            Text(field.valueTitle(value, strings: strings)).tag(value)
                        }
                    }
                    .labelsHidden().frame(width: 180)
                    .help(field.key + (field.requiresNewTerminal ? " · " + strings.newTerminalRequired : ""))
                }
            }
        }
    }
}

/// Shared setting row: labels on the left, a bounded control on the right;
/// captions wrap within the available width instead of widening the window.
struct OMGSettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            label.frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 6)
    }
}

struct OMGSettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 20) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }
    }
}
