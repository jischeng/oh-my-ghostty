import AppKit
import SwiftUI

/// A transparent native button fills the visual trigger. SwiftUI's Menu bridge
/// reconstructs complex labels on macOS and loses their spacing/backgrounds.
/// NSMenu preserves keyboard navigation, type-ahead and VoiceOver without that
/// bridge, and opens from the entire control rather than just its text.
struct OMGSettingsMenuTrigger<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [OMGSettingsOption<Value>]
    var enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = SettingsMenuButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .exterior
        button.setAccessibilityRole(.popUpButton)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(options.first { $0.value == selection }?.title ?? String(describing: selection))
    }

    final class Coordinator: NSObject {
        var parent: OMGSettingsMenuTrigger
        init(_ parent: OMGSettingsMenuTrigger) { self.parent = parent }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            for (index, option) in parent.options.enumerated() {
                let item = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.representedObject = Choice(value: option.value)
                item.state = option.value == parent.selection ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc func open(_ sender: NSButton) {
            guard parent.enabled else { return }
            let menu = makeMenu()
            menu.minimumWidth = sender.bounds.width
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func choose(_ sender: NSMenuItem) {
            guard parent.enabled, let choice = sender.representedObject as? Choice,
                  parent.options.contains(where: { $0.value == choice.value }) else { return }
            parent.selection = choice.value
        }

        private final class Choice: NSObject {
            let value: Value
            init(value: Value) { self.value = value }
        }
    }
}

private final class SettingsMenuButton: NSButton {
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
