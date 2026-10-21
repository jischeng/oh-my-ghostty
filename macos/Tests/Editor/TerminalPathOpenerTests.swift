import AppKit
import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

struct TerminalPathOpenerTests {
    @Test func resolvesPlainPathsAndFileURLsAgainstTheClickedPane() {
        #expect(TerminalPathTarget.path("README.md", directory: "/project/one", isRemote: false) == "/project/one/README.md")
        #expect(TerminalPathTarget.path("README.md", directory: "/remote/two", isRemote: true) == "/remote/two/README.md")
        #expect(TerminalPathTarget.path("'App icon.icon'", directory: "/project", isRemote: false) == "/project/App icon.icon")
        #expect(TerminalPathTarget.path("\"App icon.icon\"", directory: "/project", isRemote: false) == "/project/App icon.icon")
        #expect(TerminalPathTarget.path("README.md", directory: "", isRemote: false) == nil)
        #expect(TerminalPathTarget.path("/project/README.md", directory: "", isRemote: false) == "/project/README.md")
        #expect(TerminalPathTarget.path("src/file.swift:12:3", directory: "/project", isRemote: false) == "/project/src/file.swift")
        #expect(TerminalPathTarget.path("file:///tmp/%E4%B8%AD%E6%96%87%20%23.md#42", directory: "/", isRemote: false) == "/tmp/中文 #.md")
        #expect(TerminalPathTarget.path("file://server/home/me/readme.md", directory: "/remote", isRemote: true) == "/home/me/readme.md")
        #expect(TerminalPathTarget.path("file://unrelated.invalid/etc/passwd", directory: "/", isRemote: false) == nil)
        #expect(TerminalPathTarget.path("https://example.com", directory: "/", isRemote: false) == nil)
        #expect(TerminalPathTarget.path("file:///tmp/a%0Ab", directory: "/", isRemote: false) == nil)
        #expect(TerminalPathTarget.path("~/README.md", directory: "/remote", isRemote: true) == nil)
    }

    @Test func standaloneFullStopIsNotAPathLink() {
        for remote in [false, true] {
            for value in [".", "'.'", "\".\"", ".:12"] {
                #expect(TerminalPathTarget.path(value, directory: "/project", isRemote: remote) == nil)
            }
            for value in ["./", "./README.md", ".gitignore", "../README.md"] {
                #expect(TerminalPathTarget.path(value, directory: "/project", isRemote: remote) != nil)
            }
            #expect(TerminalPathTarget.path("file:///project/", directory: "/project", isRemote: remote) == "/project")
        }
    }

