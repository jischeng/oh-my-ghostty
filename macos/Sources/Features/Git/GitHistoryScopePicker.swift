import AppKit
import SwiftUI

struct GitHistoryScopePicker: NSViewRepresentable {
    let title: String
    let branches: [GitBranchInfo]
    let enabled: Bool
    let perform: (InspectorGitAction) -> Void

    final class Control: NSPopUpButton {
        var fullTitle = ""
        var perform: (InspectorGitAction) -> Void = { _ in }
        override func layout() {
            super.layout()
            item(at: 0)?.title = GitHistoryScopePicker.compact(fullTitle, width: max(40, bounds.width - 28), font: font ?? .systemFont(ofSize: 11))
        }
        @objc func choose(_ sender: Any?) {
            guard let action = ((sender as? NSMenuItem)?.representedObject ?? selectedItem?.representedObject) as? InspectorGitAction else { return }
            selectItem(at: 0)
            perform(action)
        }
    }
    func makeNSView(context: Context) -> Control {
        let view = Control(frame: .zero, pullsDown: true)
        view.font = .systemFont(ofSize: 11)
        view.cell?.lineBreakMode = .byTruncatingMiddle
        view.target = view
        view.action = #selector(Control.choose(_:))
        return view
    }
    func updateNSView(_ view: Control, context: Context) {
        view.fullTitle = title
        view.perform = perform
        view.toolTip = title
        view.removeAllItems()
        view.addItem(withTitle: Self.compact(title))
        view.menu?.autoenablesItems = false
        for scope in GitHistoryScope.allCases {
            let item = NSMenuItem(title: scope.displayName, action: #selector(Control.choose(_:)), keyEquivalent: "")
            item.target = view
            item.representedObject = InspectorGitAction.selectHistoryScope(scope)
            view.menu?.addItem(item)
        }
        view.menu?.addItem(.separator())
        for branch in branches {
            let item = NSMenuItem(title: Self.compact(branch.name), action: #selector(Control.choose(_:)), keyEquivalent: "")
            item.target = view
            item.toolTip = branch.name
            item.image = NSImage(systemSymbolName: branch.isRemote ? "network" : "arrow.triangle.branch", accessibilityDescription: nil)
            item.representedObject = InspectorGitAction.browseBranch(branch.id)
            item.isEnabled = enabled
            view.menu?.addItem(item)
        }
        view.selectItem(at: 0)
        view.needsLayout = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 24)
    }
    static func compact(_ text: String, width: CGFloat = 220, font: NSFont = .menuFont(ofSize: 0)) -> String {
        func fits(_ value: String) -> Bool { (value as NSString).size(withAttributes: [.font: font]).width <= width }
        if fits(text) { return text }
        let characters = Array(text)
        var low = 0
        var high = max(0, characters.count - 1)
        var result = "…"
        while low <= high {
            let count = (low + high) / 2
            let left = (count * 2 + 2) / 3
            let candidate = String(characters.prefix(left)) + "…" + String(characters.suffix(count - left))
            if fits(candidate) { result = candidate; low = count + 1 } else { high = count - 1 }
        }
        return result
    }
}
