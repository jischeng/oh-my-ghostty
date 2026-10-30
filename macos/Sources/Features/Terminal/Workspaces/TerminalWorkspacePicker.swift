import AppKit
import SwiftUI

struct TerminalWorkspacePicker: View {
    @ObservedObject var model: TerminalWorkspacePickerModel
    @ObservedObject private var store: TerminalWorkspaceStore
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool

    init(model: TerminalWorkspacePickerModel) {
        self.model = model
        self.store = model.store
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.page {
            case .switcher, .move: workspaceList
            case .create, .edit: editor
            case .delete(let id): deletion(id)
            }
            if let error = model.error ?? store.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .accessibilityIdentifier("workspace.error")
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            }
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.isPerforming)
        .onAppear { focusPage() }
        .onChange(of: model.page) { _ in focusPage() }
        .onChange(of: model.query) { _ in model.selectedID = model.filtered.first?.id }
        .onExitCommand { model.cancel() }
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.page != .switcher {
                Button { model.back() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help(WorkspaceL10n.text("Back", "返回"))
                    .accessibilityIdentifier("workspace.back")
            }
            Text(pageTitle).font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.page == .switcher {
                Button { model.beginCreate() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        Text(WorkspaceL10n.text("New", "新建")).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9).frame(height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(WorkspaceCreateButtonStyle()).disabled(!model.canCreate)
                .help(WorkspaceL10n.text("Create a workspace", "创建工作区"))
                .accessibilityIdentifier("workspace.create")
            }
        }
        .padding(.horizontal, 12).frame(height: 42)
    }

    private var pageTitle: String {
        switch model.page {
        case .switcher: WorkspaceL10n.text("Workspaces", "工作区")
        case .create: WorkspaceL10n.text("New Workspace", "新建工作区")
        case .edit: WorkspaceL10n.text("Edit Workspace", "编辑工作区")
        case .move: WorkspaceL10n.text("Move Tab", "移动标签")
        case .delete: WorkspaceL10n.text("Delete Workspace", "删除工作区")
        }
    }

    private var workspaceList: some View {
        VStack(spacing: 0) {
            if model.page == .move {
                Text(WorkspaceL10n.text("Move “\(model.movingTabTitle)” to…", "将“\(model.movingTabTitle)”移动到…"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(WorkspaceL10n.text("Search workspaces", "搜索工作区"), text: $model.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("workspace.search")
                    .onSubmit { model.activateSelected() }
                    .onMoveCommand { direction in
                        if direction == .up { model.step(-1) }
                        if direction == .down { model.step(1) }
                    }
            }.padding(10)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.filtered) { workspace in row(workspace).id(workspace.id) }
                        if model.filtered.isEmpty {
                            Text(WorkspaceL10n.text("No matching workspaces", "没有匹配的工作区"))
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
                        }
                    }.padding(.horizontal, 7).padding(.bottom, 7)
                }
                .frame(height: min(310, CGFloat(max(1, model.filtered.count)) * 51 + 7))
                .onChange(of: model.selectedID) { id in if let id { scroll.scrollTo(id) } }
            }
            if model.page == .switcher {
                Divider()
                Button { model.beginMove() } label: {
                    HStack {
                        Label(WorkspaceL10n.text("Move current tab…", "移动当前标签…"), systemImage: "arrow.right.square")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }.font(.system(size: 12)).padding(12).contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceHoverButtonStyle()).disabled(store.workspaces.count < 2)
                .accessibilityIdentifier("workspace.move")
            }
            Text(WorkspaceL10n.text("↑ ↓ Choose  ·  Return Confirm  ·  Esc Back", "↑ ↓ 选择  ·  回车确认  ·  Esc 返回"))
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 10).padding(.top, 6)
        }
    }

    private func row(_ workspace: TerminalWorkspace) -> some View {
        let moving = model.page == .move
        let current = workspace.id == model.currentID
        return HStack(spacing: 0) {
            Button { model.activate(workspace.id) } label: {
                HStack(spacing: 9) {
                    workspaceIcon(workspace, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        let count = model.tabCount(workspace.id)
                        Text(count == 0 ? WorkspaceL10n.text("Not open in this window", "当前窗口未打开") :
                            WorkspaceL10n.text("\(count) tabs in this window", "当前窗口 · \(count) 个标签"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if current {
                        Text(WorkspaceL10n.text("Current", "当前")).font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if moving {
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !moving, let index = store.workspaces.firstIndex(where: { $0.id == workspace.id }), index < 9 {
                        Text(OMGKeyboardShortcut(storageValue: store.shortcut(slot: index + 1))?.displayValue ?? "")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }.padding(.leading, 9).padding(.vertical, 7).padding(.trailing, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("workspace.open.\(workspace.id)")
            if !moving {
                HStack(spacing: 2) {
                    WorkspaceRowAction(symbol: "pencil", title: WorkspaceL10n.text("Edit \(workspace.name)", "编辑 \(workspace.name)")) {
                        model.beginEdit(workspace.id)
                    }.accessibilityIdentifier("workspace.edit.\(workspace.id)")
                    WorkspaceRowAction(symbol: "trash", title: WorkspaceL10n.text("Delete \(workspace.name)", "删除 \(workspace.name)"), destructive: true) {
                        model.beginDelete(workspace.id)
                    }.disabled(workspace.id == store.defaultID)
                        .accessibilityIdentifier("workspace.delete.\(workspace.id)")
                }.padding(.trailing, 5)
            }
        }
        .background(model.selectedID == workspace.id ? Color.primary.opacity(0.07) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { if $0 { model.selectedID = workspace.id } }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                workspaceIcon(.init(id: UUID(), name: model.name, symbol: model.symbol, color: model.color), size: 38)
                TextField(WorkspaceL10n.text("Workspace name", "工作区名称"), text: $model.name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityIdentifier("workspace.name").onSubmit { model.save() }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(WorkspaceL10n.text("Icon", "图标")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8), spacing: 5) {
                    ForEach(TerminalWorkspace.symbols, id: \.self) { symbol in
                        Button { model.symbol = symbol } label: {
                            Image(systemName: symbol).frame(width: 30, height: 28)
                                .background(model.symbol == symbol ? Color.primary.opacity(0.12) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel(symbol)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(WorkspaceL10n.text("Color", "颜色")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                    ForEach(TerminalWorkspace.colors, id: \.self) { color in
                        Button { model.color = color } label: {
                            Circle().fill(TerminalWorkspace(id: UUID(), name: "", symbol: model.symbol, color: color).tint)
                                .frame(width: 22, height: 22)
                                .overlay { if model.color == color { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).accessibilityLabel(color)
                    }
                }
            }
            if model.name.count > 40 {
                Text(WorkspaceL10n.text("Use 40 characters or fewer.", "名称最多 40 个字符。")).font(.caption).foregroundStyle(.orange)
            } else if model.duplicateName {
                Text(WorkspaceL10n.text("Another workspace uses this name. A distinct name is easier to recognize.",
                    "已有同名工作区，使用不同名称更容易区分。")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(WorkspaceL10n.text("Cancel", "取消")) { model.back() }
                Spacer()
                Button(model.page == .create ? WorkspaceL10n.text("Create & Open", "创建并打开") : WorkspaceL10n.text("Save", "保存")) {
                    model.save()
                }.keyboardShortcut(.defaultAction).disabled(!model.validName)
                    .accessibilityIdentifier("workspace.save")
            }
        }.padding(14)
    }

    private func deletion(_ id: UUID) -> some View {
        let workspace = store.workspace(id)
        let fallback = store.workspace(store.defaultID)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                workspaceIcon(workspace, size: 36)
                Text(WorkspaceL10n.text("Delete “\(workspace.name)” ?", "删除“\(workspace.name)”？")).font(.headline)
            }
            Text(WorkspaceL10n.text(
                "Its \(model.tabCount(id, allWindows: true)) tabs will move to “\(fallback.name)” in their own windows. Running sessions will stay open.",
                "其中的 \(model.tabCount(id, allWindows: true)) 个标签将移至各自窗口的“\(fallback.name)”。运行中的会话会保留。"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(WorkspaceL10n.text("Cancel", "取消")) { model.back() }
                Spacer()
                Button(WorkspaceL10n.text("Delete Workspace", "删除工作区"), role: .destructive) { model.confirmDelete() }
                    .accessibilityIdentifier("workspace.confirm-delete")
            }
        }.padding(14)
    }

    private func workspaceIcon(_ workspace: TerminalWorkspace, size: CGFloat) -> some View {
        Image(systemName: workspace.symbol).foregroundStyle(workspace.tint)
            .frame(width: size, height: size).background(workspace.tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func focusPage() {
        switch model.page {
        case .create, .edit: nameFocused = true
        case .switcher, .move: searchFocused = true
        case .delete: break
        }
    }
}

private struct WorkspaceCreateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Control(configuration: configuration) }
    private struct Control: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary.opacity(enabled ? 0.85 : 0.3))
                .background(Color.primary.opacity(enabled && configuration.isPressed ? 0.16 : enabled && hovered ? 0.1 : 0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}

private struct WorkspaceRowAction: View {
    let symbol: String
    let title: String
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundStyle(destructive && hovered && isEnabled ? Color.red : Color.primary.opacity(isEnabled ? 0.65 : 0.2))
                .frame(width: 26, height: 28)
                .background(hovered && isEnabled ? Color.primary.opacity(0.09) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .onHover { hovered = $0 }
    }
}

private struct WorkspaceHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration) }
    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.05 : 0))
                .onHover { hovered = $0 }
        }
    }
}
