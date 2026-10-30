import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalWorkspaceTests {
    @Test func deletingWorkspacePreservesTabsAndMergesWindowGroups() throws {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let id = try #require(store.create(name: "Delete", symbol: "house", color: "blue"))
        let host = UUID(), first = UUID(), second = UUID()
        store.assign(tab: first, to: store.defaultID)
        store.assign(tab: second, to: id)
        store.rememberGroup(window: host, workspace: store.defaultID,
            group: .init(id: UUID(), tabs: [first], selected: first))
        store.rememberGroup(window: host, workspace: id,
            group: .init(id: UUID(), tabs: [second], selected: second))
        store.selectWorkspace(id, in: host, frame: nil, fullscreen: nil)
        #expect(store.delete(id: id))
        #expect(store.workspaceID(for: second) == store.defaultID)
        #expect(store.group(window: host, workspace: store.defaultID)?.tabs == [first, second])
        #expect(store.snapshot.windows?[host]?.currentWorkspace == store.defaultID)
        #expect(store.group(window: host, workspace: id) == nil)
    }

    @Test func catalogRoundTripsStableMembershipAndPresentation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalWorkspaceStore(fileURL: url)
        let work = try #require(store.create(name: " Work ", symbol: "briefcase", color: "blue"))
        let tab = UUID()
        store.assign(tab: tab, to: work)
        store.rememberPresentation(hidden: [tab], selected: [work: tab])
        store.setShortcut(slot: 2, value: "control+shift+command+2")
        store.flush()

        let restored = TerminalWorkspaceStore(fileURL: url)
        #expect(restored.workspace(work).name == "Work")
        #expect(restored.workspaceID(for: tab) == work)
        #expect(restored.snapshot.hiddenTabs == [tab])
        #expect(restored.snapshot.selectedTabs[work] == tab)
        #expect(restored.shortcut(slot: 2) == "control+shift+command+2")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func windowGroupsPersistIndependentSelectionHistoryAndScroll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        let store = TerminalWorkspaceStore(fileURL: url)
        let first = store.defaultID
        let second = try #require(store.create(name: "Two", symbol: "house", color: "blue"))
        let a = UUID(), b = UUID(), aTab = UUID(), bTab = UUID()
        store.rememberGroup(window: a, workspace: first, group: .init(id: UUID(), tabs: [aTab], selected: aTab, scrollOffset: 25))
        store.rememberGroup(window: b, workspace: first, group: .init(id: UUID(), tabs: [bTab], selected: bTab, scrollOffset: 320))
        store.selectWorkspace(second, in: b, frame: .init(x: 50, y: 60, width: 800, height: 500), fullscreen: false)
        store.flush()
        let restored = TerminalWorkspaceStore(fileURL: url)
        #expect(restored.group(window: a, workspace: first)?.selected == aTab)
        #expect(restored.group(window: b, workspace: first)?.selected == bTab)
        #expect(restored.group(window: a, workspace: first)?.scrollOffset == 25)
        #expect(restored.group(window: b, workspace: first)?.scrollOffset == 320)
        #expect(restored.snapshot.windows?[a]?.currentWorkspace == first)
        #expect(restored.snapshot.windows?[b]?.currentWorkspace == second)
        #expect(restored.snapshot.windows?[b]?.previousWorkspace == first)
        restored.removeTab(bTab, window: b, workspace: first)
        #expect(restored.group(window: a, workspace: first)?.tabs == [aTab])
        #expect(restored.group(window: b, workspace: first)?.tabs.isEmpty == true)
        let host = VerticalTabSidebarHost()
        host.restoreScrollOffset(320)
        #expect(host.scrollOffset == 320)
    }

    @Test func workspaceChromeIsIsolatedAndPersistsWithoutSharingDrafts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        let store = TerminalWorkspaceStore(fileURL: url)
        let other = try #require(store.create(name: "Other", symbol: "house", color: "blue"))
        let first = store.quickInputPresentation(for: store.defaultID)
        let second = store.quickInputPresentation(for: other)
        let model = AgentQuickInputModel(globalPresentation: first)
        let sibling = AgentQuickInputModel(globalPresentation: first)
        let foreign = AgentQuickInputModel(globalPresentation: second)
        model.bindGlobalTarget { UUID() }
        sibling.bindGlobalTarget { UUID() }
        foreign.bindGlobalTarget { UUID() }
        first.setPresented(true)
        first.togglePinned()
        first.setHeight(310)
        model.draft = "Only this pane"
        #expect(sibling.isPresented)
        #expect(sibling.draft.isEmpty)
        #expect(!foreign.isPresented)
        #expect(!foreign.isPinned)
        #expect(foreign.draft.isEmpty)
        #expect(model.dockHeight == 310)
        store.updatePresentation(for: other) {
            $0.sidebarVisible = false
            $0.sidebarWidth = 300
            $0.inspectorVisible = true
            $0.inspectorWidth = 350
        }
        store.flush()
        let restored = TerminalWorkspaceStore(fileURL: url)
        #expect(restored.presentation(for: other).sidebarWidth == 300)
        #expect(restored.presentation(for: other).inspectorVisible)
        #expect(!restored.presentation(for: other).quickInputVisible)
        #expect(restored.quickInputPresentation(for: store.defaultID).isPresented)
        #expect(restored.quickInputPresentation(for: store.defaultID).height == 310)
        #expect(restored.quickInputPresentation(for: store.defaultID).isPinned)
    }

    @Test func nativeGroupHandoffRestoresWorkspaceLayout() {
        let first = UUID()
        let second = UUID()
        let layout = VerticalTabWindowLayoutState(isSidebarVisible: true)
        layout.bindWorkspace(first)
        layout.setSidebarVisible(false)
        layout.setInspectorVisible(true)
        layout.updateSidebarWidth(280, availableWidth: 1200, persist: true)
        layout.updateInspectorWidth(360, availableWidth: 1200, persist: true)
        layout.selectInspectorPane("files")
        layout.bindWorkspace(second)
        layout.setSidebarVisible(true)
        layout.setInspectorVisible(false)
        layout.updateSidebarWidth(220, availableWidth: 1200, persist: true)
        layout.bindWorkspace(first)
        #expect(!layout.isSidebarVisible)
        #expect(layout.isInspectorVisible)
        #expect(layout.sidebarWidth == 280)
        #expect(layout.inspectorWidth == 360)
        #expect(layout.selectedInspectorPaneID == "files")
        layout.bindWorkspace(second)
        #expect(layout.isSidebarVisible)
        #expect(!layout.isInspectorVisible)
        #expect(layout.sidebarWidth == 220)
    }

    @Test func newTabsInheritButKnownTabsKeepTheirWorkspace() throws {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let work = try #require(store.create(name: "Work", symbol: "briefcase", color: "blue"))
        let tab = UUID()
        #expect(store.workspaceID(for: tab, inheriting: work) == work)
        store.assign(tab: tab, to: store.defaultID)
        #expect(store.workspaceID(for: tab, inheriting: work) == store.defaultID)
        #expect(store.workspaceID(for: UUID(), inheriting: UUID()) == store.defaultID)
    }

    @Test func malformedCatalogCannotLoseTheDefaultWorkspace() throws {
        var snapshot = TerminalWorkspaceStore.Snapshot()
        snapshot.workspaces = []
        #expect(!TerminalWorkspaceStore.isValid(snapshot))
        snapshot.workspaces = [.initial, .initial]
        #expect(!TerminalWorkspaceStore.isValid(snapshot))
        snapshot.workspaces = [.initial]
        snapshot.membership = [UUID(): UUID()]
        #expect(!TerminalWorkspaceStore.isValid(snapshot))
        snapshot.membership = [:]
        snapshot.version = 2
        #expect(!TerminalWorkspaceStore.isValid(snapshot))
    }

    @Test func shortcutSlotsStayStableAndRequireCommand() throws {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let work = try #require(store.create(name: "Work", symbol: "briefcase", color: "blue"))
        store.update(id: work, name: "Office", symbol: "folder", color: "purple")
        #expect(store.workspaces[1].id == work)
        #expect(store.shortcut(slot: 0) == "control+command+w")
        #expect(store.shortcut(slot: 2) == "control+command+2")
        store.setShortcut(slot: 2, value: "control+2")
        #expect(store.shortcut(slot: 2) == "control+command+2")
        store.setShortcut(slot: 2, value: store.shortcut(slot: 1))
        #expect(store.shortcutConflict(slot: 2) != nil)
    }
}
