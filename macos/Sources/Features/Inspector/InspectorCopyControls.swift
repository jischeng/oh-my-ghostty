import AppKit

/// Read-only inspector fields participate in the host's early key routing,
/// before terminal bindings can consume Copy or Select All.
class InspectorCopyableTextField: NSTextField {
    var pasteboard = NSPasteboard.general
    var copyValue: String?
    var copyItems: [(String, String)]?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  let editor = self.currentEditor() as? NSTextView, self.window?.firstResponder === editor else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil); return true
            case "c":
                let range = editor.selectedRange()
                if range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length {
                    InspectorCopyMenu.copy((editor.string as NSString).substring(with: range), to: self.pasteboard)
                }
                return true
            default: return false
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        InspectorCopyMenu(values: copyItems ?? [("Copy", copyValue ?? stringValue)], pasteboard: pasteboard)
    }
}

final class InspectorCopyButton: NSButton {
    var value = ""
    var pasteboard = NSPasteboard.general
    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(copyValue(_:))
        toolTip = "Copy"
        setAccessibilityLabel("Copy")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func copyValue(_ sender: Any?) { InspectorCopyMenu.copy(value, to: pasteboard) }
}

final class InspectorCopyMenu: NSMenu {
    var pasteboard = NSPasteboard.general
    init(values: [(String, String)] = [], pasteboard: NSPasteboard = .general) {
        super.init(title: "")
        self.pasteboard = pasteboard
        addCopyItems(values)
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func addCopyItems(_ values: [(String, String)]) {
        for (title, value) in values {
            let item = NSMenuItem(title: title, action: #selector(copyItem(_:)), keyEquivalent: "")
            item.representedObject = value
            item.target = self
            addItem(item)
        }
    }
    @objc private func copyItem(_ item: NSMenuItem) {
        if let value = item.representedObject as? String { Self.copy(value, to: pasteboard) }
    }
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

final class InspectorCopyTableView: NSTableView {
    var copyValue: (() -> String?)?
    var pasteboard = NSPasteboard.general
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
            if let value = self.copyValue?() { InspectorCopyMenu.copy(value, to: self.pasteboard) }
            return true
        }
    }
}
