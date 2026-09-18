import AppKit
import Testing
@testable import Ghostty

/// The Edit menu drives the standard editing commands for every text field in
/// the application, so its shortcuts must never be dropped by the
/// configuration-driven menu sync.
@MainActor
struct MenuShortcutManagerMenuShortcutTests {
    private func makeConfig(_ contents: String = "# no overrides\n") throws -> Ghostty.Config {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-shortcuts-\(UUID().uuidString)")
            .appendingPathExtension("ghostty")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return Ghostty.Config(at: file.path)
    }

    private func makeItem() -> NSMenuItem {
        NSMenuItem(title: "item", action: nil, keyEquivalent: "")
    }

    @Test func standardEditingActionsKeepPlatformShortcuts() throws {
        let config = try makeConfig()
        let manager = Ghostty.MenuShortcutManager()

        let expected: [(action: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("undo", "z", .command),
            ("redo", "z", [.command, .shift]),
            ("copy_to_clipboard", "c", .command),
            ("paste_from_clipboard", "v", .command),
            ("select_all", "a", .command),
        ]

        for entry in expected {
            let item = makeItem()
            manager.syncMenuShortcut(config, action: entry.action, menuItem: item)
            #expect(item.keyEquivalent == entry.key, "unexpected key for \(entry.action)")
            #expect(
                item.keyEquivalentModifierMask == entry.modifiers,
                "unexpected modifiers for \(entry.action)")
        }
    }

    @Test func configuredShortcutOverridesPlatformShortcut() throws {
        let config = try makeConfig("keybind = cmd+shift+c=copy_to_clipboard\n")
        let manager = Ghostty.MenuShortcutManager()
        let item = makeItem()

        manager.syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: item)

        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test func actionWithoutShortcutIsCleared() throws {
        let config = try makeConfig()
        let manager = Ghostty.MenuShortcutManager()
        let item = makeItem()

        manager.syncMenuShortcut(config, action: "check_for_updates", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }
}
