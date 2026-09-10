import AppKit
import SwiftUI

struct GitHistoryScopePicker: NSViewRepresentable {
    let title: String
    let branches: [GitBranchInfo]
    let enabled: Bool
    var isBusy = false
    var worktrees: [GitWorktreeInfo] = []
    var worktreesError: String?
    var state: GitCollectionState?
    var stateKey = "history-refs"
    var selectedID: String?
    var tags: [GitRefDecoration] = []
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors

    final class Control: NSButton {
        private let chevron = NSImageView()
        fileprivate var content: GitHistoryScopePicker?
        private(set) var popover: NSPopover?
        private var host: NSHostingController<AnyView>?
        override init(frame: NSRect) {
            super.init(frame: frame)
            cell = GitScopeButtonCell()
            font = .systemFont(ofSize: 11, weight: .medium)
            alignment = .left
            isBordered = false
            imagePosition = .imageLeft
            cell?.lineBreakMode = .byTruncatingMiddle
            chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
            addSubview(chevron)
            wantsLayer = true
            layer?.cornerRadius = 4
            target = self
            action = #selector(showPicker)
            setAccessibilityLabel(GitL10n.text("Choose history branch or worktree"))
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(_ content: GitHistoryScopePicker) {
            self.content = content
            if title != content.title { title = content.title }
            toolTip = content.title
            contentTintColor = content.colors.text
            let selected = content.selectedID ?? "scope:allBranches"
            let symbol = selected.hasPrefix("refs/tags/") ? "tag" : selected.hasPrefix("refs/remotes/") ? "network"
                : selected.hasPrefix("worktree:") ? "folder" : selected == "scope:allBranches" ? "square.stack.3d.up" : "arrow.triangle.branch"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            chevron.contentTintColor = content.colors.secondary
            layer?.backgroundColor = (selected == "scope:allBranches" ? content.colors.hover : content.colors.accent.withAlphaComponent(0.09)).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = content.colors.separator.cgColor
            setAccessibilityValue(content.title)
            if popover?.isShown == true { host?.rootView = browser() }
        }
        private func browser() -> AnyView {
            guard let content else { return AnyView(EmptyView()) }
            let selected = content.selectedID.map { $0.hasPrefix("refs/tags/") ? "ref:tag:" + String($0.dropFirst("refs/tags/".count)) : $0 }
            return GitRefPopoverStyle.content(GitRefBrowser(branches: content.branches, worktrees: content.worktrees, isBusy: content.isBusy,
                branchesError: content.enabled ? nil : GitL10n.text("Branch status unavailable"), worktreesError: content.worktreesError,
                isPicker: true, state: content.state, stateKey: content.stateKey, selectedID: selected, tags: content.tags,
                close: { [weak self] in self?.popover?.performClose(nil) }, perform: content.perform), colors: content.colors)
        }
        @objc func showPicker() {
            guard window != nil else { return }
            if popover?.isShown == true { popover?.performClose(nil); return }
            let host = NSHostingController(rootView: browser())
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = host
            popover.contentSize = GitRefPopoverStyle.size
            self.host = host
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { popover?.performClose(nil) }
        }
        override func layout() {
            super.layout()
            chevron.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
        }
    }
    func makeNSView(context: Context) -> Control { Control() }
    func updateNSView(_ view: Control, context: Context) { view.configure(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 28)
    }
}
