import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

struct VerticalTabsTests {
    @Test func derivedGroupsRejectCrossGroupDrops() {
        let projectA = UUID()
        let projectB = UUID()

        #expect(VerticalTabDropPolicy.allows(source: projectA, in: [projectA]))
        #expect(!VerticalTabDropPolicy.allows(source: projectB, in: [projectA]))
        #expect(!VerticalTabDropPolicy.allows(source: nil, in: [projectA]))
    }

    @Test func rowHalfBoundarySelectsBeforeAndAfter() {
        #expect(VerticalTabDropPolicy.placement(y: 0, rowHeight: 40) == .before)
        #expect(VerticalTabDropPolicy.placement(y: 19.999, rowHeight: 40) == .before)
        #expect(VerticalTabDropPolicy.placement(y: 20, rowHeight: 40) == .after)
        #expect(VerticalTabDropPolicy.placement(y: 40, rowHeight: 40) == .after)
    }

    @Test func beforeAfterAndEndResolveInsertionIndices() {
        #expect(VerticalTabDropPolicy.insertionIndex(
            destinationIndex: 2,
            placement: .before
        ) == 2)
        #expect(VerticalTabDropPolicy.insertionIndex(
            destinationIndex: 2,
            placement: .after
        ) == 3)
        #expect(VerticalTabDropPolicy.insertionIndex(
            destinationIndex: 4,
            placement: .end
        ) == 4)
    }

    @Test func insertionCorrectsWhenSourcePrecedesDestination() {
        #expect(VerticalTabDropPolicy.destinationIndex(
            sourceIndex: 1,
            insertionIndex: 4,
            tabCount: 5
        ) == 3)
        #expect(VerticalTabDropPolicy.destinationIndex(
            sourceIndex: 4,
            insertionIndex: 1,
            tabCount: 5
        ) == 1)
        #expect(VerticalTabDropPolicy.destinationIndex(
            sourceIndex: 0,
            insertionIndex: 5,
            tabCount: 5
        ) == 4)
    }

    @Test func transactionPlanCommitsOnlyAtItsExactPostAttachIndex() throws {
        let plan = try #require(VerticalTabMoveTransactionPlan(
            sourceIndexAfterAttach: 1,
            insertionIndex: 4,
            tabCount: 5
        ))

        #expect(plan.destinationIndex == 3)
        #expect(plan.validates(actualIndex: 3, tabCount: 5))
        #expect(!plan.validates(actualIndex: 4, tabCount: 5))
        #expect(!plan.validates(actualIndex: 3, tabCount: 4))
        #expect(!plan.validates(actualIndex: nil, tabCount: 5))
        #expect(VerticalTabMoveTransactionPlan(
            sourceIndexAfterAttach: nil,
            insertionIndex: 2,
            tabCount: 4
        ) == nil)
        #expect(VerticalTabMoveTransactionPlan(
            sourceIndexAfterAttach: 4,
            insertionIndex: 2,
            tabCount: 4
        ) == nil)
    }

    @Test func onlyPerformedDropRejectsUpdates() {
        var activity = VerticalTabDropActivity.idle
        #expect(activity.acceptsUpdates)
        activity = .active
        #expect(activity.acceptsUpdates)
        activity = .performed
        #expect(!activity.acceptsUpdates)
    }

    @Test func rowDropPayloadRoutesPaneAndTabThroughOneDestination() {
        #expect(VerticalTabDropPayload.resolve(
            hasSurface: false,
            hasTab: true
        ) == .tab)
        #expect(VerticalTabDropPayload.resolve(
            hasSurface: true,
            hasTab: false
        ) == .surface)
        #expect(VerticalTabDropPayload.resolve(
            hasSurface: true,
            hasTab: true
        ) == .surface)
        #expect(VerticalTabDropPayload.resolve(
            hasSurface: false,
            hasTab: false
        ) == nil)
    }

    @Test func tabDragLifecycleEndsOnMouseUpOrEscape() {
        #expect(VerticalTabDragLifecyclePolicy.shouldFinish(
            eventType: .leftMouseUp,
            keyCode: 0
        ))
        #expect(VerticalTabDragLifecyclePolicy.shouldFinish(
            eventType: .keyDown,
            keyCode: 53
        ))
        #expect(!VerticalTabDragLifecyclePolicy.shouldFinish(
            eventType: .keyDown,
            keyCode: 36
        ))
        #expect(!VerticalTabDragLifecyclePolicy.shouldFinish(
            eventType: .mouseMoved,
            keyCode: 0
        ))
    }

    @Test func stableMoveDescriptorResolvesRecreatedValuesBySessionID() throws {
        struct Value {
            let generation: Int
            let sessionID: UUID
        }
        let sourceID = UUID()
        let destinationID = UUID()
        let movedID = UUID()
        let descriptor = VerticalTabMoveTransactionDescriptor(
            sourceTabSessionID: sourceID,
            sourceSurfaceID: UUID(),
            destinationTabSessionID: destinationID,
            placement: .after,
            movedTabSessionID: movedID
        )
        let recreated = [
            Value(generation: 2, sessionID: movedID),
            Value(generation: 2, sessionID: sourceID),
            Value(generation: 2, sessionID: destinationID),
        ]

        let redo = try #require(VerticalTabStableResolver.resolve(
            sessionIDs: descriptor.redoSessionIDs,
            in: recreated,
            sessionID: \.sessionID
        ))
        let undoSessionIDs = try #require(descriptor.undoSessionIDs)
        let undo = try #require(VerticalTabStableResolver.resolve(
            sessionIDs: undoSessionIDs,
            in: recreated,
            sessionID: \.sessionID
        ))
        #expect(redo.map(\.sessionID) == [sourceID, destinationID])
        #expect(undo.map(\.sessionID) == [sourceID, destinationID, movedID])
        #expect(undo.allSatisfy { $0.generation == 2 })
        #expect(VerticalTabStableResolver.resolve(
            sessionIDs: descriptor.redoSessionIDs,
            in: Array(recreated.dropLast()),
            sessionID: \.sessionID
        ) == nil)
        #expect(VerticalTabStableResolver.resolve(
            sessionIDs: [sourceID],
            in: recreated + [Value(generation: 1, sessionID: sourceID)],
            sessionID: \.sessionID
        ) == nil)
    }

    @Test func paneMoveSnapshotCarriesSSHAndAgentCanonicalValues() throws {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/project",
            terminalTitle: "project"
        )
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-transfer",
                metadata: "type=remote;targethost=build"
            ),
            currentWorkingDirectory: "/Users/test/project",
            currentTerminalTitle: "project"
        )
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-transfer",
                metadata: "type=remote;targethost=build;cwd=/srv/project"
            ),
            currentWorkingDirectory: "/srv/project",
            currentTerminalTitle: "build"
        )
        let activity = TabActivity(
            source: SupportedAgent.claude.rawValue,
            state: .working,
            label: "Claude",
            message: "Running",
            detail: nil,
            progress: nil,
            icon: nil
        )
        let descriptor = AgentResumeDescriptor(
            agent: .claude,
            scope: .remote,
            workingDirectory: "/srv/project",
            sshReplay: .init(
                version: 1,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: true,
                cache: true,
                args: ["build"]
            )
        )
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(.init(
            action: .start,
            id: "omg-agent-claude-123",
            metadata: "type=app;omg_agent=claude;omg_scope=remote;omg_state=working"
        ))
        let snapshot = PaneSessionStateSnapshot(
            context: context,
            activity: activity,
            resumeDescriptor: descriptor,
            resumeContextID: "omg-agent-claude-123",
            reducer: reducer,
            typedHookContextID: "omg-agent-claude-123",
            observedForegroundProcessID: nil,
            detectedAgent: nil,
            screenSignature: nil,
            screenStableTicks: nil
        )

        #expect(snapshot.context == context)
        #expect(snapshot.activity == activity)
        #expect(snapshot.resumeDescriptor == descriptor)
        #expect(snapshot.reducer?.trackedContextCount == 1)
        #expect(snapshot.typedHookContextID == "omg-agent-claude-123")
    }

    @Test func titlebarControlBridgeProvidesOnlyTheAppKitMinimumWidth() {
        let view = AlignedTerminalTitlebarControlsView(
            minimumWidth: TerminalTitlebarMetrics.inspectorCollapsedWidth,
            rootView: EmptyView()
        )
        #expect(
            view.intrinsicContentSize.width ==
                TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        #expect(
            view.intrinsicContentSize.height ==
                TerminalTitlebarMetrics.minimumHeight
        )

        view.setTitlebarWidth(300)
        #expect(view.titlebarWidth == 300)
        #expect(view.intrinsicContentSize.width == 300)
        #expect(view.frame.width == 300)
    }

    @Test func stableSessionIDIsInjectedIntoNewPTYConfiguration() {
        let sessionID = UUID()
        var base = Ghostty.SurfaceConfiguration()
        base.environmentVariables["EXISTING"] = "value"

        let configured = TerminalController.injectingSessionID(sessionID, into: base)

        #expect(configured.environmentVariables["OH_MY_GHOSTTY_SESSION"] == sessionID.uuidString)
        #expect(configured.environmentVariables["OH_MY_GHOSTTY_CHANNEL"] ==
            (OMGApplicationEnvironment.isDevelopment ? "debug" : "release"))
        #expect(configured.environmentVariables["EXISTING"] == "value")
    }

    @Test func sshNewTabUsesPreConnectionLocalDirectory() throws {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/remote/project"
            ),
            currentWorkingDirectory: "/remote/project",
            currentTerminalTitle: "remote"
        )
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/remote/project"

        let configured = try #require(TerminalController.tabConfiguration(
            inherited: inherited,
            session: session,
            fallbackWorkingDirectory: "/Users/test"
        ))
        #expect(configured.workingDirectory == "/Users/test/code")
    }

    @Test func sshNewTabRespectsDisabledDirectoryInheritance() {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/remote/project"
            ),
            currentWorkingDirectory: "/remote/project",
            currentTerminalTitle: "remote"
        )
        let inherited = Ghostty.SurfaceConfiguration()

        let configured = TerminalController.tabConfiguration(
            inherited: inherited,
            session: session,
            fallbackWorkingDirectory: "/Users/test"
        )
        #expect(configured?.workingDirectory == nil)
    }

    @Test func sshNewTabFallsBackToLocalHomeWhenSnapshotIsUnavailable() throws {
        var session = PaneSessionContext(
            workingDirectory: nil,
            terminalTitle: "Terminal"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/remote/project"
            ),
            currentWorkingDirectory: nil,
            currentTerminalTitle: "remote"
        )
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/remote/project"

        let configured = try #require(TerminalController.tabConfiguration(
            inherited: inherited,
            session: session,
            fallbackWorkingDirectory: "/Users/test"
        ))
        #expect(configured.workingDirectory == "/Users/test")

        let split = try #require(TerminalController.splitConfiguration(
            inherited: inherited,
            session: session,
            replay: nil,
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg",
            fallbackWorkingDirectory: "/Users/test"
        ))
        #expect(split.workingDirectory == "/Users/test")
        #expect(split.command == nil)
    }

    @Test func sshSplitReplaysExactLaunchInsteadOfInheritedRemotePath() throws {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/remote/project"
            ),
            currentWorkingDirectory: "/remote/project",
            currentTerminalTitle: "remote"
        )
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/remote/project"
        inherited.environmentVariables["KEEP"] = "value"
        let replay = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: true,
            terminfo: true,
            cache: true,
            args: ["-J", "jump", "cloud"]
        )

        let configured = try #require(TerminalController.splitConfiguration(
            inherited: inherited,
            session: session,
            replay: replay,
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(configured.workingDirectory == "/Users/test/code")
        #expect(configured.environmentVariables["KEEP"] == "value")
        #expect(configured.command?.contains("'+ssh'") == true)
        #expect(configured.command?.contains(
            "'--remote-working-directory=/remote/project'"
        ) == true)
        #expect(configured.command?.contains("'-J' 'jump' 'cloud'") == true)
        // SSH splits must survive a remote disconnect: the replay command runs
        // first, then an interactive login shell is exec'd so the pane returns
        // to a usable shell instead of dying with the connection.
        #expect(configured.command?.contains("; exec ") == true)
        let execIndex = configured.command?.range(of: "; exec ")?.lowerBound
        let sshIndex = configured.command?.range(of: "'+ssh'")?.lowerBound
        if let execIndex, let sshIndex {
            #expect(sshIndex < execIndex)
        }
    }

    @Test func sshSplitWithoutReplayFallsBackToSafeLocalShell() throws {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-missing",
                metadata: "type=remote;targethost=cloud"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-missing",
                metadata: "type=remote;targethost=cloud;cwd=/remote/project"
            ),
            currentWorkingDirectory: "/remote/project",
            currentTerminalTitle: "remote"
        )
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/remote/project"
        inherited.command = "unsafe inherited command"

        let configured = try #require(TerminalController.splitConfiguration(
            inherited: inherited,
            session: session,
            replay: nil,
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(configured.workingDirectory == "/Users/test/code")
        #expect(configured.command == nil)
    }

    @Test func visualStatesIncreaseFromNormalToHoverToActive() {
        let normal = GhosttyTabStyle.backgroundOpacity(selected: false, hovered: false)
        let hover = GhosttyTabStyle.backgroundOpacity(selected: false, hovered: true)
        let active = GhosttyTabStyle.backgroundOpacity(selected: true, hovered: false)
        let activeAndHover = GhosttyTabStyle.backgroundOpacity(selected: true, hovered: true)

        #expect(normal < hover)
        #expect(hover < active)
        #expect(activeAndHover == active)
    }

    @Test @MainActor func nativeDragPersistsOnlyOnMouseUp() throws {
        var updates: [(CGFloat, Bool)] = []
        let view = VerticalTabResizeInteraction.DragView(
            currentWidth: { 240 },
            resize: { updates.append(($0, $1)) }
        )
        let down = try #require(mouseEvent(type: .leftMouseDown, x: 100))
        let dragged = try #require(mouseEvent(type: .leftMouseDragged, x: 160))
        let up = try #require(mouseEvent(type: .leftMouseUp, x: 160))

        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)

        #expect(updates.count == 2)
        #expect(updates[0].0 == 300)
        #expect(updates[0].1 == false)
        #expect(updates[1].0 == 300)
        #expect(updates[1].1 == true)
    }

    @Test @MainActor func sharedTrailingDividerUsesTheSameResizeContract() throws {
        var updates: [(CGFloat, Bool)] = []
        let view = SidebarResizeInteraction.DragView(
            currentWidth: { 240 },
            resize: { updates.append(($0, $1)) },
            direction: .trailing
        )
        view.setFrameSize(NSSize(width: 8, height: 320))
        view.resetCursorRects()
        #expect(view.registeredCursorBounds == NSRect(x: 0, y: 0, width: 8, height: 320))
        view.setFrameSize(NSSize(width: 8, height: 400))
        view.resetCursorRects()
        #expect(view.registeredCursorBounds == NSRect(x: 0, y: 0, width: 8, height: 400))

        let down = try #require(mouseEvent(type: .leftMouseDown, x: 100))
        let dragged = try #require(mouseEvent(type: .leftMouseDragged, x: 160))
        let up = try #require(mouseEvent(type: .leftMouseUp, x: 160))

        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)

        #expect(updates.count == 2)
        #expect(updates[0].0 == 180)
        #expect(updates[0].1 == false)
        #expect(updates[1].0 == 180)
        #expect(updates[1].1 == true)
    }

    @Test @MainActor func resizePersistsOnlyTheFinalWidth() async throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        settings.defaultSidebarWidth = 240
        settings.rememberSidebarWidth = true
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: true,
            sidebarWidth: 240,
            settings: settings
        )
        for width in stride(from: CGFloat(200), through: 350, by: 1) {
            state.updateSidebarWidth(width, availableWidth: 1_000, persist: false)
        }
        #expect(settings.defaultSidebarWidth == 240)
        #expect(state.committedSidebarWidth == 240)
        state.updateSidebarWidth(317, availableWidth: 1_000, persist: true)
        #expect(settings.defaultSidebarWidth == 240)
        #expect(state.sidebarWidth == 317)
        #expect(state.committedSidebarWidth == 317)
        try await Task.sleep(for: .milliseconds(250))
        #expect(settings.defaultSidebarWidth == 317)
    }

    @Test @MainActor func subsequentDragCancelsPendingWidthPersistence() async throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        settings.defaultSidebarWidth = 240
        settings.rememberSidebarWidth = true
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: true,
            sidebarWidth: 240,
            settings: settings
        )

        state.updateSidebarWidth(317, availableWidth: 1_000, persist: true)
        state.updateSidebarWidth(330, availableWidth: 1_000, persist: false)
        try await Task.sleep(for: .milliseconds(250))

        #expect(settings.defaultSidebarWidth == 240)
        #expect(state.sidebarWidth == 330)
        #expect(state.committedSidebarWidth == 317)
    }

    @Test @MainActor func resizeUpdatesAreCoalescedToDisplayRate() async throws {
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true, sidebarWidth: 240)
        for step in 0..<300 {
            state.updateSidebarWidth(
                CGFloat(180 + (step % 171)),
                availableWidth: 1_000,
                persist: false
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(state.sidebarWidth == 308)
        #expect(state.appliedResizeCount <= 2)
    }

    @Test @MainActor func persistedWidthIsClampedAndRestored() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        settings.defaultSidebarWidth = 100
        #expect(settings.defaultSidebarWidth == Double(VerticalTabSidebarMetrics.minimumWidth))
        settings.defaultSidebarWidth = 1_000
        #expect(settings.defaultSidebarWidth == Double(VerticalTabSidebarMetrics.maximumWidth))
        settings.defaultSidebarWidth = 333

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.defaultSidebarWidth == 333)
    }

    @Test @MainActor func organizationModesPersistAtWindowLayoutLevel() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true, settings: settings)
        state.setGroupingMode(.project)
        state.setOrderingMode(.recentlyUsed)
        state.toggleGroup("project:test")

        let restoredSettings = OhMyGhosttySettings(fileURL: url)
        let restored = VerticalTabWindowLayoutState(
            isSidebarVisible: true,
            settings: restoredSettings
        )
        #expect(restored.groupingMode == .project)
        #expect(restored.orderingMode == .recentlyUsed)
        #expect(restored.collapsedGroupIDs.isEmpty)
    }

    @Test func tabMetadataProviderCanContributeProjectIdentity() {
        struct MockMetadataProvider: GhosttyTabMetadataProviding {
            func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
                .init(
                    project: .init(
                        id: "project:mock",
                        title: "Mock Project",
                        icon: .systemSymbol("folder.fill")
                    ),
                    agent: nil,
                    workspace: nil,
                    customGroup: nil
                )
            }
        }
        let provider = AnyGhosttyTabMetadataProvider(MockMetadataProvider())
        let metadata = provider.metadata(for: .init(
            tabID: UUID(),
            title: "Terminal",
            workingDirectory: "/tmp"
        ))

        #expect(metadata?.project?.id == "project:mock")
        #expect(metadata?.project?.title == "Mock Project")
    }

    @Test func activityIconOverridesTheTerminalFallback() {
        let activity = TabActivity(
            source: "mock",
            state: .working,
            label: nil,
            message: nil,
            detail: nil,
            progress: nil,
            icon: .init(kind: .systemSymbol, name: "bolt.fill")
        )
        let context = GhosttyTabIconContext(
            tabID: UUID(),
            title: "agent",
            activity: activity
        )
        guard case .systemSymbol(let name) = DefaultGhosttyTabIconProvider().icon(for: context) else {
            Issue.record("Expected activity system symbol")
            return
        }
        #expect(name == "bolt.fill")
    }

    @Test func sessionIconReplacesTerminalIconInTheSameSlot() {
        let context = GhosttyTabIconContext(
            tabID: UUID(),
            title: "cloud /tmp",
            activity: nil,
            defaultIcon: .systemSymbol("cloud")
        )
        guard case .systemSymbol(let name) = DefaultGhosttyTabIconProvider()
            .icon(for: context) else {
            Issue.record("Expected the canonical session icon")
            return
        }
        #expect(name == "cloud")
    }

    @Test func customIconProviderOverridesTheDefaultIcon() {
        struct MockIconProvider: GhosttyTabIconProviding {
            func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
                context.title == "agent" ? .systemSymbol("bolt.fill") : nil
            }
        }

        let provider = CompositeGhosttyTabIconProvider(overrides: [
            AnyGhosttyTabIconProvider(MockIconProvider()),
        ])
        let context = GhosttyTabIconContext(
            tabID: UUID(),
            title: "agent",
            activity: nil
        )
        guard case .systemSymbol(let name) = provider.icon(for: context) else {
            Issue.record("Expected custom system symbol")
            return
        }
        #expect(name == "bolt.fill")
    }

    @MainActor
    private func temporarySettings() -> (OhMyGhosttySettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        return (OhMyGhosttySettings(fileURL: url), url)
    }

    private func mouseEvent(type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: 0),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    @Test func explicitTitleWins() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: "quant-research",
            terminalTitle: "shell",
            workingDirectory: "/code/project",
            isGitRoot: { _ in false }
        ) == "quant-research")
    }

    @Test func gitRootWinsOverWorkingDirectoryBasename() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: nil,
            terminalTitle: "shell",
            workingDirectory: "/code/oh-my-ghostty/macos/Sources",
            isGitRoot: { $0 == "/code/oh-my-ghostty" }
        ) == "oh-my-ghostty")
    }

    @Test func workingDirectoryBasenameWinsOverTerminalTitle() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: nil,
            terminalTitle: "zsh",
            workingDirectory: "/code/project-a",
            isGitRoot: { _ in false }
        ) == "project-a")
    }

    @Test func terminalPathUsesBasenameAsFallback() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: " ",
            terminalTitle: "/code/project-b",
            workingDirectory: nil,
            isGitRoot: { _ in false }
        ) == "project-b")
    }
}
