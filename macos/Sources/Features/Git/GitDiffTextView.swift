import AppKit
import SwiftUI

struct GitDiffTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textStorage?.setAttributedString(GitDiffTextRenderer.render(text))
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let rendered = GitDiffTextRenderer.render(text)
        guard textView.attributedString() != rendered else { return }
        textView.textStorage?.setAttributedString(rendered)
    }
}

enum GitDiffTextRenderer {
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff ") { inHunk = false }
            let isHunk = line.hasPrefix("@@")
            if isHunk {
                updateLineNumbers(from: line, old: &oldLine, new: &newLine)
                inHunk = true
            }
            let isMetadata = !inHunk && (
                line.hasPrefix("diff ") ||
                line.hasPrefix("index ") ||
                line.hasPrefix("---") ||
                line.hasPrefix("+++") ||
                line.hasPrefix("Binary files ")
            )
            let isAdded = inHunk && line.hasPrefix("+")
            let isDeleted = inHunk && line.hasPrefix("-")
            let hasLineNumber = inHunk && !isHunk && !isMetadata && !line.hasPrefix("\\")

            let oldNumber = hasLineNumber && !isAdded && !isHunk ? oldLine : nil
            let newNumber = hasLineNumber && !isDeleted && !isHunk ? newLine : nil
            if isAdded { newLine += 1 } else if isDeleted { oldLine += 1 } else if !isHunk && !isMetadata && !line.hasPrefix("\\") { oldLine += 1; newLine += 1 }

            let prefix = "\(number(oldNumber)) \(number(newNumber)) │ "
            let output = prefix + line + (index + 1 < lines.count ? "\n" : "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: isAdded ? NSColor.systemGreen : (isDeleted ? NSColor.systemRed : (isHunk ? NSColor.systemBlue : NSColor.labelColor)),
                .backgroundColor: isAdded ? NSColor.systemGreen.withAlphaComponent(0.08) : (isDeleted ? NSColor.systemRed.withAlphaComponent(0.08) : NSColor.textBackgroundColor),
            ]
            result.append(NSAttributedString(string: output, attributes: attributes))
        }
        return result
    }

    private static func updateLineNumbers(from line: String, old: inout Int, new: inout Int) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }
        old = Int(parts[1].dropFirst().split(separator: ",", maxSplits: 1).first ?? "") ?? 0
        new = Int(parts[2].dropFirst().split(separator: ",", maxSplits: 1).first ?? "") ?? 0
    }

    private static func number(_ value: Int?) -> String {
        guard let value else { return "    " }
        let string = String(value)
        return String(repeating: " ", count: max(0, 4 - string.count)) + string
    }
}
