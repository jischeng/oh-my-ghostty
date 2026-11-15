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
        _ = quickController.window
        #expect(quickController.visible)
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
        _ = quickController.window
        #expect(quickController.visible)

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
        #expect(!quickController.visible)
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

        var createdResolution: EditorHostResolution?
        defer {
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
            if let createdController = createdResolution?.controller {
                createdController.window?.delegate = nil
                createdController.window?.close()
            }
            for controller in existingEligible {
                controller.workspacePresentationIsParked = false
            }
        }

        createdResolution = quickController.resolveEditorHost(workingDirectory: "/tmp")
        let resolution = try #require(createdResolution)
        #expect(resolution.createdNewWindow)
        #expect(!beforeSet.contains(ObjectIdentifier(resolution.controller)))
        #expect(QuickTerminalController.isEligibleEditorHost(resolution.controller))
    }

    @Test func quickTerminalEditorHandoffHonorsSplitOnExistingWindowAndCurrentPaneOnNewWindow() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let cApp = try #require(app.app)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-qt-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existingFile = tempDir.appendingPathComponent("Existing.swift")
        let newWinFile = tempDir.appendingPathComponent("NewWindow.swift")
        try "let existing = 1\n".write(to: existingFile, atomically: true, encoding: .utf8)
        try "let fresh = 2\n".write(to: newWinFile, atomically: true, encoding: .utf8)

        let previousDestination = OhMyGhosttySettings.shared.editorFileOpenDestination
        OhMyGhosttySettings.shared.editorFileOpenDestination = .splitRight
        defer { OhMyGhosttySettings.shared.editorFileOpenDestination = previousDestination }

        let existingEligible = TerminalController.all.filter(QuickTerminalController.isEligibleEditorHost)
        for controller in existingEligible {
            controller.workspacePresentationIsParked = true
        }

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
        _ = quickController.window
        #expect(quickController.visible)

        var createdController: TerminalController?
        var outputURL: URL?
        defer {
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            EditorWorkspaceStore.shared.remove(surfaceIDs: Array(standardController.surfaceTree).map(\.id))
            if let createdController {
                EditorWorkspaceStore.shared.remove(surfaceIDs: Array(createdController.surfaceTree).map(\.id))
                createdController.window?.delegate = nil
                createdController.window?.close()
            }
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
            standardController.window?.delegate = nil
            standardController.window?.close()
            for controller in existingEligible {
                controller.workspacePresentationIsParked = false
            }
        }

        // 1) Reusing an existing standard window honors .splitRight (splits 1 -> 2 panes).
        #expect(Array(standardController.surfaceTree).count == 1)
        #expect(TerminalPathOpener.open("Existing.swift", from: quickSurface))
        for _ in 0..<40 where Array(standardController.surfaceTree).count < 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!quickController.visible)
        let splitSurfaces = Array(standardController.surfaceTree)
        #expect(splitSurfaces.count == 2)

        outputURL = TerminalCommandOutputActions.openOutputTextInEditor("split output\n", from: quickSurface)
        #expect(outputURL != nil)
        #expect(Array(standardController.surfaceTree).count == 3)

        // 2) Creating a brand-new standard window overrides .splitRight with .currentPane (stays 1 pane).
        standardController.workspacePresentationIsParked = true
        let knownBefore = Set(TerminalController.all.map(ObjectIdentifier.init))
        #expect(TerminalPathOpener.open("NewWindow.swift", from: quickSurface))
        for _ in 0..<40 where createdController == nil {
            createdController = TerminalController.all.first { !knownBefore.contains(ObjectIdentifier($0)) }
            if createdController == nil {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let freshController = try #require(createdController)
        let freshSurface = try #require(freshController.surfaceTree.first)
        let freshWorkspace = EditorWorkspaceStore.shared.workspace(
            for: freshController.tabSessionID,
            surfaceID: freshSurface.id
        )
        for _ in 0..<40 where freshWorkspace.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(Array(freshController.surfaceTree).count == 1)
        #expect(freshWorkspace.documents.map(\.path) == [newWinFile.resolvingSymlinksInPath().path])
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
        try Data("{\"ended\":null}".utf8).write(to: sessionFile)

        var reattachConfig = Ghostty.SurfaceConfiguration()
        let secondPane = QuickTerminalRuntimeSupport.prepareInitialConfiguration(
            &reattachConfig,
            settings: settings,
            environment: env
        )
        #expect(secondPane == QuickTerminalRuntimeSupport.dedicatedPaneID)
        #expect(reattachConfig.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] == "1")

        // Post-reboot `"lost"` local session remains attachable for resurrection, whereas `"exited"` starts fresh.
        try Data("{\"ended\":\"lost\"}".utf8).write(to: sessionFile)
        var lostConfig = Ghostty.SurfaceConfiguration()
        _ = QuickTerminalRuntimeSupport.prepareInitialConfiguration(
            &lostConfig,
            settings: settings,
            environment: env
        )
        #expect(lostConfig.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] == "1")

        try Data("{\"ended\":\"exited\"}".utf8).write(to: sessionFile)
        var exitedConfig = Ghostty.SurfaceConfiguration()
        _ = QuickTerminalRuntimeSupport.prepareInitialConfiguration(
            &exitedConfig,
            settings: settings,
            environment: env
        )
        #expect(exitedConfig.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] != "1")
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
