import AppKit
import Combine

/// Keeps native tab groups alive while parked. Switching never closes a window,
/// serializes a SurfaceView, or starts another copy of a running process.
@MainActor
final class TerminalWorkspaceCoordinator: ObservableObject {
    static let shared = TerminalWorkspaceCoordinator()
    @Published private(set) var previousWorkspaceID: UUID?
    @Published private(set) var revision = 0
    private(set) var parked: [UUID: TerminalController] = [:]
    private var selectedTabs: [UUID: UUID] = [:]
    private var parkedGroups: [UUID: [TerminalController]] = [:]
    private var isSwitching = false
    private var restoring = true
    let store: TerminalWorkspaceStore

    init(store: TerminalWorkspaceStore? = nil) {
        let store = store ?? .shared
        self.store = store
        selectedTabs = store.snapshot.selectedTabs
    }

    func controllers(in id: UUID) -> [TerminalController] {
        TerminalController.all.filter { $0.workspaceID == id && !$0.surfaceTree.isEmpty }
    }

    func register(_ controller: TerminalController) {
        store.assign(tab: controller.tabSessionID, to: controller.workspaceID)
    }

    func didActivate(_ controller: TerminalController) {
        guard !isSwitching, !restoring else { return }
        // A native Window menu or Dock activation must restore the entire
        // parked group, rather than expose one detached tab in isolation.
        if parked[controller.tabSessionID] != nil {
            isSwitching = true
            activate(controller, matching: nil)
            isSwitching = false
        }
        selectedTabs[controller.workspaceID] = controller.tabSessionID
        savePresentation()
    }

    func didClose(_ controller: TerminalController) {
        parked.removeValue(forKey: controller.tabSessionID)
        for id in Array(parkedGroups.keys) {
            parkedGroups[id]?.removeAll { $0 === controller }
        }
        revision &+= 1
        if !restoring { savePresentation() }
    }

