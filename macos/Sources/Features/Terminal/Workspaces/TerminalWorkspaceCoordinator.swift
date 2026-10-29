import AppKit
import Combine

/// Native membership is transient during a workspace handoff. UI observers
/// publish only after the destination group and its selection are complete.
@MainActor
enum TerminalWorkspacePresentation {
    private static var depth = 0
    static var isChanging: Bool { depth > 0 }
    static func begin() { depth += 1 }
    static func end() { depth -= 1 }
}

/// Keeps native tab groups alive while parked. Switching never closes a window,
/// serializes a SurfaceView, or starts another copy of a running process.
@MainActor
final class TerminalWorkspaceCoordinator: ObservableObject {
    static let shared = TerminalWorkspaceCoordinator()
    @Published private(set) var revision = 0
    private(set) var parked: [UUID: TerminalController] = [:]
    private var parkedGroups: [UUID: [TerminalController]] = [:]
    private var isSwitching = false
    private var restoring = true
    private var quitting = false
    let store: TerminalWorkspaceStore
    private let sessions: TerminalWorkspaceSessionStore

    init(store: TerminalWorkspaceStore? = nil, sessions: TerminalWorkspaceSessionStore? = nil) {
        let store = store ?? .shared
        self.store = store
        self.sessions = sessions ?? .shared
    }

    func controllers(in id: UUID) -> [TerminalController] {
        TerminalController.all.filter { $0.workspaceID == id && $0.isAvailableForWorkspace }
    }

    func register(_ controller: TerminalController) {
        store.assign(tab: controller.tabSessionID, to: controller.workspaceID)
    }

    func previousWorkspaceID(in controller: TerminalController) -> UUID? {
        store.snapshot.windows?[controller.windowSessionID]?.previousWorkspace
    }

    /// Reconcile native tab joins/detaches at the adapter boundary. The host ID
    /// never depends on whichever tab AppKit currently selects.
    func reconcileNativeGroup(_ members: [TerminalController]) {
        guard !quitting, !TerminalWorkspacePresentation.isChanging, !members.isEmpty else { return }
        let native = members[0].window?.tabGroup
        let anchor = members.first { $0.tabLayoutState.nativeTabGroup === native } ?? members[0]
        if members.count == 1, anchor.workspaceTabAttachmentIsPending { return }
        var host = anchor.windowSessionID
        var group = anchor.workspaceGroupID
        let memberIDs = Set(members.map(\.tabSessionID))
        if let old = anchor.tabLayoutState.nativeTabGroup, old !== native,
           old.windows.contains(where: {
               guard let other = $0.windowController as? TerminalController else { return false }
               return other.isAvailableForWorkspace && !other.workspacePresentationIsParked &&
                   other.workspaceGroupID == group && !memberIDs.contains(other.tabSessionID)
           }) {
            // A detached native tab becomes an independent user-visible window.
            host = UUID()
            group = UUID()
        }
        for member in members {
            if member.windowSessionID != host || member.workspaceGroupID != group || member.workspaceID != anchor.workspaceID {
                store.removeTab(member.tabSessionID, window: member.windowSessionID, workspace: member.workspaceID)
                member.windowSessionID = host
                member.workspaceGroupID = group
                member.workspaceID = anchor.workspaceID
                store.assign(tab: member.tabSessionID, to: member.workspaceID)
                member.window?.tabbingIdentifier = "omg.window.\(host).workspace.\(member.workspaceID)"
            }
        }
        if !restoring && !quitting { rememberGroup(members) }
    }

    private func rememberGroup(_ members: [TerminalController], selected: UUID? = nil) {
        guard let first = members.first else { return }
        let ids = members.map(\.tabSessionID)
        let existing = store.group(window: first.windowSessionID, workspace: first.workspaceID)
        let nativeSelection = (first.window?.tabGroup?.selectedWindow?.windowController as? TerminalController)?.tabSessionID
        let chosen = [selected, nativeSelection, existing?.selected].compactMap { $0 }.first { ids.contains($0) } ?? ids.first
        store.rememberGroup(window: first.windowSessionID, workspace: first.workspaceID,
            group: .init(id: first.workspaceGroupID, tabs: ids, selected: chosen,
                         scrollOffset: first.tabLayoutState.sidebarHost.scrollOffset ?? existing?.scrollOffset))
    }

