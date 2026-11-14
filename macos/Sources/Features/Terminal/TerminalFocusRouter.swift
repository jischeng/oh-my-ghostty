import AppKit
import Foundation
import GhosttyKit

extension Notification.Name {
    static let omgDockAttentionDidChange = Notification.Name("OMGDockAttentionDidChange")
}

struct DockBadgePolicy {
    static func isAttentionState(_ state: TabActivityState) -> Bool {
        state == .needsAttention || state == .error
    }

    static func badgeLabel(
        bellCount: Int,
        bellAttentionEnabled: Bool,
        unacknowledgedAttentionCount: Int
    ) -> String? {
        let effectiveBells = bellAttentionEnabled ? max(0, bellCount) : 0
        let total = effectiveBells + max(0, unacknowledgedAttentionCount)
        guard total > 0 else { return nil }
        return total > 99 ? "99+" : String(total)
    }
}

/// Unified host router for terminal presentation, notification clicks, palette
/// `Focus:` jumps, App Intents, and AppleScript focus commands, plus Dock-level
/// attention tracking across active and parked workspaces.
@MainActor
enum TerminalFocusRouter {
    private static var acknowledgedDockActivities: [UUID: TabActivity] = [:]

    static func allTerminalControllers(
        coordinator: TerminalWorkspaceCoordinator = .shared
    ) -> [TerminalController] {
        var seen = Set<ObjectIdentifier>()
        var result: [TerminalController] = []
        for controller in TerminalController.all + coordinator.liveControllers
        where seen.insert(ObjectIdentifier(controller)).inserted {
            result.append(controller)
        }
        return result
    }

    static func findSurface(
        forUUID uuid: UUID,
        coordinator: TerminalWorkspaceCoordinator = .shared,
        quickController: QuickTerminalController? = nil
    ) -> Ghostty.SurfaceView? {
        for controller in allTerminalControllers(coordinator: coordinator) {
            for view in controller.surfaceTree where view.id == uuid {
                return view
            }
        }
        let resolvedQuick = quickController ?? (NSApp.delegate as? AppDelegate)?.quickControllerIfInitialized
        if let resolvedQuick {
            for view in resolvedQuick.surfaceTree where view.id == uuid {
                return view
            }
        }
        return nil
    }

    static func controller(
        owning surface: Ghostty.SurfaceView,
        coordinator: TerminalWorkspaceCoordinator = .shared,
        quickController: QuickTerminalController? = nil
    ) -> BaseTerminalController? {
        if let direct = BaseTerminalController.controller(owning: surface) {
            return direct
        }
        for controller in allTerminalControllers(coordinator: coordinator) where controller.surfaceTree.contains(surface) {
            return controller
        }
        let resolvedQuick = quickController ?? (NSApp.delegate as? AppDelegate)?.quickControllerIfInitialized
        if let resolvedQuick, resolvedQuick.surfaceTree.contains(surface) {
            return resolvedQuick
        }
        return nil
    }

    @discardableResult
    static func focus(
        surface: Ghostty.SurfaceView,
        highlight: Bool = false,
        activateApp: Bool = true,
        acknowledgeCompletion: Bool = true,
        coordinator: TerminalWorkspaceCoordinator? = nil,
        quickController: QuickTerminalController? = nil
    ) -> Bool {
        guard let baseController = controller(
            owning: surface,
            coordinator: coordinator ?? .shared,
            quickController: quickController
        ) else {
            return false
        }

        if let quick = baseController as? QuickTerminalController {
            unzoomIfNeeded(in: quick, for: surface)
            hideCoveringEditor(in: quick, for: surface)
            quick.focusedSurface = surface
            quick.focusSurface(surface)
            if highlight {
                surface.highlight()
            }
            acknowledgeDockAttention(for: surface, in: quick)
            return true
        }

        if let terminalController = baseController as? TerminalController {
            let resolvedCoordinator = coordinator ?? terminalController.workspaceCoordinator
            _ = resolvedCoordinator.revealTab(terminalController)

            if let window = terminalController.window {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                if let tabGroup = window.tabGroup, tabGroup.selectedWindow !== window {
                    tabGroup.selectedWindow = window
                }
            }

            unzoomIfNeeded(in: terminalController, for: surface)
            hideCoveringEditor(in: terminalController, for: surface)

            terminalController.focusedSurface = surface
            terminalController.window?.makeKeyAndOrderFront(nil)
            if activateApp, !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            Ghostty.moveFocus(to: surface)
            if highlight {
                Ghostty.moveFocus(to: surface, delay: 0.1)
                surface.highlight()
            }
            if acknowledgeCompletion {
                terminalController.acknowledgeTerminalAgentState(for: surface)
            }
            acknowledgeDockAttention(for: surface, in: terminalController)
            return true
        }

        unzoomIfNeeded(in: baseController, for: surface)
        hideCoveringEditor(in: baseController, for: surface)
        baseController.focusedSurface = surface
        baseController.window?.makeKeyAndOrderFront(nil)
        if activateApp, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        Ghostty.moveFocus(to: surface)
        if highlight {
            Ghostty.moveFocus(to: surface, delay: 0.1)
            surface.highlight()
        }
        acknowledgeDockAttention(for: surface, in: baseController)
        return true
    }

