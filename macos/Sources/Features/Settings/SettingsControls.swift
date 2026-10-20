import AppKit
import SwiftUI

/// Shared settings control metrics. Keep native menus/switches and keyboard
/// behavior, but draw the trigger ourselves instead of the compact AppKit bezel.
enum OMGSettingsControlMetrics {
    static let height: CGFloat = 32
    static let radius: CGFloat = 8
}

struct OMGSettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}

struct OMGSettingsPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [OMGSettingsOption<Value>]
    var showsTitle = true
    var width: CGFloat = 180
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var selectedTitle: String { options.first { $0.value == selection }?.title ?? String(describing: selection) }

    var body: some View {
        if showsTitle {
            OMGSettingsRow(title) { trigger }
        } else {
            trigger
        }
    }

    private var trigger: some View {
        HStack(spacing: 8) {
            Text(selectedTitle).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).frame(width: width, height: OMGSettingsControlMetrics.height)
        .background(.primary.opacity(isEnabled && hovering ? 0.09 : 0.045),
                    in: RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius).strokeBorder(.primary.opacity(0.09)))
        .accessibilityHidden(true)
        .overlay {
            OMGSettingsMenuTrigger(title: title, selection: $selection, options: options, enabled: isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(selectedTitle)
    }
}

struct OMGSettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 13)
            .frame(minHeight: OMGSettingsControlMetrics.height)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.085 : 0.045),
                        in: RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius).strokeBorder(.primary.opacity(0.09)))
            .contentShape(RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

struct OMGSettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: OMGSettingsControlMetrics.radius).strokeBorder(.primary.opacity(0.12)))
    }
}

/// A real segmented control for short, mutually exclusive choices.
struct OMGSettingsSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [OMGSettingsOption<Value>]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 12, weight: selection == option.value ? .medium : .regular))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selection == option.value ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + " · " + option.title)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(3).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.07)))
        .opacity(isEnabled ? 1 : 0.45)
    }
}
