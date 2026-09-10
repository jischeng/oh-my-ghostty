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
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors

    final class Control: NSButton {
        private static let pickerSize = NSSize(width: 380, height: 380)
        fileprivate var content: GitHistoryScopePicker?
        private(set) var popover: NSPopover?
        private var host: NSHostingController<AnyView>?
        override init(frame: NSRect) {
            super.init(frame: frame)
            font = .systemFont(ofSize: 11)
            alignment = .left
            isBordered = false
            imagePosition = .imageRight
            cell?.lineBreakMode = .byTruncatingMiddle
            image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
            target = self
            action = #selector(showPicker)
            setAccessibilityLabel("Choose history branch or worktree")
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(_ content: GitHistoryScopePicker) {
            self.content = content
            if title != content.title { title = content.title }
            toolTip = content.title
            contentTintColor = content.colors.text
            if popover?.isShown == true { host?.rootView = browser() }
        }
        private func browser() -> AnyView {
            guard let content else { return AnyView(EmptyView()) }
            return AnyView(GitRefBrowser(branches: content.branches, worktrees: content.worktrees, isBusy: content.isBusy,
                branchesError: content.enabled ? nil : "Branch status unavailable", worktreesError: content.worktreesError,
                isPicker: true, state: content.state, stateKey: content.stateKey, selectedID: content.selectedID,
                close: { [weak self] in self?.popover?.performClose(nil) }, perform: content.perform)
                .padding(.vertical, 10)
                .frame(width: Self.pickerSize.width, height: Self.pickerSize.height)
                .background(Color(content.colors.background))
                .environment(\.gitCollectionColors, content.colors))
        }
        @objc func showPicker() {
            guard window != nil else { return }
            if popover?.isShown == true { popover?.performClose(nil); return }
            let host = NSHostingController(rootView: browser())
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = host
            popover.contentSize = Self.pickerSize
            self.host = host
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { popover?.performClose(nil) }
        }
    }
    func makeNSView(context: Context) -> Control { Control() }
    func updateNSView(_ view: Control, context: Context) { view.configure(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 24)
    }
}
