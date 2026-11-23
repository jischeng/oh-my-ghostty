import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceLaunchTests {
    @Test(.tags(.interactiveDesktop))
    func coldTabGroupDisplaysItsSavedSelectionOnTheWindowServer() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        try await activateTestHost()

        let first = try fixture.tab()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        for _ in 0..<2 {
            let member = TerminalController(fixture.app, withBaseConfig: config, tabLayout: .vertical,
                workspaceID: first.workspaceID, windowSessionID: first.windowSessionID,
                workspaceGroupID: first.workspaceGroupID, workspaceCoordinator: fixture.coordinator)
            fixture.controllers.append(member)
            _ = try #require(member.window)
        }
        let members = fixture.controllers
        let selected = members[1]
        let window = try #require(selected.window)
        try #require(members.allSatisfy { $0.window?.isVisible == false })
        let panes = members.flatMap { $0.surfaceTree.map(\.id) }
        let groups = [TerminalWorkspaceNativeAdapter.Group(members: members, selected: selected,
            tabLayout: .vertical, visible: true, layout: selected.tabLayoutState)]
        let transaction = TerminalWorkspacePresentationTransaction(members, initialPresentation: true)
        let applied = fixture.coordinator.native.apply(groups, previous: [], focus: selected)
        transaction.publish { fixture.coordinator.native.publish(groups) }
        try #require(applied)

        for _ in 0..<100 {
            if isOnWindowServer(window) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.tabGroup?.windows == members.compactMap(\.window))
        #expect(window.tabGroup?.selectedWindow === window)
        #expect(window.isVisible)
        #expect(isOnWindowServer(window))
        #expect(members.flatMap { $0.surfaceTree.map(\.id) } == panes)

        // Selecting a sibling and returning must preserve the same native group.
        let sibling = try #require(members[2].window)
        sibling.makeKeyAndOrderFront(nil)
        await Task.yield()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if isOnWindowServer(window) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.tabGroup?.windows == members.compactMap(\.window))
        #expect(isOnWindowServer(window))
    }

    @Test func checkpointCapturesForegroundChangesWithoutChangingTheWorkspaceGraph() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab()
        second.showWindow(nil)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: first.window)
        fixture.sessions.flush()
        let url = fixture.directory.appendingPathComponent("state.json")
        let firstSnapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                    from: Data(contentsOf: url))
        #expect(firstSnapshot.foregroundTab == first.tabSessionID)
        let catalog = fixture.store.snapshot
        let writes = fixture.sessions.writeCount

        fixture.sessions.capture(foreground: second.window)
        fixture.sessions.flush()

        let secondSnapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                     from: Data(contentsOf: url))
        #expect(secondSnapshot.foregroundTab == second.tabSessionID)
        #expect(fixture.store.snapshot == catalog)
        #expect(fixture.sessions.writeCount == writes + 1)
    }

    @Test(arguments: [false, true])
    func checkpointLaunchRestoresForegroundSelectionWithoutAppKitWindowCallbacks(legacy: Bool) async throws {
        try await exerciseCheckpointLaunch(legacy: legacy)
    }

    @Test(.tags(.interactiveDesktop))
    func checkpointLaunchPresentsBothWindowGroupsOnTheWindowServer() async throws {
        try await activateTestHost()
        // Saving/closing the source fixture is test setup, not an actual app
        // quit. Keep a host window so that teardown cannot deactivate the app.
        let host = NSWindow(contentRect: .init(x: 40, y: 40, width: 120, height: 80),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        defer { host.close() }
        try await exerciseCheckpointLaunch(legacy: false, verifyWindowServer: true)
    }

    private func activateTestHost() async throws {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: "/tmp/omg-cold-tab-test.pid", atomically: true, encoding: .utf8
        )
        for _ in 0..<600 {
            if NSApp.isActive { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive, "Requires an unlocked foreground desktop")
    }

    private func isOnWindowServer(_ target: NSWindow) -> Bool {
        let records = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return records.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier &&
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == target.windowNumber
        }
    }

    private func exerciseCheckpointLaunch(legacy: Bool, verifyWindowServer: Bool = false) async throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let selected = try fixture.tab(parent: first)
        selected.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(selected)
        let other = try fixture.tab()
        other.showWindow(nil)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: selected.window)
        fixture.sessions.flush()
        let selectedID = selected.tabSessionID
        let firstID = first.tabSessionID
        let otherID = other.tabSessionID
        let panes = Set(fixture.controllers.flatMap { $0.surfaceTree.map(\.id) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("state.json"), to: checkpoint)
        if legacy {
            var snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                   from: Data(contentsOf: checkpoint))
            snapshot.foregroundTab = nil
            try JSONEncoder().encode(snapshot).write(to: checkpoint)
        }
        fixture.close()

        let store = TerminalWorkspaceStore(fileURL: nil)
        var restoredCoordinator: TerminalWorkspaceCoordinator?
        var completed = 0
        let selection = TerminalTabSelectionRestoration(finishRestoring: {
            completed += 1
            restoredCoordinator?.finishRestoring()
        })
        if legacy {
            let archive = TerminalTabSelectionRestoration(captureSnapshot: {
                .init(groups: [], foreground: selectedID)
            })
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            archive.encode(into: coder)
            coder.finishEncoding()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
            selection.decode(from: decoder)
            decoder.finishDecoding()
        }
        let sessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: store,
                                                    selectionRestoration: selection)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        restoredCoordinator = coordinator
        defer { restoredCoordinator = nil }
        sessions.prepare()
        sessions.start(fixture.app)
        let restored = coordinator.liveControllers
        defer {
            sessions.prepareToQuit()
            coordinator.commitTermination()
            coordinator.closeBackgroundTabsForTermination()
            for controller in restored { controller.window?.close() }
            sessions.flush()
        }
        let target = try #require(restored.first { $0.tabSessionID == selectedID })
        let targetWindow = try #require(target.window)
        let group = try #require(targetWindow.tabGroup)
        let firstWindow = try #require(restored.first { $0.tabSessionID == firstID }?.window)
        let otherWindow = try #require(restored.first { $0.tabSessionID == otherID }?.window)
        if verifyWindowServer {
            #expect(group.selectedWindow === targetWindow)
            if NSApp.isActive { #expect(targetWindow.isKeyWindow) }
        } else {
            TerminalWorkspacePresentation.begin()
            group.selectedWindow = firstWindow
            otherWindow.makeKeyAndOrderFront(nil)
            TerminalWorkspacePresentation.end()
        }

        // The checkpoint's controllers never entered registerRestored through
        // AppKit. A later system selection snapshot must not displace them.
        let stale = TerminalTabSelectionRestoration(captureSnapshot: {
            .init(groups: [.init(members: [firstID, selectedID], selected: firstID)], foreground: otherID)
        })
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        stale.encode(into: coder)
        coder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        selection.decode(from: decoder)
        decoder.finishDecoding()
        selection.finishLaunching()
        for _ in 0..<100 {
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(completed == 1)
        #expect(group.selectedWindow === targetWindow)
        #expect(targetWindow.isVisible)
        #expect(target.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(target))
        #expect(Set(target.tabLayoutState.tabSnapshot.controllers.map(\.tabSessionID)) == [firstID, selectedID])
        #expect(Set(restored.flatMap { $0.surfaceTree.map(\.id) }) == panes)
        #expect(store.group(window: target.windowSessionID, workspace: target.workspaceID)?.selected == selectedID)
        for _ in 0..<100 {
            if let host = target.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView,
               host.window === targetWindow,
               host.sidebar.list.nodes.values.filter({ $0.tab != nil }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let host = try #require(target.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView)
        #expect(host.window === targetWindow)
        #expect(host.sidebar.configuration.controller === target)
        #expect(host.sidebar.configuration.layoutState === target.tabLayoutState)
        #expect(Set(host.sidebar.list.nodes.values.compactMap { $0.tab?.controller.tabSessionID }) ==
                [firstID, selectedID])
        if verifyWindowServer {
            for _ in 0..<100 {
                if isOnWindowServer(targetWindow), isOnWindowServer(otherWindow) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(isOnWindowServer(targetWindow))
            #expect(isOnWindowServer(otherWindow))
        }
    }

    @Test func nativeSelectionOfAParkedTabActivatesItsWorkspaceAndExactTab() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let target = try fixture.tab(parent: first)
        fixture.coordinator.didActivate(first)
        let other = try #require(fixture.store.create(name: "Other", symbol: "house", color: "blue"))
        let outgoing = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(outgoing)
        let targetWindow = try #require(target.window)
        let group = try #require(targetWindow.tabGroup)
        let surfaces = fixture.controllers.map { Array($0.surfaceTree).map(ObjectIdentifier.init) }

        TerminalWorkspacePresentation.begin()
        group.selectedWindow = targetWindow
        TerminalWorkspacePresentation.end()
        try #require(target.workspacePresentationIsParked)
        for _ in 0..<100 {
            if !target.workspacePresentationIsParked { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!target.workspacePresentationIsParked)
        #expect(outgoing.workspacePresentationIsParked)
        #expect(group.selectedWindow === targetWindow)
        #expect(fixture.store.snapshot.windows?[target.windowSessionID]?.currentWorkspace == target.workspaceID)
        #expect(fixture.store.group(window: target.windowSessionID, workspace: target.workspaceID)?.selected == target.tabSessionID)
        #expect(target.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(target))
        #expect(target.tabLayoutState.tabSnapshot.controllers.map(\.tabSessionID) == [first.tabSessionID, target.tabSessionID])
        #expect(fixture.controllers.map { Array($0.surfaceTree).map(ObjectIdentifier.init) } == surfaces)
    }

    @Test func dockReopenDoesNotTreatAParkedNativeTabAsAVisibleWorkspace() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let other = try #require(fixture.store.create(name: "Other", symbol: "house", color: "blue"))
        let current = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(current)
        let currentWindow = try #require(current.window)
        let parkedWindow = try #require(first.window)
        let group = try #require(currentWindow.tabGroup)
        try #require(group.windows.contains(parkedWindow))
        let tabIDs = Set(fixture.coordinator.liveControllers.map(\.tabSessionID))

        // AppKit's Window/Dock menu can select a retained parked tab while the
        // committed workspace and its sidebar still belong to the current tab.
        TerminalWorkspacePresentation.begin()
        group.selectedWindow = parkedWindow
        TerminalWorkspacePresentation.end()
        try #require(parkedWindow.isVisible)
        try #require(first.workspacePresentationIsParked)

        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let useAppKitDefault = delegate.handleReopen(hasVisibleWindows: true, coordinator: fixture.coordinator)

        #expect(!useAppKitDefault)
        #expect(group.selectedWindow === currentWindow)
        #expect(currentWindow.isVisible)
        #expect(!current.workspacePresentationIsParked)
        #expect(first.workspacePresentationIsParked)
        #expect(Set(fixture.coordinator.liveControllers.map(\.tabSessionID)) == tabIDs)
        #expect(fixture.store.snapshot.windows?[current.windowSessionID]?.currentWorkspace == other)
    }

    @Test func checkpointPresentationWaitsForApplicationActivation() {
        let gate = TerminalWorkspaceLaunchGate()
        var starts = 0
        gate.request(isActive: false) { starts += 1 }
        #expect(starts == 0)
        gate.activate()
        #expect(starts == 1)
        gate.activate()
        #expect(starts == 1)

        gate.request(isActive: true) { starts += 1 }
        #expect(starts == 2)
        gate.activate()
        #expect(starts == 2)
    }

    @Test func dockReopenKeepsAppKitBehaviorForAHealthyVisibleWorkspace() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let selected = try fixture.tab()
        selected.showWindow(nil)
        fixture.coordinator.didActivate(selected)
        let catalog = fixture.store.snapshot
        let revision = fixture.coordinator.revision
        var presentations = 0
        let show = fixture.coordinator.native.show
        fixture.coordinator.native.show = { controller in
            presentations += 1
            return show(controller)
        }
        let delegate = try #require(NSApp.delegate as? AppDelegate)

        #expect(delegate.handleReopen(hasVisibleWindows: true, coordinator: fixture.coordinator))
        #expect(presentations == 0)
        #expect(fixture.coordinator.revision == revision)
        #expect(fixture.store.snapshot == catalog)
        #expect(selected.window?.isVisible == true)
    }

    @Test func finishingCheckpointRestoreKeepsParkedMembersInTheirRetainedGroup() throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        _ = try fixture.tab(parent: first)
        fixture.coordinator.didActivate(first)
        let other = try #require(fixture.store.create(name: "Parked", symbol: "house", color: "blue"))
        let parked = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(parked)
        _ = try fixture.tab(workspace: other, parent: parked)
        try #require(fixture.coordinator.switchWorkspace(to: first.workspaceID, from: parked) === first)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture()
        fixture.sessions.flush()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("state.json"), to: checkpoint)
        let selectedID = first.tabSessionID
        let expectedIDs = Set(fixture.controllers.map(\.tabSessionID))
        fixture.close()

        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: store)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        sessions.prepare()
        try #require(sessions.ownsRestoration)
        sessions.start(fixture.app)
        let restored = coordinator.liveControllers
        defer {
            sessions.prepareToQuit()
            coordinator.commitTermination()
            coordinator.closeBackgroundTabsForTermination()
            for controller in restored { controller.window?.close() }
            sessions.flush()
        }
        let selected = try #require(restored.first { $0.tabSessionID == selectedID })
        let window = try #require(selected.window)
        let group = try #require(window.tabGroup)
        try #require(Set(restored.map(\.tabSessionID)) == expectedIDs)
        try #require(group.windows.count == 4)
        try #require(coordinator.usesRetainedNativeTabs(in: selected.windowSessionID))
        let membership = Set(group.windows.map(ObjectIdentifier.init))

        coordinator.finishRestoring()

        #expect(Set(group.windows.map(ObjectIdentifier.init)) == membership)
        #expect(group.selectedWindow === window)
        #expect(window.isVisible)
        #expect(store.snapshot.windows?[selected.windowSessionID]?.currentWorkspace == selected.workspaceID)
        #expect(restored.filter { $0.workspaceID == other }.allSatisfy { $0.workspacePresentationIsParked })
    }

    @Test func reopeningHiddenWindowsKeepsTheCurrentWorkspace() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(fixture.app, withBaseConfig: config,
                                       tabLayout: .horizontal, workspaceCoordinator: fixture.coordinator)
        fixture.controllers.append(first)
        first.showWindow(nil)
        let other = try #require(fixture.store.create(name: "Current", symbol: "house", color: "blue"))
        let current = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(current)
        try #require(current.window?.isVisible == true)
        try #require(first.workspacePresentationIsParked)
        current.window?.orderOut(nil)
        try #require(!fixture.coordinator.liveControllers.contains { $0.window?.isVisible == true })

        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(!delegate.handleReopen(hasVisibleWindows: false, coordinator: fixture.coordinator))

        #expect(fixture.store.snapshot.windows?[first.windowSessionID]?.currentWorkspace == other)
        #expect(current.window?.isVisible == true)
        #expect(first.workspacePresentationIsParked)
    }

    @Test func launchWithoutAppKitSnapshotFinishesTheInjectedRestorationOwner() {
        var completions = 0
        let restoration = TerminalTabSelectionRestoration(
            captureSnapshot: { .init(groups: [], foreground: nil) },
            finishRestoring: { completions += 1 }
        )
        restoration.finishLaunching()
        #expect(completions == 1)
    }

    @Test func workspacePresentationPreservesItsPreparedWindowFrame() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let window = try #require(controller.window)
        let screen = try #require(window.screen ?? NSScreen.main).visibleFrame
        var frame = NSRect(x: screen.minX + 31, y: screen.minY + 47,
                           width: min(641, screen.width * 0.7), height: min(433, screen.height * 0.7))
        if let stored = UserDefaults.ghostty.array(forKey: "NSWindowLastPosition") as? [Double],
           stored.count >= 4, stored[2] == frame.width {
            frame.size.width -= 17
        }
        window.setFrame(frame, display: false)
        let expected = window.frame
        let transaction = TerminalWorkspacePresentationTransaction([controller])
        controller.showWindow(nil)
        transaction.publish {}
        #expect(window.frame == expected)
    }

    @Test func coldRestoreMultiWorkspaceVerticalWithNonFirstSelectionUnifiesGroupAndSidebars() async throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let personal = fixture.store.defaultID
        let p0 = try fixture.tab()
        p0.showWindow(nil)
        let p1 = try fixture.tab(parent: p0)
        let p2 = try fixture.tab(parent: p1)
        p1.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(p1)

        let work = try #require(fixture.store.create(name: "work", symbol: "briefcase", color: "blue"))
        let w0 = try #require(fixture.coordinator.switchWorkspace(to: work, from: p1))
        fixture.controllers.append(w0)
        let w1 = try fixture.tab(workspace: work, parent: w0)

        let testWorkspace = try #require(fixture.store.create(name: "test", symbol: "flask", color: "mint"))
        let t0 = try #require(fixture.coordinator.switchWorkspace(to: testWorkspace, from: w1))
        fixture.controllers.append(t0)

        try #require(fixture.coordinator.switchWorkspace(to: personal, from: t0) === p1)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: p1.window)
        fixture.sessions.flush()

        let host = p0.windowSessionID
        let personalIDs = [p0.tabSessionID, p1.tabSessionID, p2.tabSessionID]
        let selectedID = p1.tabSessionID
        let firstID = p0.tabSessionID
        let workIDs = Set([w0.tabSessionID, w1.tabSessionID])
        let testID = t0.tabSessionID

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("state.json"), to: checkpoint)
        fixture.close()

        let store = TerminalWorkspaceStore(fileURL: nil)
        var restoredCoordinator: TerminalWorkspaceCoordinator?
        var completed = 0
        let selection = TerminalTabSelectionRestoration(finishRestoring: {
            completed += 1
            restoredCoordinator?.finishRestoring()
        })
        let sessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: store,
                                                     selectionRestoration: selection)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        restoredCoordinator = coordinator
        defer { restoredCoordinator = nil }
        sessions.prepare()
        try #require(sessions.ownsRestoration)
        sessions.start(fixture.app)
        let restored = coordinator.liveControllers
        defer {
            sessions.prepareToQuit()
            coordinator.commitTermination()
            coordinator.closeBackgroundTabsForTermination()
            for controller in restored { controller.window?.close() }
            sessions.flush()
        }
        selection.finishLaunching()
        for _ in 0..<100 {
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(completed == 1)
        #expect(coordinator.usesRetainedNativeTabs(in: host))
        let expectedIdentifier = "omg.window.\(host)"
        #expect(restored.count == 6)
        #expect(restored.allSatisfy { $0.window?.tabbingIdentifier == expectedIdentifier })

        let restoredP1 = try #require(restored.first { $0.tabSessionID == selectedID })
        let restoredP0 = try #require(restored.first { $0.tabSessionID == firstID })
        let p1Window = try #require(restoredP1.window)
        let p0Window = try #require(restoredP0.window)
        let group = try #require(p1Window.tabGroup)
        #expect(restored.allSatisfy { $0.window?.tabGroup === group })
        #expect(group.windows.count == 6)
        #expect(group.selectedWindow === p1Window)
        #expect(p1Window.isVisible)
        #expect(!restoredP1.workspacePresentationIsParked)
        #expect(!restoredP0.workspacePresentationIsParked)
        #expect(restoredP1.tabControllers.map(\.tabSessionID) == personalIDs)

        let parked = restored.filter { workIDs.contains($0.tabSessionID) || $0.tabSessionID == testID }
        #expect(parked.count == 3)
        #expect(parked.allSatisfy { $0.workspacePresentationIsParked })

        for _ in 0..<100 {
            if let hostView = restoredP1.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView,
               hostView.window === p1Window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restoredP1.tabLayoutState.sidebarHost.liveView?.window === p1Window)

        // Switching to tab 1 (index 0) must move the live sidebar and keep native selection in sync.
        restoredP1.selectVerticalTab(restoredP0)
        for _ in 0..<100 {
            if group.selectedWindow === p0Window,
               restoredP0.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(restoredP0),
               restoredP0.tabLayoutState.sidebarHost.liveView?.window === p0Window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(group.selectedWindow === p0Window)
        #expect(restoredP0.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(restoredP0))
        #expect(restoredP0.tabLayoutState.sidebarHost.liveView?.window === p0Window)

        // Switching to a parked workspace must succeed and keep the unified retained group.
        let switched = try #require(coordinator.switchWorkspace(to: work, from: restoredP0))
        #expect(switched.workspaceID == work)
        #expect(!switched.workspacePresentationIsParked)
        #expect(restoredP0.workspacePresentationIsParked)
        #expect(group.selectedWindow === switched.window)
        #expect(restored.allSatisfy { $0.window?.tabGroup === group })
    }

    @Test func coldRestoreFallsBackToNonRetainedWhenRetainedAttachFails() async throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let personal = fixture.store.defaultID
        let p0 = try fixture.tab()
        p0.showWindow(nil)
        let p1 = try fixture.tab(parent: p0)
        p1.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(p1)

        let work = try #require(fixture.store.create(name: "work", symbol: "briefcase", color: "blue"))
        let w0 = try #require(fixture.coordinator.switchWorkspace(to: work, from: p1))
        fixture.controllers.append(w0)
        _ = try fixture.tab(workspace: work, parent: w0)
        try #require(fixture.coordinator.switchWorkspace(to: personal, from: w0) === p1)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: p1.window)
        fixture.sessions.flush()

        let host = p0.windowSessionID
        let selectedID = p1.tabSessionID
        let personalIDs = Set([p0.tabSessionID, p1.tabSessionID])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("state.json"), to: checkpoint)
        fixture.close()

        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: store)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        let originalAttach = coordinator.native.attach
        coordinator.native.attach = { anchor, child, ordering in
            if let controller = child.windowController as? TerminalController,
               controller.workspaceID != personal {
                return false
            }
            return originalAttach(anchor, child, ordering)
        }
        defer { coordinator.native.attach = originalAttach }

        sessions.prepare()
        sessions.start(fixture.app)
        let restored = coordinator.liveControllers
        defer {
            sessions.prepareToQuit()
            coordinator.commitTermination()
            coordinator.closeBackgroundTabsForTermination()
            for controller in restored { controller.window?.close() }
            sessions.flush()
        }

        #expect(!coordinator.usesRetainedNativeTabs(in: host))
        let restoredP1 = try #require(restored.first { $0.tabSessionID == selectedID })
        let p1Window = try #require(restoredP1.window)
        let group = try #require(p1Window.tabGroup)
        let activeControllers = restored.filter { personalIDs.contains($0.tabSessionID) }
        let parkedControllers = restored.filter { !personalIDs.contains($0.tabSessionID) }
        #expect(Set(group.windows.map(ObjectIdentifier.init)) ==
                Set(activeControllers.compactMap(\.window).map(ObjectIdentifier.init)))
        #expect(group.selectedWindow === p1Window)
        #expect(p1Window.isVisible)
        #expect(parkedControllers.allSatisfy { $0.workspacePresentationIsParked })
        #expect(parkedControllers.allSatisfy { $0.window?.isVisible == false })
        #expect(parkedControllers.allSatisfy { $0.window?.tabGroup !== group })
        #expect(restored.allSatisfy {
            $0.window?.tabbingIdentifier == "omg.window.\(host).workspace.\($0.workspaceID)"
        })
    }

    @Test func workspaceSwitchSelfHealsCrossTabGroupSplit() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let personal = fixture.store.defaultID
        let p0 = try fixture.tab()
        p0.showWindow(nil)
        let p1 = try fixture.tab(parent: p0)
        p1.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(p1)
        let work = try #require(fixture.store.create(name: "work", symbol: "briefcase", color: "blue"))
        let w0 = try #require(fixture.coordinator.switchWorkspace(to: work, from: p1))
        fixture.controllers.append(w0)
        let w1 = try fixture.tab(workspace: work, parent: w0)
        try #require(fixture.coordinator.switchWorkspace(to: personal, from: w1) === p1)

        // Simulate a split where `work` ended up in its own NSWindowTabGroup
        // with a mismatched per-workspace tabbingIdentifier.
        let host = p0.windowSessionID
        let w0Window = try #require(w0.window)
        let w1Window = try #require(w1.window)
        let p1Window = try #require(p1.window)
        let personalGroup = try #require(p1Window.tabGroup)
        TerminalWorkspacePresentation.begin()
        personalGroup.removeWindow(w0Window)
        personalGroup.removeWindow(w1Window)
        w0Window.tabbingIdentifier = "omg.window.\(host).workspace.\(work)"
        w1Window.tabbingIdentifier = "omg.window.\(host).workspace.\(work)"
        try #require(w0Window.addTabbedWindowSafely(w1Window, ordered: .above))
        TerminalWorkspacePresentation.end()
        try #require(w0Window.tabGroup !== personalGroup)
        try #require(w0Window.tabGroup === w1Window.tabGroup)

        let destination = try #require(fixture.coordinator.switchWorkspace(to: work, from: p1))
        let unifiedGroup = try #require(destination.window?.tabGroup)
        #expect(destination.workspaceID == work)
        #expect(!destination.workspacePresentationIsParked)
        #expect(p1.workspacePresentationIsParked)
        #expect(unifiedGroup.selectedWindow === destination.window)
        #expect([p0, p1, w0, w1].allSatisfy { $0.window?.tabGroup === unifiedGroup })
        #expect([p0, p1, w0, w1].allSatisfy { $0.window?.tabbingIdentifier == "omg.window.\(host)" })
    }

    @Test func emptyWindowsAndGroupsArePrunedOnRemovePrepareAndCapture() throws {
        var state = TerminalWorkspaceState()
        let work = TerminalWorkspace(id: UUID(), name: "work", symbol: "briefcase", color: "blue")
        state.workspaces.append(work)
        let hostA = UUID()
        let hostB = UUID()
        let tabA = UUID()
        let tabB = UUID()
        state.register(tabA, owner: .init(window: hostA, workspace: state.defaultID, group: UUID()))
        state.register(tabB, owner: .init(window: hostB, workspace: work.id, group: UUID()))
        #expect(state.windows?.keys.count == 2)

        state.remove(tabB)
        state.pruneEmptyWindows()
        #expect(state.windows?[hostB] == nil)
        #expect(state.windows?[hostA]?.groups[state.defaultID]?.tabs == [tabA])
        #expect(state.validationErrors.isEmpty)

        // Verify prepare() prunes stale empty windows from an existing v2 state.json.
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let live = try fixture.tab()
        live.showWindow(nil)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: live.window)
        fixture.sessions.flush()

        let stateURL = fixture.directory.appendingPathComponent("state.json")
        var snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                from: Data(contentsOf: stateURL))
        let staleHost = UUID()
        snapshot.catalog?.windows?[staleHost] = TerminalWorkspaceState.Window(
            currentWorkspace: fixture.store.defaultID,
            groups: [fixture.store.defaultID: .init(id: UUID(), tabs: [], selected: nil)]
        )
        try #require(snapshot.isComplete)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let polluted = directory.appendingPathComponent("state.json")
        try JSONEncoder().encode(snapshot).write(to: polluted)

        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: polluted, testing: true, workspaces: store)
        sessions.prepare()
        #expect(sessions.ownsRestoration)
        #expect(store.snapshot.windows?[staleHost] == nil)
        #expect(store.snapshot.windows?[live.windowSessionID] != nil)
        #expect(store.snapshot.validationErrors.isEmpty)
    }

    @Test func closeWindowImmediatelyRemovesClosedWindowsFromCheckpointAndRelaunch() async throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let keptFirst = try fixture.tab()
        keptFirst.showWindow(nil)
        let keptSecond = try fixture.tab(parent: keptFirst)
        keptSecond.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(keptSecond)

        // Single-tab window (mirrors Cmd+N -> Cmd+Shift+W).
        let singleWindow = try fixture.tab()
        singleWindow.showWindow(nil)
        let singleHost = singleWindow.windowSessionID
        let singleTabID = singleWindow.tabSessionID

        // Multi-tab window (mirrors multi-tab Cmd+Shift+W + Undo Close Window).
        let multiFirst = try fixture.tab()
        multiFirst.showWindow(nil)
        let multiSecond = try fixture.tab(parent: multiFirst)
        multiSecond.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(multiSecond)
        let multiHost = multiFirst.windowSessionID
        let multiTabIDs = Set([multiFirst.tabSessionID, multiSecond.tabSessionID])

        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: keptSecond.window)
        fixture.sessions.flush()
        let stateURL = fixture.directory.appendingPathComponent("state.json")
        let before = try JSONDecoder().decode(
            TerminalWorkspaceSessionStore.Snapshot.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(before.catalog?.windows?.count == 3)
        #expect(before.tabs.count == 5)

        // Close single-tab window via Cmd+Shift+W path.
        undoManager?.disableUndoRegistration()
        singleWindow.closeWindowImmediately()
        undoManager?.enableUndoRegistration()
        fixture.sessions.flush()
        #expect(fixture.store.snapshot.windows?[singleHost] == nil)
        #expect(fixture.store.snapshot.owner(of: singleTabID) == nil)
        let afterSingle = try JSONDecoder().decode(
            TerminalWorkspaceSessionStore.Snapshot.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(afterSingle.catalog?.windows?.count == 2)
        #expect(!afterSingle.tabs.contains { $0.id == singleTabID })

        // Close multi-tab window via Cmd+Shift+W path.
        multiSecond.closeWindowImmediately()
        fixture.sessions.flush()
        #expect(fixture.store.snapshot.windows?[multiHost] == nil)
        #expect(multiTabIDs.allSatisfy { fixture.store.snapshot.owner(of: $0) == nil })
        let afterMulti = try JSONDecoder().decode(
            TerminalWorkspaceSessionStore.Snapshot.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(afterMulti.catalog?.windows?.count == 1)
        #expect(Set(afterMulti.tabs.map(\.id)) == Set([keptFirst.tabSessionID, keptSecond.tabSessionID]))

        // Copy checkpoint before exercising Undo Close Window so we can verify cold relaunch.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: stateURL, to: checkpoint)

        // Undo Close Window must still restore both tabs of the closed multi-tab window.
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
            let restoredIDs = Set(fixture.coordinator.liveControllers.map(\.tabSessionID))
            #expect(multiTabIDs.isSubset(of: restoredIDs))
            #expect(fixture.store.snapshot.windows?[multiHost] != nil)
            for controller in fixture.coordinator.liveControllers where multiTabIDs.contains(controller.tabSessionID) {
                fixture.controllers.append(controller)
            }
        }
        fixture.close()

        // Cold relaunch from the post-close checkpoint must not resurrect closed windows.
        let relaunchStore = TerminalWorkspaceStore(fileURL: nil)
        let relaunchSessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: relaunchStore)
        let relaunchCoordinator = TerminalWorkspaceCoordinator(store: relaunchStore, sessions: relaunchSessions)
        relaunchSessions.prepare()
        relaunchSessions.start(fixture.app)
        let relaunched = relaunchCoordinator.liveControllers
        defer {
            relaunchSessions.prepareToQuit()
            relaunchCoordinator.commitTermination()
            relaunchCoordinator.closeBackgroundTabsForTermination()
            for controller in relaunched { controller.window?.close() }
            relaunchSessions.flush()
        }
        #expect(Set(relaunched.map(\.tabSessionID)) == Set([keptFirst.tabSessionID, keptSecond.tabSessionID]))
        #expect(relaunchStore.snapshot.windows?.count == 1)
    }

    @Test func closeWindowImmediatelyLeavesParkedWorkspaceTabsInCheckpoint() async throws {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let parked = try fixture.tab()
        parked.showWindow(nil)
        fixture.coordinator.didActivate(parked)
        let workID = try #require(fixture.store.create(name: "Work close", symbol: "briefcase", color: "blue"))
        let activeFirst = try #require(fixture.coordinator.switchWorkspace(to: workID, from: parked))
        fixture.controllers.append(activeFirst)
        let activeSecond = try fixture.tab(workspace: workID, parent: activeFirst)
        activeSecond.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(activeSecond)
        try await Task.sleep(for: .milliseconds(80))

        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: activeSecond.window)
        fixture.sessions.flush()

        let host = parked.windowSessionID
        let parkedID = parked.tabSessionID
        let activeIDs = Set([activeFirst.tabSessionID, activeSecond.tabSessionID])
        activeSecond.closeWindowImmediately()
        fixture.sessions.flush()
        // Drain queued tab-group KVO / appearance refresh turns after closing
        // an active multi-tab workspace while parked workspaces remain.
        try await Task.sleep(for: .milliseconds(100))

        let stateURL = fixture.directory.appendingPathComponent("state.json")
        let snapshot = try JSONDecoder().decode(
            TerminalWorkspaceSessionStore.Snapshot.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(fixture.store.snapshot.windows?[host] != nil)
        #expect(fixture.store.snapshot.owner(of: parkedID) != nil)
        #expect(activeIDs.allSatisfy { fixture.store.snapshot.owner(of: $0) == nil })
        #expect(Set(snapshot.tabs.map(\.id)) == Set([parkedID]))
        #expect(parked.isAvailableForWorkspace)
    }
}
