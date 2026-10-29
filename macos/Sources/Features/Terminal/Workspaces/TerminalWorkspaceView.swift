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
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
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

/// The native controller owns the popover, not the frequently replaced sidebar
/// root view. Re-rendering the button must not dismiss or recreate its editor.
@MainActor
final class WorkspacePopoverPresentation: NSObject, NSPopoverDelegate {
    private weak var controller: TerminalController?
    private let popover = NSPopover()
    private var pendingAction: (() -> Void)?
    private(set) var contentCreationCount = 0
    var isShown: Bool { popover.isShown }

    init(controller: TerminalController) {
        self.controller = controller
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func update(anchor: NSView) {
        guard let controller else { return }
        guard controller.workspaceSwitcherIsPresented else {
            if popover.isShown { popover.performClose(nil) }
            return
        }
        guard !popover.isShown, anchor.window === controller.window,
              controller.isAvailableForWorkspace, !controller.workspacePresentationIsParked else { return }
        let content = TerminalWorkspacePicker(controller: controller) { [weak self] action in
            self?.close(after: action)
        }
        popover.contentViewController = NSHostingController(rootView: content)
        contentCreationCount += 1
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func close(after action: (() -> Void)? = nil) {
        pendingAction = action
        if popover.isShown {
            popover.performClose(nil)
        } else {
            finishClosing()
        }
    }

    func popoverDidClose(_ notification: Notification) { finishClosing() }

    private func finishClosing() {
        controller?.workspaceSwitcherIsPresented = false
        popover.contentViewController = nil
        let action = pendingAction
        pendingAction = nil
        // The native close notification is the boundary, not SwiftUI teardown.
        if let action { DispatchQueue.main.async(execute: action) }
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
        let needsAttention = TerminalController.all.contains { controller in
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

struct TerminalWorkspacePicker: View {
    @ObservedObject var controller: TerminalController
    var afterDismiss: (@escaping () -> Void) -> Void = { action in DispatchQueue.main.async(execute: action) }
    @ObservedObject private var store: TerminalWorkspaceStore
    @ObservedObject private var coordinator: TerminalWorkspaceCoordinator

    init(controller: TerminalController,
         afterDismiss: @escaping (@escaping () -> Void) -> Void = { action in DispatchQueue.main.async(execute: action) }) {
        self.controller = controller
        self.afterDismiss = afterDismiss
        self.coordinator = controller.workspaceCoordinator
        self.store = controller.workspaceCoordinator.store
    }

    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var editing = false
    @State private var creating = false
    @State private var name = ""
    @State private var symbol = "house"
    @State private var color = "sage"
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool
    @State private var deleting = false

    private var filtered: [TerminalWorkspace] {
        store.workspaces.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 5) {
            if editing {
                editor
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(WorkspaceL10n.text("Search workspaces…", "搜索工作区…"), text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { activateSelected() }
                        .onMoveCommand { direction in
                            if direction == .up { step(-1) }
                            if direction == .down { step(1) }
                        }
                }
                .padding(9)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filtered) { workspace in row(workspace) }
                        if filtered.isEmpty {
                            Text(WorkspaceL10n.text("No matching workspaces", "没有匹配的工作区"))
                                .foregroundStyle(.secondary).padding()
                        }
                    }
                }
                .frame(height: min(330, CGFloat(max(1, filtered.count)) * 53))
                Divider().padding(.horizontal, 6)
                action("plus", WorkspaceL10n.text("New Workspace…", "新建工作区…")) { beginEditing(create: true) }
                action("pencil", WorkspaceL10n.text("Edit Current Workspace…", "编辑当前工作区…")) {
                    beginEditing(create: false)
                }
                action("trash", WorkspaceL10n.text("Delete Current Workspace…", "删除当前工作区…")) {
                    deleting = true
                }.disabled(controller.workspaceID == store.defaultID)
                Menu {
                    ForEach(store.workspaces.filter { $0.id != controller.workspaceID }) { workspace in
                        Button(workspace.name) {
                            afterDismiss {
                                if !coordinator.move(controller, to: workspace.id) { NSSound.beep() }
                            }
                        }
                    }
                } label: {
                    Label(WorkspaceL10n.text("Move Current Tab to", "移动当前标签到"), systemImage: "arrow.right.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .disabled(store.workspaces.count < 2)
                if let error = store.saveError {
                    Text(WorkspaceL10n.text("Could not save workspaces: ", "无法保存工作区：") + error)
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
                if let error = coordinator.operationError {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(8)
                }
                Text(WorkspaceL10n.text("↑ ↓ Choose · ↵ Switch · esc Cancel", "↑ ↓ 选择 · ↵ 切换 · esc 取消"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(7)
            }
        }
        .padding(7)
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            selectedID = coordinator.previousWorkspaceID(in: controller) ?? controller.workspaceID
            searchFocused = true
        }
        .alert(WorkspaceL10n.text("Delete workspace?", "删除工作区？"), isPresented: $deleting) {
            Button(WorkspaceL10n.text("Delete", "删除"), role: .destructive) {
                let id = controller.workspaceID
                afterDismiss { if !coordinator.deleteWorkspace(id) { NSSound.beep() } }
            }
            Button(WorkspaceL10n.text("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(WorkspaceL10n.text("Tabs and running sessions will move to Personal. They will not be closed.",
                                   "标签和运行中的会话将移至默认工作区，不会关闭。"))
        }
        .onChange(of: query) { _ in selectedID = filtered.first?.id }
        .onExitCommand {
            if editing { editing = false; searchFocused = true } else {
                controller.workspaceSwitcherIsPresented = false
            }
        }
    }

    private func row(_ workspace: TerminalWorkspace) -> some View {
        let slot = (store.workspaces.firstIndex { $0.id == workspace.id } ?? 0) + 1
        return Button {
            afterDismiss { coordinator.switchWorkspace(to: workspace.id, from: controller) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: workspace.symbol)
                    .foregroundStyle(workspace.tint)
                    .frame(width: 28, height: 28)
                    .background(workspace.tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(summary(workspace.id)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if workspace.id == controller.workspaceID {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if slot <= 9 {
                    Text(OMGKeyboardShortcut(storageValue: store.shortcut(slot: slot))?.displayValue ?? "")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(selectedID == workspace.id ? Color.primary.opacity(0.07) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selectedID = workspace.id } }
    }

    private func summary(_ id: UUID) -> String {
        let tabs = coordinator.controllers(in: id)
        let count = tabs.count
        let activities = tabs.compactMap { $0.focusedAgentActivity()?.state }
        let attention = activities.filter { $0 == .needsAttention || $0 == .error }.count
        let working = activities.filter { $0 == .working }.count
        var text = WorkspaceL10n.text("\(count) tabs", "\(count) 个标签")
        if attention > 0 {
            text += WorkspaceL10n.text(" · \(attention) need attention", " · \(attention) 待处理")
        } else if working > 0 {
            text += WorkspaceL10n.text(" · \(working) running", " · \(working) 运行中")
        }
        return text
    }

    private func action(_ icon: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
        }.buttonStyle(WorkspaceHoverButtonStyle())
    }

    private func step(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selectedID } ?? 0
        selectedID = filtered[(index + delta + filtered.count) % filtered.count].id
    }

    private func activateSelected() {
        guard let id = selectedID, filtered.contains(where: { $0.id == id }) else { return }
        afterDismiss { coordinator.switchWorkspace(to: id, from: controller) }
    }

    private func beginEditing(create: Bool) {
        creating = create
        let workspace = store.workspace(controller.workspaceID)
        name = create ? "" : workspace.name
        symbol = create ? "briefcase" : workspace.symbol
        color = create ? "blue" : workspace.color
        editing = true
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(creating ? WorkspaceL10n.text("New Workspace", "新建工作区") :
                    WorkspaceL10n.text("Edit Workspace", "编辑工作区")).font(.headline)
            TextField(WorkspaceL10n.text("Name", "名称"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onAppear { DispatchQueue.main.async { nameFocused = true } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(TerminalWorkspace.symbols, id: \.self) { item in
                    Button { symbol = item } label: {
                        Image(systemName: item).frame(width: 29, height: 28)
                            .background(symbol == item ? Color.primary.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityLabel(item)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(TerminalWorkspace.colors, id: \.self) { item in
                    Button { color = item } label: {
                        Circle().fill(TerminalWorkspace(id: UUID(), name: "", symbol: symbol, color: item).tint)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(color == item ? Color.primary : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel(item)
                }
            }
            HStack {
                Button(WorkspaceL10n.text("Cancel", "取消")) { editing = false; searchFocused = true }
                Spacer()
                Button(WorkspaceL10n.text("Save", "保存")) { saveEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 40)
            }
        }.padding(10)
    }

    private func saveEditor() {
        if creating {
            if let id = store.create(name: name, symbol: symbol, color: color) {
                afterDismiss { coordinator.switchWorkspace(to: id, from: controller) }
            }
        } else {
            store.update(id: controller.workspaceID, name: name, symbol: symbol, color: color)
            editing = false
            searchFocused = true
        }
    }
}

private struct WorkspaceHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
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
                            get: { store.shortcut(slot: slot) },
                            set: { store.setShortcut(slot: slot, value: $0) }
                        )).frame(width: 112, height: 24)
                        Button(WorkspaceL10n.text("Reset", "重置")) {
                            store.setShortcut(slot: slot, value: TerminalWorkspaceStore.defaultShortcut(slot: slot))
                        }
                    }
                }
                if let conflict = store.shortcutConflict(slot: slot) {
                    Label(WorkspaceL10n.text("Also used by: ", "同时用于：") + conflict,
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
