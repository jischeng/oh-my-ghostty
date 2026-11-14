import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct OMGDoctorTests {
    @Test func doctorDetectsMissingAccessibilityPermissionForGlobalKeybindsAndInvokesSelfHeal() async {
        var trusted = false
        var grantCalls = 0
        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { true },
            isAccessibilityTrusted: { trusted },
            isEventTapEnabled: { trusted },
            requestAccessibility: {
                grantCalls += 1
                trusted = true
                return true
            },
            resourcesURL: nil,
            homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sshControlDirectoryPath: "/tmp/nonexistent-\(UUID().uuidString)",
            surfaceCounter: { .init(visible: 2, occluded: 1) },
            residentMemoryProvider: { 128 * 1_024 * 1_024 }
        )

        let doctor = OMGDoctorService(dependencies: deps)
        await doctor.refresh()

        #expect(doctor.report.overallStatus == .warning)
        #expect(doctor.report.accessibility.status == .warning)
        #expect(doctor.report.accessibility.needsGrantAction)
        #expect(doctor.report.accessibility.summary(strings: SettingsStrings(language: .english)).contains("Accessibility"))
        #expect(doctor.report.accessibility.summary(strings: SettingsStrings(language: .simplifiedChinese)).contains("辅助功能"))

        #expect(doctor.grantAccessibilityPermission())
        await doctor.refresh()
        #expect(grantCalls == 1)
        #expect(doctor.report.accessibility.status == .healthy)
        #expect(!doctor.report.accessibility.needsGrantAction)
        #expect(doctor.report.overallStatus == .healthy)
    }

    @Test func doctorAuditsRuntimeSessionsSSHControlDirectoryAndAgentBackups() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-audit-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let runtimeDir = resources.appendingPathComponent("session-runtime", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let sshDir = root.appendingPathComponent("ssh-mux", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".omg/run/stateA/sessions"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let helperURL = runtimeDir.appendingPathComponent("omgd")
        try "#!/bin/sh\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try "rev-doctor-test\n".write(to: runtimeDir.appendingPathComponent("revision"), atomically: true, encoding: .utf8)

        let sessionsDir = home.appendingPathComponent(".omg/run/stateA/sessions")
        try Data("{\"exited\":false}".utf8).write(to: sessionsDir.appendingPathComponent("active.json"))
        try Data("{\"exited\":true}".utf8).write(to: sessionsDir.appendingPathComponent("exited.json"))
        try Data("{\"exited\":false}".utf8).write(to: sessionsDir.appendingPathComponent("closed.json"))
        try Data().write(to: sessionsDir.appendingPathComponent("closed.closed"))

        // Create one secure 0600 backup and one insecure 0644 backup.
        let secureBak = home.appendingPathComponent(".claude/settings.json.omg.bak")
        try OMGPrivateFileWriter.writeAtomically(Data("{}".utf8), to: secureBak)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".qwen"), withIntermediateDirectories: true)
        let insecureBak = home.appendingPathComponent(".qwen/settings.json.omg.bak")
        try Data("{}".utf8).write(to: insecureBak)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: insecureBak.path)

        let suiteName = "OMGDoctorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agentManager = AgentIntegrationManager(
            defaults: defaults,
            homeURL: home,
            snapshots: [
                AgentIntegrationManager.localID: AgentIntegrationSnapshot(
                    hooks: [.claude: .current],
                    cli: [.claude: .init(version: "1.0.0", path: "/usr/local/bin/claude")]
                ),
            ],
            connectionTargets: { [] },
            registry: registry
        )

        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { false },
            isAccessibilityTrusted: { true },
            isEventTapEnabled: { false },
            resourcesURL: resources,
            homeDirectory: home,
            sshControlDirectoryPath: sshDir.path,
            agentManager: agentManager,
            surfaceCounter: { .init(visible: 3, occluded: 2) },
            residentMemoryProvider: { 256 * 1_024 * 1_024 }
        )
        let doctor = OMGDoctorService(dependencies: deps)
        await doctor.refresh()

        #expect(doctor.report.runtimeSSH.omgdAvailable)
        #expect(doctor.report.runtimeSSH.omgdRevision == "rev-doctor-test")
        #expect(doctor.report.runtimeSSH.activeRuntimeSessions == 1)
        #expect(doctor.report.runtimeSSH.totalRuntimeSessionRecords == 3)
        #expect(!doctor.report.runtimeSSH.sshControlDirectoryHealthy)
        #expect(doctor.report.runtimeSSH.status == .warning)

        #expect(doctor.report.agentBackups.detectedCLICount == 1)
        #expect(doctor.report.agentBackups.installedHookCount == 1)
        #expect(doctor.report.agentBackups.backupFileCount == 2)
        #expect(doctor.report.agentBackups.insecureBackupCount == 1)
        #expect(doctor.report.agentBackups.status == .warning)

        // Tighten permissions to 0700 and 0600 -> everything turns healthy!
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: insecureBak.path)
        await doctor.refresh()

        #expect(doctor.report.runtimeSSH.sshControlDirectoryHealthy)
        #expect(doctor.report.runtimeSSH.status == .healthy)
        #expect(doctor.report.agentBackups.insecureBackupCount == 0)
        #expect(doctor.report.agentBackups.status == .healthy)
        #expect(doctor.report.overallStatus == .healthy)
    }

    @Test func doctorReclaimsIdleEditorWebViewsWhilePreservingOpenDocumentsForRehydration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("main.swift")
        try "print(\"hello\")\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = EditorWorkspaceStore()
        let ownerID = UUID()
        let surfaceID = UUID()
        let workspace = store.workspace(for: ownerID, surfaceID: surfaceID)
        defer { store.remove(surfaceIDs: [surfaceID]) }

        let fs = LocalWorkspaceFilesystem(workingDirectory: tempDir.path)
        workspace.open(path: fileURL.path, filesystem: fs)
        for _ in 0..<40 where workspace.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(workspace.documents.count == 1)
        _ = workspace.workbenchController.ensureWebView()
        #expect(workspace.workbenchController.webView != nil)
        #expect(store.resourceMetrics.activeWebViews == 1)
        #expect(store.resourceMetrics.idleReclaimableWebViews == 0)

        // Hide the editor pane -> its WebView becomes idle-reclaimable!
        workspace.isVisible = false
        #expect(store.resourceMetrics.idleReclaimableWebViews == 1)

        let lspManager = EditorLSPManager(serverCommands: [:])
        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { false },
            isAccessibilityTrusted: { true },
            isEventTapEnabled: { false },
            resourcesURL: nil,
            homeDirectory: tempDir,
            sshControlDirectoryPath: tempDir.appendingPathComponent("no-ssh").path,
            workspaceStore: store,
            lspManager: lspManager,
            surfaceCounter: { .init(visible: 1, occluded: 0) },
            residentMemoryProvider: { 64 * 1_024 * 1_024 }
        )
        let doctor = OMGDoctorService(dependencies: deps)
        await doctor.refresh()
        #expect(doctor.report.resources.activeWebViews == 1)
        #expect(doctor.report.resources.reclaimableWebViews == 1)

        let reclaimed = await doctor.reclaimIdleResources()
        #expect(reclaimed.reclaimedWebViews == 1)
        #expect(workspace.workbenchController.webView == nil)
        #expect(workspace.documents.count == 1)
        #expect(doctor.report.resources.activeWebViews == 0)
        #expect(doctor.report.resources.reclaimableWebViews == 0)

        // Uncollapsing the workspace rehydrates the WebView and open document seamlessly.
        let beforeRev = workspace.workbenchRehydrationRevision
        workspace.isVisible = true
        #expect(workspace.workbenchController.webView != nil)
        #expect(workspace.workbenchRehydrationRevision == beforeRev + 1)
        #expect(workspace.documents.first?.text == "print(\"hello\")\n")
    }

    @Test func nativePluginSettingsRendersOMGDoctorAndCommandPaletteActionWithoutTarballInstaller() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = OhMyGhosttySettings(fileURL: dir.appendingPathComponent("settings.json"))

        let suiteName = "OMGDoctorUI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)

        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            settings.language = language
            let controller = NativeSettingsController(
                settings: settings,
                initialSelection: .plugins,
                registry: registry,
                agents: agents
            )
            _ = controller.view
            controller.select(.plugins)
            controller.view.layoutSubtreeIfNeeded()

            let form = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
            let expectedLabel = SettingsStrings(language: language).doctorResourcesLabel
            #expect(form.rowTitles.contains(expectedLabel))
            #expect(!form.rowTitles.contains("GitHub"))
            #expect(!form.rowTitles.contains("Install package"))
            #expect(!form.rowTitles.contains("安装插件包"))
        }

        var didInvoke = false
        let enOption = TerminalCommandPaletteView.makeDoctorOption(language: .english) {
            didInvoke = true
        }
        #expect(enOption.title == "OMG Doctor")
        enOption.action()
        #expect(didInvoke)

        let zhOption = TerminalCommandPaletteView.makeDoctorOption(language: .simplifiedChinese) {}
        #expect(zhOption.title.contains("OMG Doctor"))
    }
}
