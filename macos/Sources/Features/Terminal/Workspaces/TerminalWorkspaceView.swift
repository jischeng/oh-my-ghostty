import AppKit
import SwiftUI

struct TerminalWorkspaceButton: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject private var store: TerminalWorkspaceStore
    @State private var hovered = false

    init(controller: TerminalController) {
        self.controller = controller
        self.store = controller.workspaceCoordinator.store
    }

    var body: some View {
        let workspace = store.workspace(controller.workspaceID)
        Button { controller.workspaceSwitcherIsPresented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: workspace.symbol).foregroundStyle(workspace.tint)
                Text(workspace.name).fontWeight(.medium).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                if let activities = (NSApp.delegate as? AppDelegate)?.tabActivities {
                    WorkspaceAttentionDot(currentID: controller.workspaceID, activities: activities)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovered || controller.workspaceSwitcherIsPresented ? Color.primary.opacity(0.06) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(WorkspaceL10n.text("Switch workspace", "切换工作区") + " · " +
              (OMGKeyboardShortcut(storageValue: store.shortcut(slot: 0))?.displayValue ?? ""))
        .accessibilityLabel(WorkspaceL10n.text("Workspace: ", "工作区：") + workspace.name)
        .background(WorkspacePopoverAnchor(controller: controller))
    }
}

/// The controller owns both the native popover and its management session.
/// Closing the native window is an explicit boundary before fullscreen commands.
@MainActor
final class WorkspacePopoverPresentation: NSObject, NSPopoverDelegate {
    private weak var controller: TerminalController?
    private let popover = NSPopover()
    private weak var anchor: NSView?
    private var pendingAction: (() -> Void)?
    private var isClosing = false
    private var management: TerminalWorkspacePickerModel?
    private(set) var contentCreationCount = 0
    var isShown: Bool { popover.isShown }
    var contentView: NSView? { popover.contentViewController?.view }

    init(controller: TerminalController) {
        self.controller = controller
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func update(anchor: NSView) {
        self.anchor = anchor
        setPresented(controller?.workspaceSwitcherIsPresented == true)
    }

    func setPresented(_ presented: Bool) {
        guard presented else {
            if popover.isShown { popover.performClose(nil) }
            return
        }
        guard let controller, !popover.isShown, !isClosing, controller.isAvailableForWorkspace,
              !controller.workspacePresentationIsParked, let window = controller.window else { return }
        let source: NSView
        let rect: NSRect
        if let anchor, anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor,
           anchor.bounds.width > 0, anchor.bounds.height > 0 {
            source = anchor
            rect = anchor.bounds
        } else {
            guard let content = window.contentView else { return }
            source = content
            rect = NSRect(x: 12, y: content.isFlipped ? 0 : max(0, content.bounds.height - 1), width: 1, height: 1)
        }
        if management == nil {
            management = TerminalWorkspacePickerModel(controller: controller, dismiss: { [weak self] action in
                self?.close(after: action)
            }, reopen: { [weak controller] in controller?.workspaceSwitcherIsPresented = true })
        }
        guard let management else { return }
        popover.contentViewController = NSHostingController(rootView: TerminalWorkspacePicker(model: management))
        contentCreationCount += 1
        popover.show(relativeTo: rect, of: source, preferredEdge: .maxY)
    }

    func close(after action: (() -> Void)? = nil) {
        if let action { pendingAction = action }
        guard !isClosing else { return }
        if popover.isShown {
            isClosing = true
            popover.performClose(nil)
        } else {
            finishClosing()
        }
    }

    func popoverDidClose(_ notification: Notification) { finishClosing() }

    private func finishClosing() {
        isClosing = false
        let action = pendingAction
        pendingAction = nil
        controller?.workspaceSwitcherIsPresented = false
        popover.contentViewController = nil
        if let action {
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.controller, controller.isAvailableForWorkspace else { return }
                controller.window?.makeKeyAndOrderFront(nil)
                action()
            }
        } else if management?.isPerforming != true {
            management = nil
        }
    }
}

private struct WorkspacePopoverAnchor: NSViewRepresentable {
    let controller: TerminalController
    final class AnchorView: NSView {
        weak var controller: TerminalController?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { controller?.workspacePopover.update(anchor: self) }
        }
    }
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.controller = controller
        controller.workspacePopover.update(anchor: view)
    }
}

private struct WorkspaceAttentionDot: View {
    let currentID: UUID
    @ObservedObject var activities: TabActivityStore
    @ObservedObject private var coordinator = TerminalWorkspaceCoordinator.shared
    var body: some View {
        let needsAttention = coordinator.liveControllers.contains { controller in
            guard controller.workspaceID != currentID else { return false }
            return controller.surfaceTree.contains { surface in
                let state = activities.activity(for: surface.id)?.state
                return state == .needsAttention || state == .error
            } || activities.activity(for: controller.tabSessionID)?.state == .needsAttention
        }
        if needsAttention {
            Circle().fill(Color.orange.opacity(0.8)).frame(width: 5, height: 5)
                .help(WorkspaceL10n.text("Another workspace needs attention", "其他工作区有待处理事项"))
        }
    }
}

struct WorkspaceShortcutSettingsView: View {
    @ObservedObject private var store = TerminalWorkspaceStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkspaceL10n.text(
                "Switch workspaces without stopping running sessions. Shortcuts apply inside OMG and must include Command.",
                "切换工作区时保持会话运行。快捷键仅在 OMG 内生效，且必须包含 Command。"
            )).font(.caption).foregroundStyle(.secondary)
            ForEach(0...9, id: \.self) { slot in
                LabeledContent(slot == 0 ? WorkspaceL10n.text("Workspace switcher", "工作区切换器") :
                                WorkspaceL10n.text("Workspace \(slot)", "工作区 \(slot)")) {
                    HStack(spacing: 8) {
                        OMGShortcutRecorder(storageValue: Binding(
                            get: { store.shortcut(slot: slot) }, set: { store.setShortcut(slot: slot, value: $0) }
                        )).frame(width: 112, height: 24)
                        Button(WorkspaceL10n.text("Reset", "重置")) {
                            store.setShortcut(slot: slot, value: TerminalWorkspaceStore.defaultShortcut(slot: slot))
                        }
                    }
                }
                if let conflict = store.shortcutConflict(slot: slot) {
                    Label(WorkspaceL10n.text("Also used by: ", "同时用于：") + conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
