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

/// Small metadata values copy on explicit click, without adding an icon column.
final class InspectorClickCopyText: NSButton {
    private(set) var value = ""
    private var displayText = ""
    private var copyLabel = ""
    private(set) var isCopied = false
    var pasteboard = NSPasteboard.general
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var feedbackTask: Task<Void, Never>?
    private var pendingCopy: Task<Void, Never>?
    var onDoubleClick: (() -> Void)?
    var naturalWidth: CGFloat { max(40, ceil((displayText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width) + 4) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        alignment = .left
        imagePosition = .noImage
        cell?.lineBreakMode = .byTruncatingMiddle
        wantsLayer = true
        layer?.cornerRadius = 3
        target = self
        action = #selector(copyValue(_:))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(text: String, value: String, label: String) {
        if self.value != value || displayText != text {
            feedbackTask?.cancel()
            pendingCopy?.cancel()
            isCopied = false
        }
        self.value = value
        displayText = text
        copyLabel = label
        setAccessibilityLabel(label + ": " + value)
        present()
    }
    private func present() {
        attributedTitle = NSAttributedString(string: displayText, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: isCopied ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ])
        layer?.backgroundColor = (isCopied ? NSColor.controlAccentColor.withAlphaComponent(0.06) : .clear).cgColor
        if hovered || isCopied {
            let value = NSMutableAttributedString(attributedString: attributedTitle)
            value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: value.length))
            attributedTitle = value
        }
        toolTip = isCopied ? "Copied" : "Copy " + copyLabel.lowercased() + " · " + value
        setAccessibilityValue(isCopied ? "Copied" : "")
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; present() }
    override func mouseExited(with event: NSEvent) { hovered = false; present() }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { feedbackTask?.cancel(); pendingCopy?.cancel(); isCopied = false; present() }
    }
    func cancelPendingCopy() { pendingCopy?.cancel(); pendingCopy = nil }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, onDoubleClick != nil { activate(clickCount: event.clickCount); return }
        super.mouseDown(with: event)
    }
    @objc private func copyValue(_ sender: Any?) {
        let mouse = NSApp.currentEvent.map { $0.window === window && ($0.type == .leftMouseDown || $0.type == .leftMouseUp) } ?? false
        activate(clickCount: 1, deferSingle: mouse)
    }
    func activate(clickCount: Int, deferSingle: Bool = false) {
        cancelPendingCopy()
        if clickCount >= 2, let onDoubleClick { onDoubleClick(); return }
        if deferSingle, onDoubleClick != nil {
            pendingCopy = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled else { return }
                self?.commitCopy()
            }
        } else { commitCopy() }
    }
    private func commitCopy() {
        InspectorCopyMenu.copy(value, to: pasteboard)
        feedbackTask?.cancel()
        isCopied = true
        present()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.isCopied = false
            self?.present()
        }
    }
}

final class InspectorCopyableTextView: NSTextView {
    var pasteboard = NSPasteboard.general
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": self.selectAll(nil); return true
            case "c":
                let range = self.selectedRange()
                if range.length > 0, NSMaxRange(range) <= (self.string as NSString).length {
                    InspectorCopyMenu.copy((self.string as NSString).substring(with: range), to: self.pasteboard)
                }
                return true
            default: return false
            }
        }
    }
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
