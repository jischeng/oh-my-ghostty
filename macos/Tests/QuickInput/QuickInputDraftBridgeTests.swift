import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct QuickInputDraftBridgeTests {
    @Test func unresponsiveAgentCannotDelayComposerPresentation() throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let settings = OhMyGhosttySettings.shared
        let previous = settings.quickInputImportShortcut
        settings.quickInputImportShortcut = "auto"
        defer { settings.quickInputImportShortcut = previous }
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/bin/sleep 30"
        configuration.workingDirectory = "/tmp"
        let controller = TerminalController(app.ghostty, withBaseConfig: configuration, tabLayout: .vertical)
        defer {
            controller.dismissQuickInput()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.focusedSurface)
        controller.adoptAgentResumeDescriptor(
            AgentResumeDescriptor(agent: .pi, scope: .local, workingDirectory: "/tmp"), for: surface
        )
        controller.quickInputModel.dismiss()
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        #expect(controller.quickInputModel.targetSurfaceID == surface.id)
        controller.toggleQuickInput()
        #expect(!controller.quickInputModel.isPresented)
    }

    @Test func automaticallySelectsKnownAndGenericShortcuts() {
        for agent in [SupportedAgent.pi, .codex, .claude] {
            #expect(QuickInputDraftBridge.shortcut(setting: "auto", agent: agent) == "control+g")
        }
        #expect(QuickInputDraftBridge.shortcut(setting: "auto", agent: nil) == "control+g")
        let opencode = QuickInputDraftBridge.shortcut(setting: "auto", agent: .opencode)
        #expect(opencode == "control+x,e")
        #expect(QuickInputDraftBridge.keys(opencode)?.last?.text == "e")
        #expect(QuickInputDraftBridge.keys(opencode)?.last?.mods.isEmpty == true)
        #expect(QuickInputDraftBridge.shortcut(setting: "", agent: .pi).isEmpty)
        #expect(QuickInputDraftBridge.shortcut(setting: "control+x,control+e", agent: .pi) == "control+x,control+e")
    }

    @Test func parsesGenericEditorShortcuts() throws {
        let keys = try #require(QuickInputDraftBridge.keys("control+x, control+e"))
        #expect(keys.map(\.key) == [.x, .e])
        #expect(keys.allSatisfy { $0.mods == .ctrl })
        #expect(QuickInputDraftBridge.keys("control+1")?.first?.key == .digit1)
        for invalid in ["", "g", "command+g", "control+g,", "control+;", "control+g,control+g,control+g,control+g,control+g"] {
            #expect(QuickInputDraftBridge.keys(invalid) == nil)
        }
    }

    @Test func helperCopiesCompleteDraftWithoutChangingAgentFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("editor.py")
        try QuickInputDraftBridge.helper.write(to: helper, atomically: true, encoding: .utf8)
        let surface = UUID().uuidString
        let identifier = UUID().uuidString
        let request = root.appendingPathComponent("\(surface).request")
        let draft = root.appendingPathComponent("agent draft.txt")
        let text = "中文 🐱\nsecond line\n\n"
        try text.write(to: draft, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: [
            "id": identifier, "expires": Date().timeIntervalSince1970 + 30,
        ]).write(to: request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, draft.path]
        process.environment = [
            "OMG_QUICK_INPUT_BRIDGE": root.path,
            "OMG_QUICK_INPUT_SURFACE": surface,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: draft, encoding: .utf8) == text)
        #expect(try String(contentsOf: root.appendingPathComponent("\(identifier).response"), encoding: .utf8) == text)
        // A helper inherited by a different pane must use its own request.
        let otherPane = Process()
        otherPane.executableURL = process.executableURL
        otherPane.arguments = process.arguments
        otherPane.environment = process.environment
        otherPane.environment?["OMG_QUICK_INPUT_SURFACE"] = UUID().uuidString
        otherPane.environment?["OMG_QUICK_INPUT_ORIGINAL_EDITOR"] = "/usr/bin/true"
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(identifier).response"))
        try otherPane.run()
        otherPane.waitUntilExit()
        #expect(otherPane.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(identifier).response").path))
    }

    @Test func helperDelegatesOrdinaryEditingToOriginalEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("editor.py")
        try QuickInputDraftBridge.helper.write(to: helper, atomically: true, encoding: .utf8)
        let draft = root.appendingPathComponent("file with spaces.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, draft.path]
        process.environment = [
            "OMG_QUICK_INPUT_BRIDGE": root.path,
            "OMG_QUICK_INPUT_SURFACE": UUID().uuidString,
            "OMG_QUICK_INPUT_ORIGINAL_EDITOR": "/usr/bin/touch",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: draft.path))
    }
}
