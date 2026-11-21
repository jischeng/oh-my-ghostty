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
        fileMenu.addItem(NSMenuItem(
            title: "Cut",
            action: nil,
            keyEquivalent: "x"
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
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Browse Sessions…",
            action: nil,
            keyEquivalent: ""
        ))
        window.submenu = windowMenu
        root.addItem(window)

        SettingsMenuLocalizer.apply(
            to: root,
            strings: SettingsStrings(language: .simplifiedChinese)
        )
        #expect(root.items[0].title == "文件")
        #expect(root.items[0].submenu?.items[0].title == "新建窗口")
        #expect(root.items[0].submenu?.items[1].title == "Dynamic Workspace Name")
        #expect(root.items[0].submenu?.items[2].title == "剪切")
        #expect(root.items[1].title == "显示")
        #expect(root.items[1].submenu?.items[0].title == "显示或隐藏检查器")
        #expect(root.items[2].title == "窗口")
        #expect(root.items[2].submenu?.items[0].title == "浏览后台会话…")
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
        #expect(root.items[2].title == "Window")
        #expect(root.items[2].submenu?.items[0].title == "Browse Sessions…")
    }

    @Test func translatesTerminalAndTabContextMenusBuiltInEnglish() {
        let menu = NSMenu()
        for title in ["Copy", "Split Right", "Close Split", "Reset Terminal", "Toggle Terminal Inspector",
                      "Change Tab Title...", "Close Tabs to the Right", "Rename Tab...", "cloud · mapping-platform"] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        SettingsMenuLocalizer.apply(to: menu, strings: SettingsStrings(language: .simplifiedChinese))
        #expect(menu.items.map(\.title) == [
            "复制", "向右分屏", "关闭分屏", "重置终端", "切换终端检查器",
            "修改标签页标题…", "关闭右侧标签页", "重命名标签页…", "cloud · mapping-platform",
        ])
        // A reused menu is translated back from either language.
        SettingsMenuLocalizer.apply(to: menu, strings: SettingsStrings(language: .english))
        #expect(menu.items.map(\.title) == [
            "Copy", "Split Right", "Close Split", "Reset Terminal", "Toggle Terminal Inspector",
            "Change Tab Title...", "Close Tabs to the Right", "Rename Tab...", "cloud · mapping-platform",
        ])
    }
}
