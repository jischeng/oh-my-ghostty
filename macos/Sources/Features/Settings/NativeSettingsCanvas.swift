import AppKit

final class NativeSettingsCanvas: NSView {
    var background: NSColor? { didSet { needsDisplay = true } }
    var onWindowDidChange: (() -> Void)?
    override var wantsUpdateLayer: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowDidChange?()
    }
    override func draw(_ dirtyRect: NSRect) {
        (background ?? window?.backgroundColor ?? .windowBackgroundColor).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}
