import AppKit
import SwiftUI

struct GitCommitComposer: View {
    @Binding var message: String
    let stagedCount: Int
    let isBusy: Bool
    let canCommit: Bool
    let isUpdatingIndex: Bool
    let commit: () -> Void
    @State private var editorHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GitCommitMessageEditor(text: $message, height: $editorHeight)
                .frame(height: editorHeight)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Commit message").font(.system(size: 11)).foregroundStyle(.tertiary)
                            .padding(.leading, 9).padding(.top, 6).allowsHitTesting(false)
                    }
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            HStack(spacing: 6) {
                Text("\(stagedCount) staged").font(.system(size: 10)).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini).frame(width: 12, height: 12).opacity(isUpdatingIndex ? 1 : 0)
                Spacer(minLength: 4)
                Button("Commit", action: commit)
                    .controlSize(.small)
                    .disabled(isBusy || !canCommit || stagedCount == 0 || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Keep the text view and its selection/undo stack alive through status updates.
struct GitCommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = InspectorCopyableTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 11)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Commit message")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let location = min(selection.location, (text as NSString).length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, (text as NSString).length - location)))
        }
        context.coordinator.measure(editor)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GitCommitMessageEditor
        init(_ parent: GitCommitMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = min(112, max(44, ceil(manager.usedRect(for: container).height) + 10))
            guard abs(parent.height - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - height) > 0.5 else { return }
                self.parent.height = height
            }
        }
    }
}
