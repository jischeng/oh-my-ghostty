import AppKit
import SwiftUI

/// Commit badges and the History filter host the same reference browser.
final class GitRefListView: NSView {
    private(set) var refs: [GitRefDecoration] = []
    var colors = GitCollectionColors() { didSet { if host != nil { configure(refs, selected: selectedRef) } } }
    var pasteboard = NSPasteboard.general { didSet { if host != nil { configure(refs, selected: selectedRef) } } }
    private var selectedRef: GitRefDecoration?
    private let state = GitCollectionState()
    private var host: NSHostingView<AnyView>?
    override var isFlipped: Bool { true }
    static func height(for refs: [GitRefDecoration], width: CGFloat) -> CGFloat { GitRefPopoverStyle.size.height }
    func configure(_ refs: [GitRefDecoration], selected: GitRefDecoration? = nil) {
        self.refs = refs
        selectedRef = selected
        let content = GitRefPopoverStyle.content(GitRefBrowser(branches: [], state: state, stateKey: "decoration-refs",
            selectedID: (selected ?? refs.first).map(GitCollectionBuilder.referenceID), decorations: refs, pasteboard: pasteboard,
            close: { [weak self] in self?.window?.performClose(nil) }, perform: { _ in }), colors: colors)
        if let host { host.rootView = content } else {
            let view = NSHostingView(rootView: content)
            view.sizingOptions = []
            addSubview(view)
            host = view
        }
        needsLayout = true
    }
    override func layout() { super.layout(); host?.frame = bounds }
}

/// Repository refs stay named and visible; long names wrap instead of aggregating.
struct GitHeaderReferences: NSViewRepresentable {
    let refs: [GitRefDecoration]
    func makeNSView(context: Context) -> GitHeaderReferencesView {
        let view = GitHeaderReferencesView()
        view.configure(refs)
        return view
    }
    func updateNSView(_ view: GitHeaderReferencesView, context: Context) { view.configure(refs) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitHeaderReferencesView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: nsView.frames(width: width).map(\.maxY).max() ?? 0)
    }
}

final class GitHeaderReferencesView: NSView {
    private var refs: [GitRefDecoration] = []
    private var fields: [InspectorCopyableTextField] = []
    override var isFlipped: Bool { true }

    func configure(_ refs: [GitRefDecoration]) {
        guard self.refs != refs else { return }
        self.refs = refs
        fields.forEach { $0.removeFromSuperview() }
        fields = refs.map { ref in
            let field = InspectorCopyableTextField(wrappingLabelWithString: "")
            field.attributedStringValue = GitRefBadgesView.attributed(ref)
            field.isSelectable = true
            field.lineBreakMode = .byCharWrapping
            field.maximumNumberOfLines = 0
            field.copyValue = ref.name
            field.toolTip = ref.name
            field.setAccessibilityLabel(ref.kind.displayName + ": " + ref.name)
            field.wantsLayer = true
            field.layer?.cornerRadius = 3
            field.layer?.backgroundColor = GitRefBadgesView.tint(for: ref.kind).withAlphaComponent(0.10).cgColor
            addSubview(field)
            return field
        }
        needsLayout = true
    }

    func frames(width: CGFloat) -> [NSRect] {
        let available = max(1, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return fields.map { field in
            let width = min(available, ceil(field.attributedStringValue.size().width) + 4)
            if x > 0, x + width > available { x = 0; y += rowHeight + 4; rowHeight = 0 }
            let height = max(17, ceil(field.cell?.cellSize(forBounds:
                NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 17))
            let frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 4
            rowHeight = max(rowHeight, height)
            return frame
        }
    }

    override func layout() {
        super.layout()
        for (field, frame) in zip(fields, frames(width: bounds.width)) { field.frame = frame }
    }
}

struct InspectorCopyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> InspectorCopyableTextField {
        let view = InspectorCopyableTextField(labelWithString: "")
        view.isSelectable = true
        view.font = .systemFont(ofSize: 10)
        view.textColor = .secondaryLabelColor
        view.lineBreakMode = .byTruncatingMiddle
        view.maximumNumberOfLines = 1
        return view
    }
    func updateNSView(_ view: InspectorCopyableTextField, context: Context) {
        if view.stringValue != text { view.stringValue = text }
        view.toolTip = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorCopyableTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 14)
    }
}
