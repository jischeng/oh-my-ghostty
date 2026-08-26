import AppKit
import Testing
@testable import Ghostty

@MainActor
struct SettingsMenuLocalizerTests {
    @Test func translatesKnownMenuTitlesAndRestoresEnglish() throws {
        let root = NSMenu(title: "Main Menu")
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "New Window",
            action: nil,
            keyEquivalent: "n"
        ))
        fileMenu.addItem(NSMenuItem(
            title: "Dynamic Workspace Name",
            action: nil,
            keyEquivalent: ""
        ))
        file.submenu = fileMenu
        root.addItem(file)
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(
            title: "Toggle Inspector",
            action: nil,
            keyEquivalent: "i"
        ))
        view.submenu = viewMenu
        root.addItem(view)

        SettingsMenuLocalizer.apply(
            to: root,
            strings: SettingsStrings(language: .simplifiedChinese)
        )
        #expect(root.items[0].title == "文件")
        #expect(root.items[0].submenu?.items[0].title == "新建窗口")
        #expect(root.items[0].submenu?.items[1].title == "Dynamic Workspace Name")
        #expect(root.items[1].title == "显示")
        #expect(root.items[1].submenu?.items[0].title == "显示或隐藏检查器")
        #expect(root.items[0].submenu?.items[0].keyEquivalent == "n")

        SettingsMenuLocalizer.apply(
            to: root,
            strings: SettingsStrings(language: .english)
        )
        #expect(root.items[0].title == "File")
        #expect(root.items[0].submenu?.items[0].title == "New Window")
        #expect(root.items[0].submenu?.items[1].title == "Dynamic Workspace Name")
        #expect(root.items[1].title == "View")
        #expect(root.items[1].submenu?.items[0].title == "Toggle Inspector")
    }
}
