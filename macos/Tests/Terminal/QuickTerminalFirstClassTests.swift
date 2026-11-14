import AppKit
import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

@MainActor
struct QuickTerminalFirstClassTests {
    @Test func quickTerminalResolvesFileLinksAndChecksLocalExistence() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let cApp = try #require(app.app)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-qt-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("notes.swift")
        try "let answer = 42\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = tempDir.path

        let quickController = QuickTerminalController(app, baseConfig: config)
        let quickSurface = Ghostty.SurfaceView(cApp, baseConfig: config)
        quickSurface.pwd = tempDir.path
        quickController.surfaceTree = SplitTree(view: quickSurface)
        defer {
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
        }

        let resolved = try #require(
            TerminalPathOpener.resolve("notes.swift:1", from: quickSurface, baseDirectory: tempDir.path)
        )
        #expect(resolved.path == fileURL.resolvingSymlinksInPath().path || resolved.path == fileURL.path)
        #expect(resolved.location == EditorTextLocation(startLine: 1))
        #expect(resolved.host === quickController)

        let itemKind = try await resolved.filesystem.itemType(at: resolved.path)
        #expect(itemKind == .file)

        let missingResolved = try #require(
            TerminalPathOpener.resolve("missing.swift", from: quickSurface, baseDirectory: tempDir.path)
        )
        let missingKind = try await missingResolved.filesystem.itemType(at: missingResolved.path)
        #expect(missingKind == nil)

        TerminalLinkChecker.check(url: "notes.swift", baseDirectory: tempDir.path, from: quickSurface)
        TerminalLinkChecker.check(url: "missing.swift", baseDirectory: tempDir.path, from: quickSurface)
    }

    @Test func clickingFileInQuickTerminalOpensInFrontmostStandardWindowEditor() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let cApp = try #require(app.app)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-qt-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("App.swift")
        try "struct App {}\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()

        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = tempDir.path

        let standardController = TerminalController(
            app,
            withBaseConfig: config,
            workspaceID: store.defaultID,
            workspaceCoordinator: coordinator
        )
        standardController.window?.makeKeyAndOrderFront(nil)

        let quickController = QuickTerminalController(app, baseConfig: config)
        let quickSurface = Ghostty.SurfaceView(cApp, baseConfig: config)
        quickSurface.pwd = tempDir.path
        quickController.surfaceTree = SplitTree(view: quickSurface)

        defer {
            if let hostSurface = standardController.surfaceTree.first {
                EditorWorkspaceStore.shared.remove(surfaceIDs: [hostSurface.id])
            }
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
            standardController.window?.delegate = nil
            standardController.window?.close()
        }

        let opened = TerminalPathOpener.open("App.swift", from: quickSurface)
        #expect(opened)

        let hostSurface = try #require(standardController.surfaceTree.first)
        let workspace = EditorWorkspaceStore.shared.workspace(
            for: standardController.tabSessionID,
            surfaceID: hostSurface.id
        )
        for _ in 0..<40 where workspace.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(workspace.documents.map(\.path) == [fileURL.resolvingSymlinksInPath().path])
        #expect(workspace.isVisible)
    }

    @Test func quickTerminalCreatesNewStandardWindowWhenNoneIsOpenForEditorHandoff() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let cApp = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp"

        // Temporarily park any existing standard controllers so none are eligible.
        let existingEligible = TerminalController.all.filter(QuickTerminalController.isEligibleEditorHost)
        for controller in existingEligible {
            controller.workspacePresentationIsParked = true
        }

        let beforeSet = Set(TerminalController.all.map(ObjectIdentifier.init))
        let quickController = QuickTerminalController(app, baseConfig: config)
        let quickSurface = Ghostty.SurfaceView(cApp, baseConfig: config)
        quickController.surfaceTree = SplitTree(view: quickSurface)

        var createdController: TerminalController?
        defer {
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
            if let createdController {
                createdController.window?.delegate = nil
                createdController.window?.close()
            }
            for controller in existingEligible {
                controller.workspacePresentationIsParked = false
            }
        }

        createdController = quickController.resolveEditorHostController(workingDirectory: "/tmp")
        let resolved = try #require(createdController)
        #expect(!beforeSet.contains(ObjectIdentifier(resolved)))
        #expect(QuickTerminalController.isEligibleEditorHost(resolved))
    }

    @Test func quickTerminalSupportsCommandHistoryAndOutputEditorHandoff() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let cApp = try #require(app.app)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()

        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp"

        let standardController = TerminalController(
            app,
            withBaseConfig: config,
            workspaceID: store.defaultID,
            workspaceCoordinator: coordinator
        )
        standardController.window?.makeKeyAndOrderFront(nil)

        let quickController = QuickTerminalController(app, baseConfig: config)
        let quickSurface = Ghostty.SurfaceView(cApp, baseConfig: config)
        quickController.surfaceTree = SplitTree(view: quickSurface)

        let history = TerminalHistoryService.shared
        let epoch = history.synchronizeSession(surfaceID: quickSurface.id, connectionID: nil) {}
        let item = InspectorHistoryItem(
            id: "qt-cmd",
            kind: .command,
            text: "echo hello",
            timestamp: Date(),
            location: .command(surfaceID: quickSurface.id, executionID: 1, epoch: epoch),
            sourceLabel: "Local"
        )
        _ = history.synchronizeSession(
            surfaceID: quickSurface.id,
            connectionID: "ssh-temp",
            captured: { [item] },
            clear: {}
        )

        var openedOutputURL: URL?
        defer {
            if let openedOutputURL {
                try? FileManager.default.removeItem(at: openedOutputURL)
            }
            history.removeSurface(quickSurface.id)
            if let hostSurface = standardController.surfaceTree.first {
                EditorWorkspaceStore.shared.remove(surfaceIDs: [hostSurface.id])
            }
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
            standardController.window?.delegate = nil
            standardController.window?.close()
        }

        let records = history.commands(for: quickSurface.id)
        #expect(records.contains { $0.text == "echo hello" })

        openedOutputURL = TerminalCommandOutputActions.openOutputTextInEditor(
            "build succeeded\n",
            from: quickSurface
        )
        #expect(openedOutputURL != nil)

        let hostSurface = try #require(standardController.surfaceTree.first)
        let workspace = EditorWorkspaceStore.shared.workspace(
            for: standardController.tabSessionID,
            surfaceID: hostSurface.id
        )
        for _ in 0..<40 where workspace.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(workspace.documents.count == 1)
        #expect(workspace.documents.first?.text == "build succeeded\n")
    }

    @Test func quickTerminalSupportsDirectorySplitAndOptionalPersistentRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-qt-runtime-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let runtimeDir = resources.appendingPathComponent("session-runtime", isDirectory: true)
        let supportDir = root.appendingPathComponent("Support", isDirectory: true)
        let homeDir = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helperURL = runtimeDir.appendingPathComponent("omgd")
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try "qt-rev-1\n".write(to: runtimeDir.appendingPathComponent("revision"), atomically: true, encoding: .utf8)
        try "snap-1\n".write(to: runtimeDir.appendingPathComponent("snapshot-revision"), atomically: true, encoding: .utf8)

        let settings = OhMyGhosttySettings(fileURL: root.appendingPathComponent("settings.json"))
        #expect(!settings.quickTerminalRuntimeEnabled)

        let env = QuickTerminalRuntimeSupport.EnvironmentContext(
            resources: resources,
            applicationSupportRoot: supportDir,
            homeDirectory: homeDir,
            isRunningTests: false
        )

        var ephemeralConfig = Ghostty.SurfaceConfiguration()
        let disabledPane = QuickTerminalRuntimeSupport.prepareInitialConfiguration(
            &ephemeralConfig,
            settings: settings,
            environment: env
        )
        #expect(disabledPane == nil)
        #expect(ephemeralConfig.environmentVariables["GHOSTTY_QUICK_TERMINAL"] == "1")
        #expect(ephemeralConfig.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)

        settings.quickTerminalRuntimeEnabled = true
        var persistentConfig = Ghostty.SurfaceConfiguration()
        let firstPane = QuickTerminalRuntimeSupport.prepareInitialConfiguration(
            &persistentConfig,
            settings: settings,
            environment: env
        )
        #expect(firstPane == QuickTerminalRuntimeSupport.dedicatedPaneID)
        #expect(persistentConfig.environmentVariables[SessionRuntimeDescriptor.environmentKey] != nil)
        #expect(persistentConfig.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] != "1")

        let encoded = try #require(persistentConfig.environmentVariables[SessionRuntimeDescriptor.environmentKey])
        let descriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(encoded.utf8))
        let stateDir = SessionRuntimeConnections.localStateDirectory(
            for: descriptor,
            applicationSupportRoot: supportDir,
            homeDirectory: homeDir
        )
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionFile = sessionsDir.appendingPathComponent(
            "\(QuickTerminalRuntimeSupport.dedicatedPaneID.uuidString.lowercased()).json"
        )
        try Data("{\"exited\":false}".utf8).write(to: sessionFile)

        var reattachConfig = Ghostty.SurfaceConfiguration()
        let secondPane = QuickTerminalRuntimeSupport.prepareInitialConfiguration(
            &reattachConfig,
            settings: settings,
            environment: env
        )
        #expect(secondPane == QuickTerminalRuntimeSupport.dedicatedPaneID)
        #expect(reattachConfig.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] == "1")
    }

    @Test func quickTerminalGeometryClampsStrictlyWithinVisibleFrameWithoutMutatingDock() throws {
        // Simulate a screen with both a bottom Dock (80pt) and top menu bar (28pt).
        let visibleFrame = NSRect(x: 0, y: 80, width: 1_440, height: 800)
        let oversized = QuickTerminalSize(
            primary: .pixels(900),
            secondary: .pixels(1_600)
        )

        for position in [
            QuickTerminalPosition.bottom,
            .top,
            .left,
            .right,
            .center,
        ] {
            let closed = NSRect(x: 0, y: 0, width: 1_600, height: 900)
            let final = position.resolvedFinalFrame(
                in: visibleFrame,
                terminalSize: oversized,
                closedFrame: closed
            )
            #expect(final.minX >= visibleFrame.minX)
            #expect(final.minY >= visibleFrame.minY)
            #expect(final.maxX <= visibleFrame.maxX)
            #expect(final.maxY <= visibleFrame.maxY)
        }
    }
}
