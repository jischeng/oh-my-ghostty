import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct QuickInputHistoryStoreTests {
    private static var retainedHostingWindows: [NSWindow] = []

    @Test func queueHistorySurvivesEditsCancellationAndPersistenceWithoutDuplicateSends() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = QuickInputHistoryStore(fileURL: file)
        let model = AgentQuickInputModel(historyStore: store)
        let pane = UUID()
        model.present(for: pane)
        model.draft = "queued text"
        let first = try #require(model.enqueueDraft())
        #expect(store.entries.first?.deliveryState == .queued)
        model.editQueuedItem(first.id, for: pane)
        model.draft = "edited queued text"
        #expect(model.confirmQueuedItemEdit(moveToEnd: false))
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.text == "edited queued text")
        model.recordSentText("edited queued text", for: pane, historyID: first.id)
        model.removeQueuedItem(first.id, for: pane)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.id == first.id)
        #expect(store.entries.first?.deliveryState == .sent)
        model.draft = "cancelled text"
        let cancelled = try #require(model.enqueueDraft())
        model.removeQueuedItem(cancelled.id, for: pane)
        #expect(store.entries.last?.deliveryState == .cancelled)
        store.flushPendingWrites()
        let restored = QuickInputHistoryStore(fileURL: file)
        #expect(restored.entries == store.entries)
        #expect(restored.visibleEntries(paneID: pane, tabID: model.historyTabID, scope: .pane).count == 2)
        model.draft = "waiting at quit"
        let pending = try #require(model.enqueueDraft())
        store.flushPendingWrites()
        let relaunched = QuickInputHistoryStore(fileURL: file)
        #expect(relaunched.entries.first(where: { $0.id == pending.id })?.deliveryState == .cancelled)
        #expect(relaunched.entries.first(where: { $0.id == pending.id })?.text == "waiting at quit")
    }

    @Test func oldSentHistoryWithoutDeliveryStateStillLoads() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let entry = QuickInputHistoryEntry(id: UUID(), paneID: UUID(), tabID: UUID(), text: "older sent message", sentAt: Date())
        let encoded = try JSONEncoder().encode(entry)
        let object = try JSONSerialization.jsonObject(with: encoded)
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [object]]).write(to: file)
        let restored = QuickInputHistoryStore(fileURL: file)
        #expect(restored.entries.first?.delivery == nil)
        #expect(restored.entries.first?.deliveryState == .sent)
    }

    private func temporaryFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("history.json")
    }

    @Test func historyPopoverAdaptsHeightAndCapsItsScrollableList() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let settings = OhMyGhosttySettings(fileURL: file)
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane)
        store.record("A short prompt", paneID: pane, tabID: tab)
        let hosting = NSHostingView(rootView: QuickInputHistoryView(
            model: model, store: store, settings: settings, onSelect: { _ in }
        ).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        Self.retainedHostingWindows.append(window)
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let compactHeight = hosting.fittingSize.height
        #expect(compactHeight < 160)
        store.record("Another short prompt", paneID: pane, tabID: tab)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let twoRowHeight = hosting.fittingSize.height
        // Two short entries must both fit, without inheriting a one-row viewport.
        #expect(twoRowHeight > compactHeight + 25)
        #expect(twoRowHeight < 140)
        for index in 0..<15 {
            store.record("Prompt \(index)\nSecond line with context\nThird line", paneID: pane, tabID: tab)
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let expandedHeight = hosting.fittingSize.height
        #expect(hosting.fittingSize.width >= QuickInputHistoryLayout.controlCapsuleWidth)
        #expect(compactHeight < expandedHeight)
        #expect(expandedHeight == QuickInputHistoryLayout.stackHeight(entryCount: 17))
        store.clear()
        store.record("Back to two rows", paneID: pane, tabID: tab)
        store.record("Another short prompt", paneID: pane, tabID: tab)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height == twoRowHeight, "The popup must shrink again after a large history.")
        // Keep an offscreen rendering for human layout review, without showing
        // a window, taking focus, or touching the installed release app.
        let previouslySelected = model.historyPresentation.selectedID
        model.historyPresentation.open(entries: store.visibleEntries(paneID: pane, tabID: tab, scope: .tab))
        #expect(model.historyPresentation.selectedID == previouslySelected)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/omg-quick-input-history-preview.png"))
    }

    @Test func scopesSearchDatesAndPaneMoveRemainIndependent() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(now: { timestamp })
        let pane = UUID()
        let sibling = UUID()
        let other = UUID()
        let tab = UUID()
        let otherTab = UUID()
        store.record("First prompt\n你好", paneID: pane, tabID: tab)
        store.record("Second Prompt", paneID: sibling, tabID: tab)
        store.record("Remote prompt", paneID: other, tabID: otherTab)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .pane).map(\.text) == ["First prompt\n你好"])
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .tab).count == 2)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .global).count == 3)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .tab, query: "second").first?.paneID == sibling)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .global, query: " 你好 ").first?.sentAt == timestamp)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .global, query: "missing").isEmpty)
        store.bind(paneIDs: [pane], to: otherTab)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .pane).count == 1)
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .tab).map(\.text) == ["Second Prompt"])
        #expect(store.visibleEntries(paneID: other, tabID: otherTab, scope: .tab).count == 2)
    }

    @Test func persistenceRestoresFullTextDatesOwnershipAndPrivatePermissions() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pane = UUID()
        let tab = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(fileURL: file, now: { timestamp })
        let text = "line 1\nline 2 🐱\n" + String(repeating: "long prompt ", count: 1_000)
        store.record(text, paneID: pane, tabID: tab)
        store.flushPendingWrites()
        let restored = QuickInputHistoryStore(fileURL: file, now: { timestamp })
        restored.flushPendingWrites()
        #expect(restored.entries == store.entries)
        #expect(restored.visibleEntries(paneID: pane, tabID: tab, scope: .pane).first?.text == text)
        #expect(restored.visibleEntries(paneID: UUID(), tabID: UUID(), scope: .pane).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func expiryAppliesDuringSessionAndAfterRestart() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(fileURL: file, now: { timestamp })
        let pane = UUID()
        let tab = UUID()
        store.record("old", paneID: pane, tabID: tab)
        timestamp = timestamp.addingTimeInterval(6 * 86_400)
        store.record("recent", paneID: pane, tabID: tab)
        timestamp = timestamp.addingTimeInterval(86_400)
        // Exact expiry boundary is excluded even before the cleanup timer fires.
        #expect(store.visibleEntries(paneID: pane, tabID: tab, scope: .pane).map(\.text) == ["recent"])
        store.flushPendingWrites()
        let restored = QuickInputHistoryStore(fileURL: file, now: { timestamp })
        restored.flushPendingWrites()
        #expect(restored.entries.map(\.text) == ["recent"])
        store.pruneExpired()
        store.flushPendingWrites()
        #expect(store.entries.map(\.text) == ["recent"])
        store.configure(retentionDays: 1, keepsAfterQuit: true)
        store.flushPendingWrites()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func turningOffPersistenceDeletesDiskButKeepsSessionAndClearRemovesBoth() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = QuickInputHistoryStore(fileURL: file)
        let pane = UUID()
        let tab = UUID()
        store.record("keep in session", paneID: pane, tabID: tab)
        store.configure(retentionDays: 7, keepsAfterQuit: false)
        store.flushPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.entries.count == 1)
        let restarted = QuickInputHistoryStore(fileURL: file, keepsAfterQuit: false)
        restarted.flushPendingWrites()
        #expect(restarted.entries.isEmpty)
        store.configure(retentionDays: 7, keepsAfterQuit: true)
        store.flushPendingWrites()
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.clear()
        store.flushPendingWrites()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func disabledPersistenceOnLaunchRemovesPreviouslySavedCopy() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = QuickInputHistoryStore(fileURL: file)
        store.record("private", paneID: UUID(), tabID: UUID())
        store.flushPendingWrites()
        let restarted = QuickInputHistoryStore(fileURL: file, keepsAfterQuit: false)
        restarted.flushPendingWrites()
        #expect(restarted.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func repeatedSendsRefreshDateAndHistoryIsBounded() {
        var timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(now: { timestamp })
        let pane = UUID()
        let tab = UUID()
        store.record("same", paneID: pane, tabID: tab)
        timestamp = timestamp.addingTimeInterval(1)
        store.record("same", paneID: pane, tabID: tab)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.sentAt == timestamp)
        for index in 0..<60 { store.record("message \(index)", paneID: pane, tabID: tab) }
        #expect(store.entries.count == QuickInputHistoryStore.perPaneLimit)
        #expect(store.entries.first?.text == "message 10")
        store.record(String(repeating: "a", count: QuickInputHistoryStore.maximumEntryBytes + 1), paneID: pane, tabID: tab)
        #expect(store.entries.last?.text == "message 59")
        for _ in 0..<1_010 { store.record("other pane", paneID: UUID(), tabID: tab) }
        #expect(store.entries.count == QuickInputHistoryStore.totalLimit)
    }

    @Test func corruptedArchiveDoesNotCrashOrOverwriteFileAndSymlinksAreRejected() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let invalid = Data("not JSON".utf8)
        try invalid.write(to: file)
        let store = QuickInputHistoryStore(fileURL: file)
        store.flushPendingWrites()
        #expect(store.entries.isEmpty)
        #expect(store.storageError != nil)
        #expect(try Data(contentsOf: file) == invalid)
        let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linked = QuickInputHistoryStore(fileURL: link)
        linked.flushPendingWrites()
        #expect(linked.entries.isEmpty)
        #expect(linked.storageError != nil)
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test func directorySharingCombinesOrthogonallyWithPaneAndTabAndRetainsPaneHistoryAcrossCd() {
        var timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(now: { timestamp })
        let paneA = UUID()
        let paneB = UUID()
        let paneSibling = UUID()
        let tab1 = UUID()
        let tab2 = UUID()
        let dirA = QuickInputHistoryLocation(workingDirectory: "/tmp/omg-dir-a/")!
        let dirB = QuickInputHistoryLocation(workingDirectory: "/tmp/omg-dir-b")!

        // paneA writes in dirA (tab1), sibling writes in dirOther (tab1), paneB writes in dirB (tab2)
        store.record("paneA in A", paneID: paneA, tabID: tab1, location: dirA)
        timestamp = timestamp.addingTimeInterval(1)
        store.record("sibling in tab1", paneID: paneSibling, tabID: tab1, location: QuickInputHistoryLocation(workingDirectory: "/tmp/omg-other"))
        timestamp = timestamp.addingTimeInterval(1)
        store.record("paneB in B", paneID: paneB, tabID: tab2, location: dirB)

        // paneA cds to dirB:
        // - With pane + dir sharing: paneA sees both its own dirA entry AND dirB's shared entry (paneB), newest first
        #expect(
            store.visibleEntries(paneID: paneA, tabID: tab1, scope: .pane, location: dirB, shareByDirectory: true).map(\.text)
                == ["paneB in B", "paneA in A"]
        )
        // - With tab + dir sharing: paneA sees tab1's entries AND dirB's shared entry
        #expect(
            store.visibleEntries(paneID: paneA, tabID: tab1, scope: .tab, location: dirB, shareByDirectory: true).map(\.text)
                == ["paneB in B", "sibling in tab1", "paneA in A"]
        )
        // - paneB in dirB does NOT see paneA's dirA history (no leak from A to other panes in B)
        #expect(
            store.visibleEntries(paneID: paneB, tabID: tab2, scope: .pane, location: dirB, shareByDirectory: true).map(\.text)
                == ["paneB in B"]
        )
        // - With shareByDirectory == false: paneA in dirB only sees its own pane / tab history
        #expect(
            store.visibleEntries(paneID: paneA, tabID: tab1, scope: .pane, location: dirB, shareByDirectory: false).map(\.text)
                == ["paneA in A"]
        )
        #expect(
            store.visibleEntries(paneID: paneA, tabID: tab1, scope: .tab, location: dirB, shareByDirectory: false).map(\.text)
                == ["sibling in tab1", "paneA in A"]
        )
    }

    @Test func directorySharingIsolatesLocalAndSSHHostsAndHandlesConnectingFallback() {
        var timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(now: { timestamp })
        let localPane = UUID()
        let sshAPane = UUID()
        let sshBPane = UUID()
        let otherPane = UUID()
        let tab1 = UUID()
        let tab2 = UUID()
        let tab3 = UUID()

        let localRoot = QuickInputHistoryLocation(workingDirectory: "/root/")!
        let sshARoot = QuickInputHistoryLocation(workingDirectory: "/root//", remoteHostKey: "srv-a")!
        let sshBRoot = QuickInputHistoryLocation(workingDirectory: "/root", remoteHostKey: "srv-b")!

        #expect(localRoot.workingDirectory == "/root")
        #expect(sshARoot.workingDirectory == "/root")
        #expect(localRoot != sshARoot)
        #expect(sshARoot != sshBRoot)

        store.record("local cmd", paneID: localPane, tabID: tab1, location: localRoot)
        timestamp = timestamp.addingTimeInterval(1)
        store.record("sshA cmd", paneID: sshAPane, tabID: tab2, location: sshARoot)
        timestamp = timestamp.addingTimeInterval(1)
        store.record("sshB cmd", paneID: sshBPane, tabID: tab3, location: sshBRoot)

        #expect(
            store.visibleEntries(paneID: otherPane, tabID: UUID(), scope: .pane, location: localRoot, shareByDirectory: true).map(\.text)
                == ["local cmd"]
        )
        #expect(
            store.visibleEntries(paneID: otherPane, tabID: UUID(), scope: .pane, location: sshARoot, shareByDirectory: true).map(\.text)
                == ["sshA cmd"]
        )
        #expect(
            store.visibleEntries(paneID: otherPane, tabID: UUID(), scope: .pane, location: sshBRoot, shareByDirectory: true).map(\.text)
                == ["sshB cmd"]
        )

        // PaneSessionContext.sshConnecting must return nil location so it never mixes local cwd with SSH
        var connectingContext = PaneSessionContext(workingDirectory: "/root", terminalTitle: "ssh")
        connectingContext.observeForegroundSSH(
            alias: "prod",
            transferTarget: "ubuntu@prod",
            processGroupID: 42,
            currentWorkingDirectory: "/root",
            currentTerminalTitle: "ssh",
            remoteWorkingDirectory: nil
        )
        #expect(QuickInputHistoryLocation.from(connectingContext) == nil)
        #expect(
            store.visibleEntries(
                paneID: sshAPane,
                tabID: tab2,
                scope: .pane,
                location: QuickInputHistoryLocation.from(connectingContext),
                shareByDirectory: true
            ).map(\.text) == ["sshA cmd"]
        )

        // Once sshReady, remoteHostKey + remote workingDirectory are resolved
        connectingContext.applyInferredRemoteWorkingDirectory("/root/app/")
        let readyLocation = QuickInputHistoryLocation.from(connectingContext)
        #expect(readyLocation == QuickInputHistoryLocation(workingDirectory: "/root/app", remoteHostKey: "ubuntu@prod"))

        // OMG SSH signal with empty serverid must fall back to targethost (never misclassified as local)
        var signalContext = PaneSessionContext(workingDirectory: "/root", terminalTitle: "ssh")
        signalContext.apply(
            Ghostty.ContextSignal(
                action: .start,
                id: "omg-ssh-test-1",
                metadata: "type=remote;targethost=prod-box;serverid=;cwd=%2Froot%2Fapp"
            ),
            currentWorkingDirectory: "/root",
            currentTerminalTitle: "ssh"
        )
        let signalLocation = QuickInputHistoryLocation.from(signalContext)
        #expect(signalLocation == QuickInputHistoryLocation(workingDirectory: "/root/app", remoteHostKey: "prod-box"))
        #expect(signalLocation != localRoot)
    }

    @Test func visibleEntriesDeduplicatesCrossPaneIdenticalTextKeepingLatest() {
        var timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = QuickInputHistoryStore(now: { timestamp })
        let pane1 = UUID()
        let pane2 = UUID()
        let tab1 = UUID()
        let tab2 = UUID()
        let dir = QuickInputHistoryLocation(workingDirectory: "/tmp/shared-dedup")!

        store.record("git status", paneID: pane1, tabID: tab1, location: dir)
        let olderTime = timestamp
        timestamp = timestamp.addingTimeInterval(5)
        store.record("unique cmd", paneID: pane1, tabID: tab1, location: dir)
        timestamp = timestamp.addingTimeInterval(5)
        store.record("git status", paneID: pane2, tabID: tab2, location: dir)
        let newerTime = timestamp

        let dirVisible = store.visibleEntries(paneID: pane1, tabID: tab1, scope: .pane, location: dir, shareByDirectory: true)
        #expect(dirVisible.map(\.text) == ["git status", "unique cmd"])
        #expect(dirVisible.first?.sentAt == newerTime)
        #expect(dirVisible.first?.sentAt != olderTime)

        let globalVisible = store.visibleEntries(paneID: pane1, tabID: tab1, scope: .global)
        #expect(globalVisible.map(\.text) == ["git status", "unique cmd"])
        #expect(globalVisible.first?.paneID == pane2)
    }

    @Test func legacyV1EntriesWithoutLocationDecodeCleanlyAndStayPaneOwned() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pane = UUID()
        let tab = UUID()
        let payload: [String: Any] = [
            "version": 1,
            "entries": [
                [
                    "id": UUID().uuidString,
                    "paneID": pane.uuidString,
                    "tabID": tab.uuidString,
                    "text": "legacy entry",
                    "sentAt": Date().timeIntervalSinceReferenceDate,
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let restored = QuickInputHistoryStore(fileURL: file)
        #expect(restored.entries.count == 1)
        #expect(restored.entries.first?.workingDirectory == nil)
        #expect(restored.entries.first?.remoteHostKey == nil)
        #expect(restored.entries.first?.location == nil)

        let someDir = QuickInputHistoryLocation(workingDirectory: "/tmp/some-dir")!
        #expect(restored.visibleEntries(paneID: pane, tabID: tab, scope: .pane, location: someDir, shareByDirectory: true).map(\.text) == ["legacy entry"])
        #expect(restored.visibleEntries(paneID: UUID(), tabID: UUID(), scope: .pane, location: someDir, shareByDirectory: true).isEmpty)
    }

    @Test func modelLocationUpdateReactsImmediatelyForNavigationAndRecording() {
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let paneA = UUID()
        let paneB = UUID()
        let dirA = QuickInputHistoryLocation(workingDirectory: "/tmp/model-dir-a")!
        let dirB = QuickInputHistoryLocation(workingDirectory: "/tmp/model-dir-b")!

        model.present(for: paneA)
        model.updateHistoryLocation(dirA, for: paneA)
        model.recordSentText("from A", for: paneA)
        store.record("from B", paneID: paneB, tabID: UUID(), location: dirB)

        // While in dirA, paneA only sees "from A"
        #expect(store.visibleEntries(paneID: paneA, tabID: model.historyTabID, scope: .pane, location: model.targetHistoryLocation, shareByDirectory: true).map(\.text) == ["from A"])

        // After cd to dirB, paneA immediately sees "from B" + "from A" via navigateHistory
        model.updateHistoryLocation(dirB, for: paneA)
        let draft = QuickInputDraftSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        _ = model.navigateHistory(.older, current: draft, scope: .pane, shareByDirectory: true, atBoundary: true, isRepeat: false)
        _ = model.navigateHistory(.older, current: draft, scope: .pane, shareByDirectory: true, atBoundary: true, isRepeat: false)
        #expect(model.draft == "from B")
    }
}