    private func select(_ controller: TerminalController) {
        store.selectWorkspace(controller.workspaceID, in: controller.windowSessionID,
            frame: controller.window?.frame, fullscreen: controller.window?.styleMask.contains(.fullScreen))
    }

    func didActivate(_ controller: TerminalController) {
        guard !isSwitching, !restoring, !quitting, controller.isAvailableForWorkspace,
              controller.window?.isVisible == true else { return }
        // Ignore late activation notifications from a window just parked by a
        // handoff. Window-menu/Dock activation makes it visible before this call.
        // A native Window menu or Dock activation must restore the entire
        // parked group, rather than expose one detached tab in isolation.
        if parked[controller.tabSessionID] != nil {
            if let current = TerminalController.all.first(where: {
                $0.windowSessionID == controller.windowSessionID && $0.workspaceID != controller.workspaceID &&
                    $0.isAvailableForWorkspace && !$0.workspacePresentationIsParked
            }) {
                _ = switchWorkspace(to: controller.workspaceID, from: current)
                return
            }
            isSwitching = true
            activate(controller, matching: nil)
            isSwitching = false
        }
        let members = groupControllers(controller)
        reconcileNativeGroup(members)
        rememberGroup(members, selected: controller.tabSessionID)
        select(controller)
        savePresentation()
    }

