import AppKit
import Combine

/// Write-ahead session catalog independent of AppKit's clean-exit archives.
/// Encoded terminal states contain typed resume descriptors, never live processes.
@MainActor
final class TerminalWorkspaceSessionStore {
    static let shared = TerminalWorkspaceSessionStore()
    struct Tab: Codable {
        var id: UUID
        var workspace: UUID
        var state: Data
    }
    struct Snapshot: Codable {
        var version = 1
        var tabs: [Tab] = []
    }
    static let restoreSessionsKey = CodingUserInfoKey(rawValue: "omg.workspace.restore-sessions")!
    private let url: URL
    private let testing: Bool

    init(url: URL? = nil, testing: Bool = false) {
        self.url = url ?? OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("workspaces/sessions.json")
        self.testing = testing
    }
    private var saved = Snapshot()
    private var timer: AnyCancellable?
    private var started = false
    private var restoring = false
    private var removed = Set<UUID>()
    private(set) var ownsRestoration = false

    func prepare() {
        guard testing || NSClassFromString("XCTestCase") == nil else { return }
        if let data = try? Data(contentsOf: url), data.count <= 32 * 1_024 * 1_024,
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 {
            saved = snapshot
            ownsRestoration = true
        }
    }

    func start(_ app: Ghostty.App) {
        guard testing || NSClassFromString("XCTestCase") == nil else { return }
        restoring = true
        let decoder = JSONDecoder()
        decoder.userInfo[Self.restoreSessionsKey] = true
        if ownsRestoration {
            var anchors: [UUID: NSWindow] = [:]
            for tab in saved.tabs {
                guard !TerminalController.all.contains(where: { $0.tabSessionID == tab.id }),
                      let state = try? decoder.decode(TerminalRestorableState.self, from: tab.state) else { continue }
                let controller = TerminalController(
                    app, withSurfaceTree: state.surfaceTree, tabSessionID: tab.id,
                    tabCreatedAt: state.tabCreatedAt, workspaceID: tab.workspace
                )
                controller.titleOverride = state.titleOverride
                if let focused = state.focusedSurface {
                    controller.focusedSurface = controller.surfaceTree.first { $0.id.uuidString == focused }
                }
                guard let window = controller.window else { continue }
                if let anchor = anchors[tab.workspace] { _ = anchor.addTabbedWindowSafely(window, ordered: .above) }
                anchors[tab.workspace] = window
                controller.refreshWorkspaceTabs()
                if !TerminalWorkspaceStore.shared.snapshot.hiddenTabs.contains(tab.id) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        for (workspace, anchor) in anchorsForRestoredTabs() {
            let selectedID = TerminalWorkspaceStore.shared.snapshot.selectedTabs[workspace]
            if let selected = anchor.tabGroup?.windows.first(where: {
                ($0.windowController as? TerminalController)?.tabSessionID == selectedID
            }) {
                anchor.tabGroup?.selectedWindow = selected
            }
        }
        if ownsRestoration, saved.tabs.isEmpty, TerminalController.all.isEmpty {
            _ = TerminalController.newWindow(app)
        }
        restoring = false
        started = true
        capture()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.capture()
        }
    }

    private func anchorsForRestoredTabs() -> [UUID: NSWindow] {
        var anchors: [UUID: NSWindow] = [:]
        for controller in TerminalController.all where anchors[controller.workspaceID] == nil {
            anchors[controller.workspaceID] = controller.window
        }
        return anchors
    }

    func forget(_ controller: TerminalController) {
        guard started else { return }
        removed.insert(controller.tabSessionID)
        saved.tabs.removeAll { $0.id == controller.tabSessionID }
        persist()
    }

    /// Retain a window-close snapshot; only explicit tab close removes it.
    func capture() {
        guard started, !restoring else { return }
        for controller in TerminalController.all where !controller.surfaceTree.isEmpty && !removed.contains(controller.tabSessionID) {
            guard let data = try? JSONEncoder().encode(TerminalRestorableState(from: controller)) else { continue }
            let tab = Tab(id: controller.tabSessionID, workspace: controller.workspaceID, state: data)
            if let index = saved.tabs.firstIndex(where: { $0.id == tab.id }) { saved.tabs[index] = tab } else { saved.tabs.append(tab) }
        }
        // Retain saved closed-window records, but refresh live native ordering.
        let order = TerminalController.all.flatMap { controller in
            (controller.window?.tabGroup?.windows ?? []).compactMap {
                ($0.windowController as? TerminalController)?.tabSessionID
            }
        }
        var ranks: [UUID: Int] = [:]
        for id in order where ranks[id] == nil { ranks[id] = ranks.count }
        saved.tabs.sort { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
        persist()
    }

    private var lastData: Data?
    private func persist() {
        guard let data = try? JSONEncoder().encode(saved), data != lastData else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastData = data
        } catch {
            AppDelegate.logger.error("Workspace session snapshot could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
