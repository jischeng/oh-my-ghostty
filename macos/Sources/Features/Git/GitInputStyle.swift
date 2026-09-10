import AppKit
import SwiftUI

enum GitInputState { case normal, hovered, focused, disabled }

extension GitCollectionColors {
    func inputFill(_ state: GitInputState) -> NSColor {
        text.gitOpacity(state == .disabled ? 0.02 : state == .focused ? 0.075 : state == .hovered ? 0.055 : 0.035)
    }
    func inputBorder(_ state: GitInputState) -> NSColor {
        if state == .focused { return accent.withAlphaComponent(0.42) }
        return text.gitOpacity(state == .disabled ? 0.08 : state == .hovered ? 0.23 : 0.14)
    }
}

struct GitInputSurface: ViewModifier {
    let focused: Bool
    var enabled = true
    @State private var hovered = false
    @Environment(\.gitCollectionColors) private var colors
    private var state: GitInputState { !enabled ? .disabled : focused ? .focused : hovered ? .hovered : .normal }
    func body(content: Content) -> some View {
        content
            .background(Color(colors.inputFill(state)), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(colors.inputBorder(state)), lineWidth: focused ? 1 : 0.5))
            .onHover { hovered = $0 }
    }
}

final class GitSearchFieldCell: NSSearchFieldCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let field = controlView as? GitCollectionSearchField.Field else { super.draw(withFrame: frame, in: controlView); return }
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        field.colors.inputFill(field.inputState).setFill()
        shape.fill()
        field.colors.inputBorder(field.inputState).setStroke()
        shape.lineWidth = field.inputState == .focused ? 1 : 0.5
        shape.stroke()
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

final class GitCommitTextView: InspectorCopyableTextView {
    var focusChanged: (Bool) -> Void = { _ in }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged(false) }
        return result
    }
}
