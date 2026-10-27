import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalWorkspaceTests {
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