    func didClose(_ controller: TerminalController) {
        guard !quitting else { return }
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
              source.isAvailableForWorkspace, source.window?.attachedSheet == nil else { return nil }
        source.workspaceSwitcherIsPresented = false
        if source.workspaceID == id { return source }
        let host = source.windowSessionID
        let candidates = controllers(in: id).filter { $0.windowSessionID == host }
        let selected = store.group(window: host, workspace: id)?.selected
        let target = candidates.first { $0.tabSessionID == selected } ?? candidates.first
        isSwitching = true
        TerminalWorkspacePresentation.begin()
        NSDisableScreenUpdates()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var animationBehaviors: [(NSWindow, NSWindow.AnimationBehavior)] = []
        var presented = source
        defer {
            let scrollOffset = store.group(window: host, workspace: presented.workspaceID)?.scrollOffset
            presented.tabLayoutState.sidebarHost.restoreScrollOffset(scrollOffset)
            TerminalWorkspacePresentation.end()
            presented.window?.tabGroup?.setGhosttyTerminalShellLayoutState(presented.tabLayoutState)
            presented.refreshWorkspaceTabs()
            presented.tabLayoutState.sidebarHost.presentSelectedWindow(updateContent: true)
            presented.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            presented.tabLayoutState.sidebarHost.restoreScrollOffset(scrollOffset)
            presented.prepareWorkspaceFrame()
            presented.window?.contentView?.displayIfNeeded()
            CATransaction.commit()
            NSAnimationContext.endGrouping()
            for (window, behavior) in animationBehaviors { window.animationBehavior = behavior }
            NSEnableScreenUpdates()
            isSwitching = false
            sessions.capture()
            presented.finishWorkspacePresentation()
        }
        // Capture membership before creating a window: AppKit can auto-tab
        // it during initialization in a fullscreen Space.
        let outgoing = groupControllers(source)
        rememberGroup(outgoing, selected: source.tabSessionID)
        select(source)
        let destination: TerminalController
        let restored = target == nil ? sessions.restoreWorkspace(id, window: host,
            group: store.group(window: host, workspace: id)?.id, app: source.ghostty, parent: source.window) : []
        if let target {
            destination = target
        } else if let selectedController = restored.first(where: { $0.tabSessionID == selected }) ?? restored.first {
            destination = selectedController
        } else {
            destination = TerminalController(source.ghostty, parent: source.window, tabLayout: source.tabLayout,
                workspaceID: id, windowSessionID: host, workspaceGroupID: store.group(window: host, workspace: id)?.id)
            destination.isBackgroundOpaque = source.isBackgroundOpaque
            // Explicit workspace switches must also work with an isolated
            // catalog, rather than falling back through the shared default ID.
            destination.workspaceID = id
            guard destination.window != nil else { return nil }
        }
        guard let sourceWindow = source.window, destination.window != nil else { return nil }
        // Keep separate hosts/scroll state for each workspace, even when a new
        // destination initially inherited the source's native parent geometry.
        if destination.tabLayoutState === source.tabLayoutState {
            destination.tabLayoutState = source.tabLayoutState.detachedCopy()
        }
        destination.tabLayoutState.bindWorkspace(id)
        for member in outgoing { member.cancelWorkspacePendingPresentation() }
        // Keep the native fullscreen container alive across the handoff. The
        // incoming tab joins it before any outgoing tab is detached.
        let destinationGroupID = destination.workspaceGroupID
        let incoming = (parkedGroups[destinationGroupID] ??
            (restored.isEmpty ? groupControllers(destination) : restored)).filter {
                $0.workspaceID == id && $0.windowSessionID == host && $0.isAvailableForWorkspace
            }
        for member in outgoing + incoming {
            guard let window = member.window else { continue }
            animationBehaviors.append((window, window.animationBehavior))
            window.animationBehavior = .none
        }
        var completed = false
        defer {
            if !completed {
                for member in incoming where !outgoing.contains(where: { $0 === member }) {
                    guard let window = member.window else { continue }
                    window.tabGroup?.removeWindow(window)
                    window.orderOut(nil)
                    parked[member.tabSessionID] = member
                    member.workspacePresentationIsParked = true
                }
                parkedGroups[destinationGroupID] = incoming
                sourceWindow.makeKeyAndOrderFront(nil)
                source.refreshWorkspaceTabs()
                savePresentation()
            }
        }
        var anchor = sourceWindow
        for member in incoming {
            guard let window = member.window else { continue }
            if !window.styleMask.contains(.fullScreen) {
                window.setFrame(sourceWindow.frame, display: false)
            }
            if sourceWindow.tabGroup?.windows.contains(window) != true {
                guard anchor.addTabbedWindowSafely(window, ordered: .above) else { return nil }
            }
            member.finishWorkspaceTabAttachment()
            anchor = window
        }
        // AppKit must establish the incoming tab's fullscreen geometry before
        // the outgoing windows are detached from its native stack.
        let shown = destination.withNewTabPresentation(from: sourceWindow) {
            destination.showWindowSafely(nil)
        }
        guard shown else { return nil }
        activate(destination, matching: sourceWindow, members: incoming)
        parkedGroups[source.workspaceGroupID] = outgoing
        for member in outgoing {
            parked[member.tabSessionID] = member
            member.workspacePresentationIsParked = true
            guard let window = member.window else { continue }
            window.tabGroup?.removeWindow(window)
            window.orderOut(nil)
        }
        // Removing the outgoing fullscreen tabs can change AppKit's selected
        // window and responder after the initial show. Commit selection only
        // after the native group has its final membership.
        destination.window?.tabGroup?.selectedWindow = destination.window
        destination.window?.makeKeyAndOrderFront(nil)
        destination.refreshWorkspaceTabs()
        completed = true
        presented = destination
        rememberGroup(incoming, selected: destination.tabSessionID)
        select(destination)
        savePresentation()
        return destination
    }

