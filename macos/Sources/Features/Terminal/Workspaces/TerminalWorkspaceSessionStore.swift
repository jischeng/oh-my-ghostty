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
        var group: UUID?
        var selected: Bool?
        var frame: CGRect?
        var fullscreen: Bool?
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
    private var quitting = false
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
            NSDisableScreenUpdates()
            defer { NSEnableScreenUpdates() }
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
                if let frame = tab.frame {
                    window.setFrame(frame, display: false)
                    window.constrainToScreen()
                }
                (window as? TerminalWindow)?.tabColor = state.tabColor ?? .none
                let group = tab.group ?? tab.workspace
                if let anchor = anchors[group] { _ = anchor.addTabbedWindowSafely(window, ordered: .above) }
                anchors[group] = window
                controller.cancelWorkspacePendingPresentation()
            }
            // Assemble every group before exposing its selected tab. Showing
            // each tab during construction causes visible incremental restore.
            let presentation = TerminalWorkspaceStore.shared.snapshot
            for (_, anchor) in anchors {
                let workspace = (anchor.windowController as? TerminalController)?.workspaceID
                let windows = anchor.tabGroup?.windows ?? [anchor]
                let visible = windows.filter {
                    guard let controller = $0.windowController as? TerminalController else { return false }
                    return !presentation.hiddenTabs.contains(controller.tabSessionID)
                }
                let selected = visible.first {
                    guard let id = ($0.windowController as? TerminalController)?.tabSessionID else { return false }
                    return saved.tabs.first(where: { $0.id == id })?.selected == true ||
                        (workspace.flatMap { presentation.selectedTabs[$0] } == id)
                } ?? visible.first
                (anchor.windowController as? TerminalController)?.refreshWorkspaceTabs()
                if let selected {
                    anchor.tabGroup?.selectedWindow = selected
                    selected.makeKeyAndOrderFront(nil)
                    let selectedID = (selected.windowController as? TerminalController)?.tabSessionID
                    if saved.tabs.first(where: { $0.id == selectedID })?.fullscreen == true {
                        DispatchQueue.main.async { [weak selected] in
                            guard let selected, selected.isVisible,
                                  !selected.styleMask.contains(.fullScreen) else { return }
                            selected.toggleFullScreen(nil)
                        }
                    }
                }
            }
        }
        for (workspace, anchor) in ownsRestoration ? [:] : anchorsForRestoredTabs() {
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

    /// Freeze the catalog before AppKit starts removing/reordering tab windows.
    /// Confirmation dialogs and windowWillClose callbacks must not replace the
    /// user's layout with an intermediate teardown order.
    func prepareToQuit() {
        guard started, !quitting else { return }
        if !testing { TerminalWorkspaceCoordinator.shared.prepareToQuit() }
        capture()
        quitting = true
    }

    func cancelQuit() {
        if !testing { TerminalWorkspaceCoordinator.shared.cancelQuit() }
        quitting = false
        capture()
    }

    func forget(_ controller: TerminalController) {
        guard started, !quitting else { return }
        removed.insert(controller.tabSessionID)
        saved.tabs.removeAll { $0.id == controller.tabSessionID }
        persist()
    }

    /// Retain a window-close snapshot; only explicit tab close removes it.
    func capture() {
        guard started, !restoring, !quitting else { return }
        for controller in TerminalController.all where !controller.surfaceTree.isEmpty && !removed.contains(controller.tabSessionID) {
            guard let data = try? JSONEncoder().encode(TerminalRestorableState(from: controller)) else { continue }
            let window = controller.window
            let parkedGroup = TerminalWorkspaceStore.shared.snapshot.parkedGroups?.first {
                $0.value.contains(controller.tabSessionID)
            }?.key
            let group = parkedGroup ?? (window?.tabGroup?.windows.first?.windowController as? TerminalController)?.tabSessionID
                ?? controller.tabSessionID
            let tab = Tab(id: controller.tabSessionID, workspace: controller.workspaceID, state: data,
                group: group, selected: (window?.tabGroup?.selectedWindow ?? window) === window,
                frame: window?.frame, fullscreen: window?.styleMask.contains(.fullScreen))
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