    @discardableResult
    static func focus(
        tab controller: BaseTerminalController,
        activateApp: Bool = true,
        acknowledgeCompletion: Bool = false
    ) -> Bool {
        if let target = controller.focusedSurface ?? controller.surfaceTree.first,
           controller.surfaceTree.contains(target) {
            return focus(
                surface: target,
                activateApp: activateApp,
                acknowledgeCompletion: acknowledgeCompletion
            )
        }

        if let terminalController = controller as? TerminalController {
            _ = terminalController.workspaceCoordinator.revealTab(terminalController)
            guard let window = terminalController.window else { return false }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if let tabGroup = window.tabGroup, tabGroup.selectedWindow !== window {
                tabGroup.selectedWindow = window
            }
            window.makeKeyAndOrderFront(nil)
            if activateApp, !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            return true
        }

        if let quick = controller as? QuickTerminalController {
            if !quick.visible {
                quick.animateIn()
            } else {
                quick.window?.makeKeyAndOrderFront(nil)
            }
            return true
        }

        guard let window = controller.window else { return false }
        window.makeKeyAndOrderFront(nil)
        if activateApp, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private static func unzoomIfNeeded(
        in controller: BaseTerminalController,
        for targetSurface: Ghostty.SurfaceView
    ) {
        guard let zoomed = controller.surfaceTree.zoomed,
              zoomed.find(id: targetSurface.id) == nil else {
            return
        }
        controller.surfaceTree = SplitTree(root: controller.surfaceTree.root, zoomed: nil)
    }

    private static func hideCoveringEditor(
        in controller: BaseTerminalController,
        for targetSurface: Ghostty.SurfaceView
    ) {
        _ = controller.editorWorkspaceStore.hideIfCovering(surfaceID: targetSurface.id)
        if controller.editorWorkspaceStore !== EditorWorkspaceStore.shared {
            _ = EditorWorkspaceStore.shared.hideIfCovering(surfaceID: targetSurface.id)
        }
    }

    // MARK: - Dock Attention State

    static func acknowledgeDockAttention(
        for surface: Ghostty.SurfaceView,
        in controller: BaseTerminalController? = nil,
        tabActivities: TabActivityStore? = nil
    ) {
        let store = tabActivities ?? (NSApp.delegate as? AppDelegate)?.tabActivities
        let resolvedController = controller ?? self.controller(owning: surface)
        var didChange = false

        let surfaceActivity = (resolvedController as? TerminalController)?.agentActivity(for: surface)
            ?? store?.activity(for: surface.id)
        if let surfaceActivity, DockBadgePolicy.isAttentionState(surfaceActivity.state) {
            if acknowledgedDockActivities[surface.id] != surfaceActivity {
                acknowledgedDockActivities[surface.id] = surfaceActivity
                didChange = true
            }
        }

        if let terminalController = resolvedController as? TerminalController,
           let tabActivity = store?.activity(for: terminalController.tabSessionID),
           DockBadgePolicy.isAttentionState(tabActivity.state) {
            if acknowledgedDockActivities[terminalController.tabSessionID] != tabActivity {
                acknowledgedDockActivities[terminalController.tabSessionID] = tabActivity
                didChange = true
            }
        }

        if didChange {
            NotificationCenter.default.post(name: .omgDockAttentionDidChange, object: nil)
        }
    }

    static func notifyActivityMapChanged(previous: [UUID: TabActivity], current: [UUID: TabActivity]) {
        var needsUpdate = false
        let allIDs = Set(previous.keys).union(current.keys)
        for id in allIDs {
            let old = previous[id]
            let now = current[id]
            if let now, DockBadgePolicy.isAttentionState(now.state) {
                if acknowledgedDockActivities[id] != nil && acknowledgedDockActivities[id] != now {
                    acknowledgedDockActivities.removeValue(forKey: id)
                }
                if old != now {
                    needsUpdate = true
                }
            } else {
                if acknowledgedDockActivities.removeValue(forKey: id) != nil {
                    needsUpdate = true
                }
                if let old, DockBadgePolicy.isAttentionState(old.state) {
                    needsUpdate = true
                }
            }
        }
        if needsUpdate {
            NotificationCenter.default.post(name: .omgDockAttentionDidChange, object: nil)
        }
    }

    static func unacknowledgedAttentionCount(
        controllers: [TerminalController],
        tabActivities: TabActivityStore?
    ) -> Int {
        var activeAttentionByID: [UUID: TabActivity] = [:]
        for controller in controllers {
            var tabHasSurfaceAttention = false
            for surface in controller.surfaceTree {
                let activity = controller.agentActivity(for: surface)
                    ?? tabActivities?.activity(for: surface.id)
                if let activity, DockBadgePolicy.isAttentionState(activity.state) {
                    activeAttentionByID[surface.id] = activity
                    tabHasSurfaceAttention = true
                }
            }
            if !tabHasSurfaceAttention,
               let tabActivity = tabActivities?.activity(for: controller.tabSessionID),
               DockBadgePolicy.isAttentionState(tabActivity.state) {
                activeAttentionByID[controller.tabSessionID] = tabActivity
            }
        }

        var unacknowledged = 0
        for (id, activity) in activeAttentionByID where acknowledgedDockActivities[id] != activity {
            unacknowledged += 1
        }
        return unacknowledged
    }

    static func resetDockAcknowledgmentsForTesting() {
        acknowledgedDockActivities.removeAll()
    }
}