    private func activate(_ target: TerminalController, matching source: NSWindow?, members explicitMembers: [TerminalController]? = nil) {
        guard target.isAvailableForWorkspace, let window = target.window else { return }
        let storedMembers = parkedGroups.removeValue(forKey: target.workspaceGroupID)
        let members = (explicitMembers ?? storedMembers ?? groupControllers(target)).filter(\.isAvailableForWorkspace)
        if let anchor = members.first?.window {
            var previous = anchor
            for member in members.dropFirst() {
                if let memberWindow = member.window {
                    if anchor.tabGroup?.windows.contains(memberWindow) != true {
                        _ = previous.addTabbedWindowSafely(memberWindow, ordered: .above)
                    }
                    previous = memberWindow
                }
            }
        }
        for member in members {
            member.finishWorkspaceTabAttachment()
            parked.removeValue(forKey: member.tabSessionID)
            member.workspacePresentationIsParked = false
        }
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
    func deleteWorkspace(_ id: UUID) -> Bool {
        guard id != store.defaultID, !isSwitching, !quitting else { return false }
        let fallback = store.defaultID
        let affected = controllers(in: id)
        let visibleHosts = Set(affected.filter { !$0.workspacePresentationIsParked }.map(\.windowSessionID))
        guard affected.allSatisfy({ $0.window?.attachedSheet == nil }) else { return false }
        // Move live tabs through the existing lifecycle path; no PTY is closed.
        for controller in affected {
            guard move(controller, to: fallback, replacingLastTab: false) else { return false }
        }
        guard store.delete(id: id) else { return false }
        sessions.reassignWorkspace(id, to: fallback)
        for host in visibleHosts {
            if let controller = affected.first(where: { $0.windowSessionID == host }) {
                activate(controller, matching: nil)
                select(controller)
            }
        }
        savePresentation()
        return true
    }

    @discardableResult
    func move(_ controller: TerminalController, to id: UUID, replacingLastTab: Bool = true) -> Bool {
        guard !isSwitching, controller.isAvailableForWorkspace, controller.workspaceID != id,
              store.workspaces.contains(where: { $0.id == id }),
              let window = controller.window, window.attachedSheet == nil,
              window.tabbingMode != .disallowed, controller.fullscreenStyle?.supportsTabs != false else { return false }
        let originalID = controller.workspaceID
        let host = controller.windowSessionID
        let oldGroupID = controller.workspaceGroupID
        let outgoing = groupControllers(controller)
        rememberGroup(outgoing, selected: controller.tabSessionID)
        let originalGroup = window.tabGroup
        let successor = outgoing.first { $0 !== controller }
        let candidates = controllers(in: id).filter { $0.windowSessionID == host }
        let stored = store.group(window: host, workspace: id)
        isSwitching = true
        TerminalWorkspacePresentation.begin()
        NSDisableScreenUpdates()
        var presented = successor ?? controller
        defer {
            TerminalWorkspacePresentation.end()
            presented.window?.tabGroup?.setGhosttyTerminalShellLayoutState(presented.tabLayoutState)
            presented.refreshWorkspaceTabs()
            NSEnableScreenUpdates()
            isSwitching = false
            savePresentation()
        }
        let restored = candidates.isEmpty ? sessions.restoreWorkspace(id, window: host, group: stored?.id,
            app: controller.ghostty, parent: window) : []
        let target = (candidates + restored).first { $0.tabSessionID == stored?.selected }
            ?? candidates.first ?? restored.first
        var incoming = target.flatMap { parkedGroups[$0.workspaceGroupID] } ??
            (restored.isEmpty ? target.map { groupControllers($0) } ?? [] : restored)
        controller.cancelWorkspacePendingPresentation()
        originalGroup?.removeWindow(window)
        if let anchor = target?.window, !anchor.addTabbedWindowSafely(window, ordered: .above) {
            if let successor = successor?.window { _ = successor.addTabbedWindowSafely(window, ordered: .above) }
            return false
        }
        store.removeTab(controller.tabSessionID, window: host, workspace: originalID)
        controller.workspaceID = id
        controller.workspaceGroupID = target?.workspaceGroupID ?? stored?.id ?? UUID()
        controller.tabLayoutState = target?.tabLayoutState ?? controller.tabLayoutState.detachedCopy()
        controller.tabLayoutState.bindWorkspace(id)
        store.assign(tab: controller.tabSessionID, to: id)
        incoming.append(controller)
        parkedGroups[controller.workspaceGroupID] = incoming
        rememberGroup(incoming, selected: target?.tabSessionID ?? controller.tabSessionID)
        for member in incoming {
            member.workspacePresentationIsParked = true
            parked[member.tabSessionID] = member
            member.window?.orderOut(nil)
        }
        if let successor {
            rememberGroup(outgoing.filter { $0 !== controller }, selected: successor.tabSessionID)
            successor.window?.makeKeyAndOrderFront(nil)
            select(successor)
        } else if replacingLastTab {
            let replacement = TerminalController(controller.ghostty, tabLayout: controller.tabLayout,
                workspaceID: originalID, windowSessionID: host, workspaceGroupID: oldGroupID)
            replacement.workspaceID = originalID
            replacement.window?.setFrame(window.frame, display: false)
            replacement.window?.makeKeyAndOrderFront(nil)
            rememberGroup([replacement], selected: replacement.tabSessionID)
            select(replacement)
            presented = replacement
        }
        return true
    }

    /// Called after AppKit's selection-restoration loop, so its late focus
    /// callbacks cannot expose every parked workspace at launch.
    func finishRestoring() {
        guard restoring else { return }
        let hidden = store.snapshot.hiddenTabs
        isSwitching = true
        let hiddenControllers = TerminalController.all.filter {
            guard $0.isAvailableForWorkspace else { return false }
            if let record = store.snapshot.windows?[$0.windowSessionID] {
                return record.currentWorkspace != $0.workspaceID
            }
            return hidden.contains($0.tabSessionID)
        }
        for controller in hiddenControllers {
            let group = store.group(window: controller.windowSessionID, workspace: controller.workspaceID)
            let ids = group?.tabs ?? store.snapshot.parkedGroups?.values.first { $0.contains(controller.tabSessionID) } ?? []
            parkedGroups[controller.workspaceGroupID] = ids.compactMap { tabID in
                hiddenControllers.first { $0.tabSessionID == tabID }
            }
        }
        for controller in hiddenControllers where !parkedGroups.values.contains(where: { $0.contains { $0 === controller } }) {
            parkedGroups[controller.workspaceGroupID] = groupControllers(controller)
        }
        for controller in hiddenControllers {
            parked[controller.tabSessionID] = controller
            controller.workspacePresentationIsParked = true
            controller.window?.orderOut(nil)
        }
        isSwitching = false
        restoring = false
        revision &+= 1
        ensureVisibleWorkspace()
    }

    func ensureVisibleWorkspace() {
        guard !quitting, !isSwitching else { return }
        let controllers = TerminalController.all.filter(\.isAvailableForWorkspace)
        guard !controllers.contains(where: { $0.window?.isVisible == true }),
              let target = controllers.first else { return }
        isSwitching = true
        activate(target, matching: nil)
        isSwitching = false
        savePresentation()
    }

    func prepareToQuit() {
        guard !quitting else { return }
        savePresentation()
        quitting = true
    }

    func cancelQuit() {
        quitting = false
        savePresentation()
    }

    func savePresentation() {
        guard !quitting, !restoring else { return }
        store.rememberPresentation(
            hidden: Set(parked.keys), selected: [:],
            groups: parkedGroups.mapValues { $0.map(\.tabSessionID) }
        )
        revision &+= 1
        sessions.capture()
    }

    private func groupControllers(_ controller: TerminalController) -> [TerminalController] {
        (controller.window?.tabGroup?.windows ?? [controller.window].compactMap { $0 }).compactMap {
            $0.windowController as? TerminalController
        }.filter(\.isAvailableForWorkspace)
    }
}