    func handle(_ event: NSEvent, in controller: TerminalController) -> Bool {
        guard controller.window?.attachedSheet == nil,
              (controller.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        for slot in 0...min(9, store.workspaces.count) {
            guard let shortcut = OMGKeyboardShortcut(storageValue: store.shortcut(slot: slot)),
                  shortcut.matches(event) else { continue }
            if slot == 0 {
                controller.workspaceSwitcherIsPresented.toggle()
            } else {
                switchWorkspace(to: store.workspaces[slot - 1].id, from: controller)
            }
            return true
        }
        return false
    }

    @discardableResult
    func switchWorkspace(to id: UUID, from source: TerminalController) -> TerminalController? {
        guard store.workspaces.contains(where: { $0.id == id }), !isSwitching,
              source.window?.attachedSheet == nil else { return nil }
        source.workspaceSwitcherIsPresented = false
        if source.workspaceID == id { return source }
        let candidates = controllers(in: id)
        let visible = candidates.first {
            !parked.keys.contains($0.tabSessionID) && $0.window?.isVisible == true
        }
        let target = visible ?? candidates.first { $0.tabSessionID == selectedTabs[id] } ?? candidates.first
        isSwitching = true
        defer { isSwitching = false }
        previousWorkspaceID = source.workspaceID
        selectedTabs[source.workspaceID] = source.tabSessionID

        // An already-visible workspace belongs to another window: focus it and
        // leave the source window alone, rather than duplicating its sessions.
        if let visible {
            activate(visible, matching: nil)
            selectedTabs[id] = visible.tabSessionID
            savePresentation()
            return visible
        }

        let destination: TerminalController
        if let target {
            destination = target
        } else {
            destination = TerminalController(source.ghostty, tabLayout: source.tabLayout, workspaceID: id)
            destination.isBackgroundOpaque = source.isBackgroundOpaque
            guard destination.window != nil else { return nil }
        }
        guard let sourceWindow = source.window, destination.window != nil else { return nil }
        let outgoing = groupControllers(source)
        parkedGroups[source.tabSessionID] = outgoing
        for member in outgoing {
            member.cancelWorkspacePendingPresentation()
            parked[member.tabSessionID] = member
        }
        // Keep the native fullscreen container alive across the handoff. The
        // incoming tab joins it before any outgoing tab is detached.
        NSDisableScreenUpdates()
        defer { NSEnableScreenUpdates() }
        let destinationGroupID = parkedGroups.first { $0.value.contains { $0 === destination } }?.key
        let incoming = destinationGroupID.flatMap { parkedGroups[$0] } ?? groupControllers(destination)
        var anchor = sourceWindow
        for member in incoming {
            guard let window = member.window else { continue }
            window.setFrame(sourceWindow.frame, display: false)
            if window.tabGroup !== sourceWindow.tabGroup {
                guard anchor.addTabbedWindowSafely(window, ordered: .above) else { return nil }
            }
            anchor = window
        }
        destination.prepareTabPresentation(from: sourceWindow)
        activate(destination, matching: sourceWindow, members: incoming)
        for member in outgoing {
            guard let window = member.window else { continue }
            window.tabGroup?.removeWindow(window)
            window.orderOut(nil)
        }
        destination.refreshWorkspaceTabs()
        selectedTabs[id] = destination.tabSessionID
        savePresentation()
        return destination
    }

    private func activate(_ target: TerminalController, matching source: NSWindow?, members explicitMembers: [TerminalController]? = nil) {
        guard let window = target.window else { return }
        let groupID = parkedGroups.first { $0.value.contains { $0 === target } }?.key
        let storedMembers = groupID.flatMap { parkedGroups.removeValue(forKey: $0) }
        let members = explicitMembers ?? storedMembers ?? groupControllers(target)
        if let anchor = members.first?.window {
            var previous = anchor
            for member in members.dropFirst() {
                if let memberWindow = member.window {
                    if memberWindow.tabGroup !== anchor.tabGroup {
                        _ = previous.addTabbedWindowSafely(memberWindow, ordered: .above)
                    }
                    previous = memberWindow
                }
            }
        }
        for member in members { parked.removeValue(forKey: member.tabSessionID) }
        if let source, !source.styleMask.contains(.fullScreen), !window.styleMask.contains(.fullScreen) {
            window.setFrame(source.frame, display: false)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        target.refreshWorkspaceTabs()
        if let surface = target.focusedSurface ?? target.surfaceTree.first, surface.window === window {
            window.makeFirstResponder(surface)
        }
    }

    @discardableResult
    func move(_ controller: TerminalController, to id: UUID) -> Bool {
        guard controller.workspaceID != id, store.workspaces.contains(where: { $0.id == id }),
              let window = controller.window, window.attachedSheet == nil else { return false }
        let originalID = controller.workspaceID
        let originalGroup = window.tabGroup
        let successor = originalGroup?.windows.first { $0 !== window }
        let target = controllers(in: id).first
        // Refuse unsupported native operations before touching ownership.
        guard window.tabbingMode != .disallowed,
              controller.fullscreenStyle?.supportsTabs != false else { return false }
        isSwitching = true
        defer { isSwitching = false }
        originalGroup?.removeWindow(window)
        if let anchor = target?.window,
           !anchor.addTabbedWindowSafely(window, ordered: .above) {
            if let successor { _ = successor.addTabbedWindowSafely(window, ordered: .above) }
            controller.refreshWorkspaceTabs()
            return false
        }
        controller.workspaceID = id
        store.assign(tab: controller.tabSessionID, to: id)
        controller.refreshWorkspaceTabs()
        if let successor {
            (successor.windowController as? TerminalController)?.refreshWorkspaceTabs()
            successor.makeKeyAndOrderFront(nil)
        }
        if target == nil || target.map({ parked[$0.tabSessionID] != nil }) == true {
            let groupID = target.flatMap { target in
                parkedGroups.first { $0.value.contains { $0 === target } }?.key
            } ?? controller.tabSessionID
            if parkedGroups[groupID] == nil { parkedGroups[groupID] = target.map { groupControllers($0) } ?? [] }
            if parkedGroups[groupID]?.contains(where: { $0 === controller }) != true {
                parkedGroups[groupID]?.append(controller)
            }
            parked[controller.tabSessionID] = controller
            window.orderOut(nil)
        }
        selectedTabs[id] = target?.tabSessionID ?? controller.tabSessionID
        if successor == nil {
            // Keep the source workspace reachable, even when moving its last tab.
            let replacement = TerminalController(controller.ghostty, tabLayout: controller.tabLayout, workspaceID: originalID)
            replacement.window?.setFrame(window.frame, display: false)
            replacement.window?.makeKeyAndOrderFront(nil)
            selectedTabs[originalID] = replacement.tabSessionID
        }
        savePresentation()
        return true
    }

    /// Called after AppKit's selection-restoration loop, so its late focus
    /// callbacks cannot expose every parked workspace at launch.
    func finishRestoring() {
        guard restoring else { return }
        let hidden = store.snapshot.hiddenTabs
        isSwitching = true
        let hiddenControllers = TerminalController.all.filter { hidden.contains($0.tabSessionID) }
        for (id, members) in store.snapshot.parkedGroups ?? [:] {
            parkedGroups[id] = members.compactMap { tabID in
                hiddenControllers.first { $0.tabSessionID == tabID }
            }
        }
        for controller in hiddenControllers where !parkedGroups.values.contains(where: { $0.contains { $0 === controller } }) {
            parkedGroups[controller.tabSessionID] = groupControllers(controller)
        }
        for controller in hiddenControllers {
            parked[controller.tabSessionID] = controller
            controller.window?.orderOut(nil)
        }
        isSwitching = false
        restoring = false
        revision &+= 1
    }

    func savePresentation() {
        store.rememberPresentation(
            hidden: Set(parked.keys), selected: selectedTabs,
            groups: parkedGroups.mapValues { $0.map(\.tabSessionID) }
        )
        revision &+= 1
        TerminalWorkspaceSessionStore.shared.capture()
    }

    private func groupControllers(_ controller: TerminalController) -> [TerminalController] {
        (controller.window?.tabGroup?.windows ?? [controller.window].compactMap { $0 }).compactMap {
            $0.windowController as? TerminalController
        }
    }
}
