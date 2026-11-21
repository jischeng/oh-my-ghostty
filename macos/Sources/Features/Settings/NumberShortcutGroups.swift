import AppKit

/// Modifier combinations offered for "modifier + digit" shortcut families
/// (sidebar tabs, right sidebar panels, workspaces).
enum OMGNumberShortcutModifiers: String, CaseIterable {
    case command
    case option
    case control
    case controlCommand = "control+command"
    case optionCommand = "option+command"
    case controlOption = "control+option"

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: [.command]
        case .option: [.option]
        case .control: [.control]
        case .controlCommand: [.control, .command]
        case .optionCommand: [.option, .command]
        case .controlOption: [.control, .option]
        }
    }

    var symbols: String {
        OMGKeyboardShortcut(key: "1", modifiers: flags).displayValue.dropLast().description
    }

    /// Ghostty's keybind spelling of the same modifiers.
    var ghosttyPrefix: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.command) { parts.append("super") }
        return parts.joined(separator: "+")
    }

    func shortcut(digit: Int) -> String {
        OMGKeyboardShortcut(key: "\(digit)", modifiers: flags).storageValue
    }

    /// The combination shared by every `modifier + digit` value, or nil when
    /// the slots were customised individually.
    static func shared(by shortcuts: [String]) -> Self? {
        let parsed = shortcuts.enumerated().map { index, value -> Self? in
            guard let shortcut = OMGKeyboardShortcut(storageValue: value), shortcut.key == "\(index + 1)" else { return nil }
            return allCases.first { $0.flags == shortcut.modifiers }
        }
        guard let first = parsed.first, let value = first, parsed.allSatisfy({ $0 == value }) else { return nil }
        return value
    }

    /// Overlay lines that move Ghostty's tab-number bindings off Command.
    var tabKeybindLines: [String] {
        guard self != .command else { return [] }
        var lines: [String] = []
        for digit in 1...8 {
            lines.append("keybind = super+digit_\(digit)=unbind")
            lines.append("keybind = super+\(digit)=unbind")
            lines.append("keybind = \(ghosttyPrefix)+digit_\(digit)=goto_tab:\(digit)")
            lines.append("keybind = \(ghosttyPrefix)+\(digit)=goto_tab:\(digit)")
        }
        lines.append("keybind = super+9=unbind")
        lines.append("keybind = \(ghosttyPrefix)+9=last_tab")
        return lines
    }
}

/// Keeps the sidebar toggles' menu key equivalents in step with OMG settings.
@MainActor
enum OMGMenuShortcuts {
    static func apply(to menu: NSMenu?, settings: OhMyGhosttySettings) {
        guard let menu else { return }
        let bindings: [(Selector, String)] = [
            (#selector(AppDelegate.toggleSidebar(_:)), settings.toggleSidebarShortcut),
            (#selector(AppDelegate.toggleInspector(_:)), settings.toggleInspectorShortcut),
        ]
        for item in menu.items {
            if let action = item.action, let value = bindings.first(where: { $0.0 == action })?.1,
               let shortcut = OMGKeyboardShortcut(storageValue: value) {
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.modifiers
            }
            apply(to: item.submenu, settings: settings)
        }
    }
}
