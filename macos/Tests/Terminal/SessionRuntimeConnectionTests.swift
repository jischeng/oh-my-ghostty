import AppKit
import Foundation
import Testing
@testable import Ghostty

struct SessionRuntimeConnectionTests {
    @MainActor
    @Test func remoteExitRestoresRetainedLocalSurfaceAndClearsDescriptor() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let local = Ghostty.SurfaceView(native, baseConfig: config)
        let remote = Ghostty.SurfaceView(native, baseConfig: config)
        remote.runtimeDescriptor = .init(connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp"), revision: "test", policy: .init())
        remote.runtimeLocalSurface = local
        let completion = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        remote.runtimeLocalCompletion = completion
        let controller = TerminalController(app, withSurfaceTree: .init(view: remote))
        _ = controller.window
        controller.focusedSurface = remote
        defer { controller.window?.delegate = nil; controller.window?.close(); try? FileManager.default.removeItem(at: completion) }
        SessionRuntimeHandoff.shared.returnToLocal(from: remote)
        #expect(controller.surfaceTree.first === local)
        #expect(controller.focusedSurface === local)
        #expect(remote.runtimeDescriptor == nil)
        #expect(remote.runtimeLocalSurface == nil)
        #expect(FileManager.default.fileExists(atPath: completion.path))
        let data = try JSONEncoder().encode(TerminalRestorableState(from: controller))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("runtimeDescriptor"))
    }

    @MainActor
    @Test func newTabIsLocalButSplitInheritsRuntime() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(native, baseConfig: config)
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp"), revision: "test", policy: .init())
        view.runtimeDescriptor = descriptor
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        try descriptor.configure(&config)
        config.environmentVariables["OMG_RUNTIME_SOCKET"] = "/tmp/remote.sock"
        config.environmentVariables["OMG_RUNTIME_PANE_ID"] = "old"
        let tab = try #require(controller.tabConfiguration(inherited: config, from: view))
        #expect(tab.workingDirectory == "/tmp")
        #expect(tab.command == nil)
        #expect(tab.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
        #expect(tab.environmentVariables["OMG_RUNTIME_SOCKET"] == nil)
        #expect(tab.environmentVariables["OMG_RUNTIME_PANE_ID"] == nil)
        let split = try #require(controller.splitConfiguration(inherited: nil, from: view))
        #expect(split.environmentVariables[SessionRuntimeDescriptor.environmentKey] != nil)
    }

    @MainActor
    @Test func runtimeSettingsStringsFollowLanguageAndSearch() {
        let en = SettingsStrings(language: .english)
        let zh = SettingsStrings(language: .simplifiedChinese)
        #expect(en.runtimeTitle == "Persistent SSH sessions")
        #expect(zh.runtimeTitle == "SSH 后台会话")
        #expect(en.runtimeTitle != zh.runtimeTitle)
        #expect(SettingsStrings(language: .system, preferredLanguages: ["zh-CN"]).runtimeTitle == zh.runtimeTitle)
        #expect(zh.runtimeDoneGraceCaption.contains("最长保留期限"))
        let entries = SettingsSearchCatalog.entries(strings: zh)
        #expect(entries.contains { $0.settingIDs.contains("sessions.runtimeDetachedHours") && $0.title == zh.runtimeTitle })
    }

    @Test func hostIdentityIncludesExactRoutingAndRuntimeRevision() throws {
        let a = try GitSSHConnection(destination: "devbox", options: ["-p", "2222", "-J", "jump"])
        let b = try GitSSHConnection(destination: "devbox", options: ["-p", "2223", "-J", "jump"])
        let first = SessionRuntimeDescriptor(connection: a, revision: "abc", policy: .init())
        let second = SessionRuntimeDescriptor(connection: b, revision: "abc", policy: .init())
        #expect(first.identity != second.identity)
        #expect(first.identity != SessionRuntimeDescriptor(connection: a, revision: "def", policy: .init()).identity)
        let decoded = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
    }

    @Test func restoredPaneCannotSilentlyCreateANewRemoteProcess() throws {
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "devbox"), revision: "abc", policy: .init())
        let id = UUID()
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, restoring: false).utf8)) as? [String: Any])
        let restored = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, restoring: true).utf8)) as? [String: Any])
        #expect(fresh["id"] as? String == id.uuidString.lowercased())
        #expect(fresh["create"] as? Bool == true)
        #expect(restored["create"] as? Bool == false)
        #expect((restored["policy"] as? [String: Any])?["detached_ttl_seconds"] as? Int == 259200)
        #expect((restored["policy"] as? [String: Any])?["close_on_agent_done"] as? Bool == true)
    }

    @MainActor
    @Test func lifetimeSettingsPersistAndRemainBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.runtimePolicy.detachedTTLSeconds == 259200)
        #expect(settings.runtimePolicy.closeOnAgentDone)
        settings.runtimeDetachedHours = 2
        settings.runtimeCloseOnAgentDone = false
        settings.runtimeDoneGraceSeconds = 15
        settings.runtimeExpiration = "2030-01-01T00:00:00Z"
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.runtimePolicy.detachedTTLSeconds == 7200)
        #expect(!restored.runtimePolicy.closeOnAgentDone)
        #expect(restored.runtimePolicy.agentDoneGraceSeconds == 15)
        #expect(restored.runtimePolicy.expiresAt == 1_893_456_000)
        settings.runtimeDetachedHours = -1
        #expect(settings.runtimePolicy.detachedTTLSeconds == 0)
    }

    @Test func runtimeSidebarUsesSSHIdentityAndRemoteDirectory() throws {
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "user@devbox"),
            revision: "test", policy: .init())
        var context = PaneSessionContext(workingDirectory: "/Users/test/code", terminalTitle: "local")
        context.applyRuntimeConnection(descriptor, workingDirectory: nil)
        #expect(context.isSSHSession)
        #expect(context.presentationTitle == "user@devbox")
        context.applyRuntimeConnection(descriptor, workingDirectory: "/srv/project")
        #expect(context.workingDirectory == "/srv/project")
        #expect(context.remoteTabBreadcrumb?.host == "user@devbox")
        #expect(context.remoteTabBreadcrumb?.directory == "project")
    }

    @Test func existingSessionPoliciesKeepTheirExplicitValues() throws {
        let old = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "devbox"),
            revision: "previous", policy: .init(detachedTTLSeconds: 86400, closeOnAgentDone: false))
        let restored = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: JSONEncoder().encode(old))
        #expect(restored.policy.detachedTTLSeconds == 86400)
        #expect(!restored.policy.closeOnAgentDone)
        #expect(SessionRuntimePolicy().detachedTTLSeconds == 259200)
        #expect(SessionRuntimePolicy().closeOnAgentDone)
    }
}
