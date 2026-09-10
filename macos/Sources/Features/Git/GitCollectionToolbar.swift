import AppKit
import SwiftUI

struct GitCollectionToolbar: View {
    @Binding var query: String
    @Binding var mode: GitCollectionMode
    var placeholder = "Search branches…"
    var autofocus = false
    let controller: GitCollectionController
    var cancel: () -> Void = {}
    @Environment(\.gitCollectionColors) private var colors
    var body: some View {
        HStack(spacing: 6) {
            GitCollectionSearchField(query: $query, placeholder: placeholder, autofocus: autofocus,
                                     colors: colors, controller: controller, cancel: cancel)
                .frame(height: 23)
            GitCollectionModePicker(mode: $mode)
        }
    }
}

struct GitCollectionSearchField: NSViewRepresentable {
    @Binding var query: String
    let placeholder: String
    let autofocus: Bool
    let colors: GitCollectionColors
    let controller: GitCollectionController
    let cancel: () -> Void
    final class Field: NSSearchField {
        var autofocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, autofocus else { return }
            autofocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.autofocus = autofocus
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.focusRingType = .none
        // NSSearchField needs its native bezel geometry to inset the field
        // editor past the search icon, including when it is auto-focused.
        field.isBezeled = true
        field.drawsBackground = true
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.identifier = .init("git-collection-search")
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        field.textColor = colors.text
        field.backgroundColor = colors.background
        field.placeholderAttributedString = NSAttributedString(string: placeholder,
            attributes: [.foregroundColor: colors.secondary, .font: NSFont.systemFont(ofSize: 11)])
        field.setAccessibilityLabel(placeholder)
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: GitCollectionSearchField
        init(_ parent: GitCollectionSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField, parent.query != field.stringValue else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch NSStringFromSelector(command) {
            case "moveUp:": parent.controller.move(-1)
            case "moveDown:": parent.controller.move(1)
            case "insertNewline:": parent.controller.activate()
            case "cancelOperation:": parent.cancel()
            default: return false
            }
            return true
        }
    }
}
