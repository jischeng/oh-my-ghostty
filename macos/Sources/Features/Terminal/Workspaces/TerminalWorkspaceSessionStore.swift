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
        var window: UUID?
    }
    struct Snapshot: Codable {
        var version = 1
        var tabs: [Tab] = []
    }
    static let restoreSessionsKey = CodingUserInfoKey(rawValue: "omg.workspace.restore-sessions")!
    private let url: URL
    private let testing: Bool
    private let workspaces: TerminalWorkspaceStore

    init(url: URL? = nil, testing: Bool = false, workspaces: TerminalWorkspaceStore? = nil) {
        self.url = url ?? OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("workspaces/sessions.json")
        self.testing = testing
        self.workspaces = workspaces ?? .shared
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
            migrateWindowGroups()
            ownsRestoration = true
        }
    }

    private func migrateWindowGroups() {
        // A legacy native group is the only reliable window boundary. Do not
        // infer that unrelated parked groups used to share a window.
        for index in saved.tabs.indices {
            let group = saved.tabs[index].group ?? saved.tabs[index].workspace
            saved.tabs[index].group = group
            if saved.tabs[index].window == nil { saved.tabs[index].window = group }
        }
        for (host, tabs) in Dictionary(grouping: saved.tabs, by: { $0.window! }) {
            for (workspace, members) in Dictionary(grouping: tabs, by: \.workspace) {
                guard workspaces.group(window: host, workspace: workspace) == nil else { continue }
                let selected = members.first { $0.selected == true }?.id ?? members.first?.id
                workspaces.rememberGroup(window: host, workspace: workspace,
                    group: .init(id: members[0].group!, tabs: members.map(\.id), selected: selected))
            }
            if let tab = tabs.first, workspaces.snapshot.windows?[host]?.frame == nil {
                let current = workspaces.snapshot.windows?[host]?.currentWorkspace ?? tab.workspace
                workspaces.selectWorkspace(current, in: host, frame: tab.frame, fullscreen: tab.fullscreen)
            }
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
            TerminalWorkspacePresentation.begin()
            defer {
                for anchor in anchors.values {
                    if let controller = anchor.windowController as? TerminalController {
                        controller.tabLayoutState.sidebarHost.restoreScrollOffset(workspaces.group(
                            window: controller.windowSessionID, workspace: controller.workspaceID)?.scrollOffset)
                    }
                }
                TerminalWorkspacePresentation.end()
                for anchor in anchors.values {
                    (anchor.windowController as? TerminalController)?.refreshWorkspaceTabs()
                    anchor.contentView?.superview?.layoutSubtreeIfNeeded()
                    if let controller = anchor.windowController as? TerminalController {
                        controller.tabLayoutState.sidebarHost.restoreScrollOffset(workspaces.group(
                            window: controller.windowSessionID, workspace: controller.workspaceID)?.scrollOffset)
                    }
                    anchor.contentView?.displayIfNeeded()
                }
                NSEnableScreenUpdates()
            }
            for tab in saved.tabs {
                guard let controller = restore(tab, app: app, decoder: decoder),
                      let window = controller.window else { continue }
                let group = tab.group ?? tab.workspace
                if let anchor = anchors[group] { _ = anchor.addTabbedWindowSafely(window, ordered: .above) }
                anchors[group] = window
                controller.cancelWorkspacePendingPresentation()
            }
            // Assemble every group before exposing its selected tab. Showing
            // each tab during construction causes visible incremental restore.
            let presentation = workspaces.snapshot
            for (_, anchor) in anchors {
                guard let controller = anchor.windowController as? TerminalController else { continue }
                let workspace = controller.workspaceID
                let host = controller.windowSessionID
                let record = presentation.windows?[host]
                let windows = anchor.tabGroup?.windows ?? [anchor]
                let selectedID = record?.groups[workspace]?.selected ?? saved.tabs.first {
                    ($0.window ?? $0.group ?? $0.workspace) == host && $0.workspace == workspace && $0.selected == true
                }?.id
                let selected = windows.first { ($0.windowController as? TerminalController)?.tabSessionID == selectedID } ?? anchor
                anchor.tabGroup?.selectedWindow = selected
                let hidden = record.map { $0.currentWorkspace != workspace } ?? false
                for window in windows {
                    (window.windowController as? TerminalController)?.workspacePresentationIsParked = hidden
                }
                if !hidden {
                    if let frame = record?.frame { selected.setFrame(frame, display: false); selected.constrainToScreen() }
                    selected.makeKeyAndOrderFront(nil)
                    let selectedID = (selected.windowController as? TerminalController)?.tabSessionID
                    if record?.fullscreen ?? (saved.tabs.first(where: { $0.id == selectedID })?.fullscreen == true) {
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
            let host = (anchor.windowController as? TerminalController)?.windowSessionID
            let selectedID = host.flatMap { workspaces.group(window: $0, workspace: workspace)?.selected }
                ?? workspaces.snapshot.selectedTabs[workspace]
            if let selected = anchor.tabGroup?.windows.first(where: {
                ($0.windowController as? TerminalController)?.tabSessionID == selectedID
            }) {
                anchor.tabGroup?.selectedWindow = selected
            }
        }
        // A valid catalog can still contain only undecodable records. It must
        // not suppress the initial window when no surface could be restored.
        if ownsRestoration, TerminalController.all.isEmpty {
            _ = TerminalController.newWindow(app)
        }
        if ownsRestoration, !testing {
            // Run after selection restoration has parked hidden groups. Never
            // strand a launch with live sessions but no accessible window.
            DispatchQueue.main.async {
                TerminalWorkspaceCoordinator.shared.ensureVisibleWorkspace()
            }
        }
        restoring = false
        started = true
        capture()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.capture()
        }
    }

    /// A window close retains its catalog entries. Reopen them only when the
    /// user switches to that workspace, never by re-showing a torn-down window.
    /// The coordinator attaches this ordered group to the current window.
    func restoreWorkspace(_ id: UUID, window: UUID, group: UUID?, app: Ghostty.App, parent: NSWindow?) -> [TerminalController] {
        let wasRestoring = restoring
        restoring = true
        defer { restoring = wasRestoring }
        let decoder = JSONDecoder()
        decoder.userInfo[Self.restoreSessionsKey] = true
        return saved.tabs.filter {
            $0.workspace == id && ($0.window ?? $0.group ?? $0.workspace) == window &&
                (group == nil || ($0.group ?? $0.workspace) == group) && !removed.contains($0.id)
        }.compactMap { restore($0, app: app, decoder: decoder, parent: parent) }
    }

    private func restore(
        _ tab: Tab, app: Ghostty.App, decoder: JSONDecoder, parent: NSWindow? = nil
    ) -> TerminalController? {
        guard !TerminalController.all.contains(where: { $0.tabSessionID == tab.id && $0.isAvailableForWorkspace }),
              let state = try? decoder.decode(TerminalRestorableState.self, from: tab.state),
              !state.surfaceTree.isEmpty else { return nil }
        let controller = TerminalController(
            app, withSurfaceTree: state.surfaceTree, parent: parent,
            tabLayout: (parent?.windowController as? TerminalController)?.tabLayout,
            tabSessionID: tab.id, tabCreatedAt: state.tabCreatedAt, workspaceID: tab.workspace,
            windowSessionID: tab.window ?? tab.group ?? tab.workspace,
            workspaceGroupID: tab.group ?? tab.workspace
        )
        controller.workspaceID = tab.workspace
        controller.titleOverride = state.titleOverride
        if let focused = state.focusedSurface {
            controller.focusedSurface = controller.surfaceTree.first { $0.id.uuidString == focused }
        }
        guard let window = controller.window else { return nil }
        if parent == nil, let frame = tab.frame {
            window.setFrame(frame, display: false)
            window.constrainToScreen()
        }
        (window as? TerminalWindow)?.tabColor = state.tabColor ?? .none
        controller.cancelWorkspacePendingPresentation()
        return controller
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
        workspaces.removeTab(controller.tabSessionID, window: controller.windowSessionID, workspace: controller.workspaceID)
        saved.tabs.removeAll { $0.id == controller.tabSessionID }
        persist()
    }

    /// Retain a window-close snapshot; only explicit tab close removes it.
    func capture() {
        guard started, !restoring, !quitting, !TerminalWorkspacePresentation.isChanging else { return }
        let live = TerminalController.all.filter { $0.isAvailableForWorkspace && !removed.contains($0.tabSessionID) }
        var visited = Set<UUID>()
        for controller in live where !controller.workspacePresentationIsParked && !visited.contains(controller.workspaceGroupID) {
            let members = (controller.window?.tabGroup?.windows ?? [controller.window].compactMap { $0 }).compactMap {
                $0.windowController as? TerminalController
            }.filter(\.isAvailableForWorkspace)
            TerminalWorkspaceCoordinator.shared.reconcileNativeGroup(members)
            visited.insert(controller.workspaceGroupID)
            let ids = members.filter { $0.isAvailableForWorkspace }.map(\.tabSessionID)
            let selected = (controller.window?.tabGroup?.selectedWindow?.windowController as? TerminalController) ?? controller
            workspaces.rememberGroup(window: controller.windowSessionID, workspace: controller.workspaceID,
                group: .init(id: controller.workspaceGroupID, tabs: ids.isEmpty ? [controller.tabSessionID] : ids,
                    selected: selected.tabSessionID, scrollOffset: controller.tabLayoutState.sidebarHost.scrollOffset))
            workspaces.selectWorkspace(controller.workspaceID, in: controller.windowSessionID,
                frame: controller.window?.frame, fullscreen: controller.window?.styleMask.contains(.fullScreen))
        }
        for controller in live {
            guard let data = try? JSONEncoder().encode(TerminalRestorableState(from: controller)) else { continue }
            let window = controller.window
            let selection = workspaces.group(window: controller.windowSessionID, workspace: controller.workspaceID)?.selected
            let tab = Tab(id: controller.tabSessionID, workspace: controller.workspaceID, state: data,
                group: controller.workspaceGroupID, selected: selection == controller.tabSessionID,
                frame: window?.frame, fullscreen: window?.styleMask.contains(.fullScreen), window: controller.windowSessionID)
            if let index = saved.tabs.firstIndex(where: { $0.id == tab.id }) { saved.tabs[index] = tab } else { saved.tabs.append(tab) }
        }
        // Retain saved closed-window records, but refresh live native ordering.
        let order = workspaces.snapshot.windows?.values.flatMap { $0.groups.values.flatMap(\.tabs) } ?? []
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
