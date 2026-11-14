import AppKit
import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct ProgrammaticInputSecurityTests {
    @Test func localCanonicalNoEchoTTYMatchesPasswordPromptOnly() throws {
        var primaryFD: Int32 = -1
        var replicaFD: Int32 = -1
        var nameBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let opened = nameBuffer.withUnsafeMutableBufferPointer { ptr in
            Darwin.openpty(&primaryFD, &replicaFD, ptr.baseAddress, nil, nil)
        }
        try #require(opened == 0)
        defer {
            if primaryFD >= 0 { Darwin.close(primaryFD) }
            if replicaFD >= 0 { Darwin.close(replicaFD) }
        }
        let ttyPath = String(cString: nameBuffer)

        var cookedEcho = termios()
        try #require(tcgetattr(replicaFD, &cookedEcho) == 0)
        cookedEcho.c_lflag |= tcflag_t(ICANON | ECHO)
        try #require(tcsetattr(replicaFD, TCSANOW, &cookedEcho) == 0)
        #expect(!ProgrammaticInputGuard.isLocalTTYCanonicalNoEcho(ttyPath))

        var passwordMode = cookedEcho
        passwordMode.c_lflag |= tcflag_t(ICANON)
        passwordMode.c_lflag &= ~tcflag_t(ECHO)
        try #require(tcsetattr(replicaFD, TCSANOW, &passwordMode) == 0)
        #expect(ProgrammaticInputGuard.isLocalTTYCanonicalNoEcho(ttyPath))

        var rawMode = cookedEcho
        cfmakeraw(&rawMode)
        try #require(tcsetattr(replicaFD, TCSANOW, &rawMode) == 0)
        #expect(!ProgrammaticInputGuard.isLocalTTYCanonicalNoEcho(ttyPath))
    }

    @Test func unfocusedPasswordSurfaceStillBlocksQuickInputDraftSendAndQueueDequeue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("codex")
        let ready = root.appendingPathComponent("ready")
        let captured = root.appendingPathComponent("captured")
        try """
        import os, pathlib, tty
        tty.setraw(0)
        pathlib.Path(\(String(reflecting: ready.path))).write_text("ready")
        buf = bytearray()
        while True:
            chunk = os.read(0, 1)
            if not chunk:
                break
            buf.extend(chunk)
            pathlib.Path(\(String(reflecting: captured.path))).write_bytes(bytes(buf))
        """.write(to: script, atomically: true, encoding: .utf8)

        let settings = OhMyGhosttySettings.shared
        let previousHooks = settings.agentStatusHooksEnabled
        let previousLanguage = settings.language
        let previousImport = settings.quickInputImportShortcut
        settings.agentStatusHooksEnabled = true
        settings.language = .english
        settings.quickInputImportShortcut = "ctrl+g"
        defer {
            settings.agentStatusHooksEnabled = previousHooks
            settings.language = previousLanguage
            settings.quickInputImportShortcut = previousImport
        }

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let python = try #require(LocalPythonInterpreter.cached())
        var config = Ghostty.SurfaceConfiguration()
        config.command = Ghostty.Shell.quote(python.executablePath) + " " + Ghostty.Shell.quote(script.path)
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer {
            controller.quickInputDraftImportTask?.cancel()
            controller.dismissQuickInput()
            controller.window?.delegate = nil
            controller.window?.close()
        }

        let surface = try #require(controller.surfaceTree.first)
        try await waitForAppKit { FileManager.default.fileExists(atPath: ready.path) }

        // Simulate a password prompt followed by QuickInput taking focus away from the terminal.
        surface.passwordInput = true
        defer { surface.passwordInput = false }
        surface.focusDidChange(false)
        #expect(!SecureInput.shared.enabled)
        #expect(surface.isPasswordInputActive)
        #expect(surface.blocksProgrammaticInput)
        #expect(controller.isQuickInputPasswordLocked(for: surface.id))
        #expect(!(surface as any GitTerminalSurfaceTarget).sendText("git status"))

        // 1. Opening QuickInput and requesting explicit draft import must NOT send Ctrl+G ($EDITOR bridge).
        controller.presentQuickInput(for: surface, requestFocus: false)
        controller.importQuickInputDraftFromTerminal(for: surface.id)
        #expect(controller.quickInputDraftImportTask == nil)
        #expect(controller.quickInputModel.statusMessage == "Waiting for password input in terminal")

        // Verify Simplified Chinese localization too.
        settings.language = .simplifiedChinese
        #expect(
            SettingsStrings(language: settings.language).quickInputPasswordLockedMessage ==
                "终端正在等待密码输入"
        )

        // 2. Manual Send must fail closed, retain draft, and surface localized lock message.
        controller.quickInputModel.draft = "secret-multiline\npayload"
        let submitted = controller.submitQuickInputText(
            controller.quickInputModel.draft,
            to: surface.id,
            restoreFocus: false
        )
        #expect(!submitted)
        #expect(controller.quickInputModel.draft == "secret-multiline\npayload")
        #expect(controller.quickInputModel.statusMessage == "终端正在等待密码输入")

        settings.language = .english

        // 3. Queued auto-dequeue must keep the head item untouched while password input is active.
        let group = try #require(surface.surfaceModel?.foregroundPID)
        let contextID = "omg-agent-codex-\(group)"
        let metadata = "type=app;omg_agent=codex;omg_scope=local;omg_liveness=pgid;omg_state="
        surface.contextSignal = .init(action: .start, id: contextID, metadata: metadata + "working")
        controller.quickInputModel.draft = "first queued message"
        controller.queueQuickInputDraft()
        controller.quickInputModel.draft = "second queued message"
        controller.queueQuickInputDraft()
        #expect(controller.quickInputModel.state(for: surface.id)?.queue.map(\.text) == [
            "first queued message",
            "second queued message",
        ])

        surface.contextSignal = .init(action: .start, id: contextID, metadata: metadata + "done")
        controller.dispatchNextQuickInput(for: surface.id)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.quickInputModel.state(for: surface.id)?.queue.map(\.text) == [
            "first queued message",
            "second queued message",
        ])
        #expect(controller.quickInputModel.statusMessage == "Waiting for password input in terminal")
        #expect(!FileManager.default.fileExists(atPath: captured.path))

        // 4. Clearing passwordInput automatically resumes queued dispatch of the retained head item.
        surface.passwordInput = false
        try await waitForAppKit {
            guard let data = try? Data(contentsOf: captured),
                  let text = String(data: data, encoding: .utf8) else {
                return false
            }
            return text.contains("first queued message\r")
        }
        try await waitForAppKit {
            controller.quickInputModel.state(for: surface.id)?.queue.map(\.text) == ["second queued message"]
        }
    }

    @Test func appleScriptAndIntentGuardsRejectPasswordPromptSurface() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
        }

        let surface = try #require(controller.surfaceTree.first)
        surface.passwordInput = true
        defer { surface.passwordInput = false }
        surface.focusDidChange(false)
        #expect(!SecureInput.shared.enabled)

        let scriptTerminal = ScriptTerminal(surfaceView: surface)

        let inputCmd = ScriptInputTextCommand()
        inputCmd.directParameter = "injected-secret"
        inputCmd.arguments = ["terminal": scriptTerminal]
        _ = inputCmd.performDefaultImplementation()
        #expect(inputCmd.scriptErrorNumber == Int(errAEEventFailed))
        #expect(inputCmd.scriptErrorString?.contains("password input") == true)

        let keyCmd = ScriptKeyEventCommand()
        keyCmd.directParameter = "enter"
        keyCmd.arguments = ["terminal": scriptTerminal]
        _ = keyCmd.performDefaultImplementation()
        #expect(keyCmd.scriptErrorNumber == Int(errAEEventFailed))
        #expect(keyCmd.scriptErrorString?.contains("password input") == true)

        let errorText = String(localized: GhosttyIntentError.passwordInputActive.localizedStringResource)
        #expect(errorText.contains("password input"))
    }
}