    @Test func remoteLinksIgnoreLocalHistoryAndResolveChineseOSC8Targets() {
        let remote = "/home/user/deeproute/mapping.worktrees/trajectory_server_to_paimon"
        for history in [nil, "", "/Users/me/local", "file:///Users/me/local"] as [String?] {
            let base = TerminalPathTarget.baseDirectory(historical: history, paneDirectory: remote, isRemote: true)
            #expect(base == remote)
            #expect(TerminalPathTarget.path("docs/Bag轨迹入湖替换缺口核查.md", directory: base, isRemote: true)
                    == remote + "/docs/Bag轨迹入湖替换缺口核查.md")
            #expect(TerminalPathTarget.path("adapter", directory: base, isRemote: true) == remote + "/adapter")
            #expect(TerminalPathTarget.path("/srv/docs/a.md", directory: base, isRemote: true) == "/srv/docs/a.md")
        }
        #expect(TerminalPathTarget.baseDirectory(historical: "/old", paneDirectory: "/new", isRemote: false) == "/old")
        #expect(TerminalPathTarget.baseDirectory(historical: "", paneDirectory: "/new", isRemote: false) == "")
    }

    @Test @MainActor func directoryClickNeverSubmitsCdToAnAgent() {
        #expect(TerminalPathOpener.directoryDestination(preferred: .currentPane, hasAgent: true) == .splitRight)
        #expect(TerminalPathOpener.directoryDestination(preferred: .currentPane, hasAgent: false) == .currentPane)
        #expect(TerminalPathOpener.directoryDestination(preferred: .newTab, hasAgent: true) == .newTab)
        #expect(TerminalPathOpener.directoryDestination(preferred: .splitDown, hasAgent: true) == .splitDown)
    }

    @Test func directoryCommandTreatsShellMetacharactersAsLiteralNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("folder ' $(echo oops); 中文")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", TerminalPathTarget.directoryCommand(folder.path) + " && pwd -P"]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let actual = try #require(String(data: output, encoding: .utf8)).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    }

    @Test @MainActor func terminalPathsOpenInEditorAndFolderChangesTheSameShell() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# preview".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("# different child file".utf8).write(to: folder.appendingPathComponent("README.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = OhMyGhosttySettings.shared
        let oldFile = settings.editorFileOpenDestination
        let oldDirectory = settings.editorDirectoryOpenDestination
        defer {
            settings.editorFileOpenDestination = oldFile
            settings.editorDirectoryOpenDestination = oldDirectory
        }
        settings.editorFileOpenDestination = .currentPane
        settings.editorDirectoryOpenDestination = .currentPane
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = root.path
        config.command = "/bin/bash --noprofile --norc -i"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer {
            EditorWorkspaceStore.shared.remove(tabID: controller.tabSessionID)
            window.delegate = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        let surface = try #require(controller.surfaceTree.first)
        try await Task.sleep(for: .milliseconds(200))
        surface.surfaceModel?.sendText("printf '\\033]7;file://localhost%s\\007' \"$PWD\"")
        surface.surfaceModel?.sendKeyEvent(.init(key: .enter))
        for _ in 0..<100 {
            if surface.pwd != nil, surface.window != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(surface.window != nil)
        try #require(!surface.processExited, Comment(rawValue: surface.cachedScreenContents.get()))
        let pwd = try #require(surface.pwd)
        #expect(URL(fileURLWithPath: pwd).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        let workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: surface.id)
        let cApp = try #require(app.app)
        let cSurface = try #require(surface.surface)
        // Hover carries the raw target and historical base separately, just as
        // the click action does. A relative target must not acquire a '/' from
        // Foundation's process-cwd URL normalization.
        var hoverTarget = ghostty_target_s()
        hoverTarget.tag = GHOSTTY_TARGET_SURFACE
        hoverTarget.target.surface = cSurface
        var hoverAction = ghostty_action_s()
        hoverAction.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
        let hoverValue = "docs/中文.md"
        hoverValue.withCString { value in
            root.path.withCString { base in
                hoverAction.action.mouse_over_link.url = value
                hoverAction.action.mouse_over_link.len = hoverValue.utf8.count
                hoverAction.action.mouse_over_link.base_directory = base
                hoverAction.action.mouse_over_link.base_directory_len = root.path.utf8.count
                _ = Ghostty.App.action(cApp, target: hoverTarget, action: hoverAction)
            }
        }
        for _ in 0..<50 {
            if surface.hoverUrl == root.path + "/docs/中文.md" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(surface.hoverUrl == root.path + "/docs/中文.md")
        func dispatchLink(_ value: String, kind: ghostty_action_open_url_kind_e, baseDirectory: String? = nil) -> Bool {
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = cSurface
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            action.action.open_url.kind = kind
            action.action.open_url.len = UInt(value.utf8.count)
            return value.withCString { pointer in
                action.action.open_url.url = pointer
                if let baseDirectory {
                    return baseDirectory.withCString { base in
                        action.action.open_url.base_directory = base
                        action.action.open_url.base_directory_len = UInt(baseDirectory.utf8.count)
                        return Ghostty.App.action(cApp, target: target, action: action)
                    }
                }
                return Ghostty.App.action(cApp, target: target, action: action)
            }
        }
        #expect(dispatchLink("README.md", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN))
        for _ in 0..<100 {
            if workspace.selectedDocument != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let opened = try #require(workspace.selectedDocument?.path)
        #expect(URL(fileURLWithPath: opened).resolvingSymlinksInPath() == root.appendingPathComponent("README.md").resolvingSymlinksInPath())
        #expect(workspace.isVisible)
        #expect(!TerminalPathOpener.open("https://example.com", from: surface))
        #expect(TerminalPathOpener.open("not-a-file", from: surface))
        #expect(dispatchLink(folder.absoluteString, kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8))
        for _ in 0..<100 {
            if !workspace.isVisible { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!workspace.isVisible)
        let capture = root.appendingPathComponent("pwd.txt")
        surface.surfaceModel?.sendText("pwd -P > '" + capture.path + "'")
        surface.surfaceModel?.sendKeyEvent(.init(key: .enter))
        for _ in 0..<100 {
            if let text = try? String(contentsOf: capture, encoding: .utf8), !text.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let changedDirectory = try String(contentsOf: capture, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: changedDirectory).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        surface.pwd = folder.path
        #expect(dispatchLink("README.md", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, baseDirectory: root.path))
        for _ in 0..<100 {
            if workspace.isVisible, !workspace.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.selectedDocument?.text == "# preview")
        #expect(workspace.documents.count == 1)
    }
}
