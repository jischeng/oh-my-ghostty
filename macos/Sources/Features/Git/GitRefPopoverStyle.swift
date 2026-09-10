import AppKit
import SwiftUI

enum GitRefPopoverStyle {
    static let size = NSSize(width: 380, height: 380)
    static func content<V: View>(_ view: V, colors: GitCollectionColors) -> AnyView {
        AnyView(view.padding(.vertical, 10).frame(width: size.width, height: size.height)
            .background(Color(colors.background)).environment(\.gitCollectionColors, colors))
    }
}

final class GitScopeButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var value = super.titleRect(forBounds: rect)
        value.size.width = max(0, value.width - 20)
        return value
    }
}
