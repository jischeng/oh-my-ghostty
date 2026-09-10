import AppKit
import CodeEditTextView

/// The dependency synchronously scrolls/resizes from inside layoutLines, which
/// re-enters layout through its clip-view observers. Forward geometry changes
/// after that layout pass so width changes cannot recurse until stack overflow.
@MainActor
final class EditorLayoutDelegate: @preconcurrency TextLayoutManagerDelegate {
    private weak var textView: TextView?
    private var scheduled = false
    private var geometryChanged = false
    private var adjustment: CGFloat = 0
    private var origin: NSPoint?

    init(textView: TextView) { self.textView = textView }
    var visibleRect: NSRect { textView?.visibleRect ?? .zero }
    func textViewportSize() -> CGSize { textView?.textViewportSize() ?? .zero }
    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any] { textView?.typingAttributes ?? [:] }
    func layoutManagerHeightDidUpdate(newHeight: CGFloat) { geometryChanged = true; schedule() }
    func layoutManagerMaxWidthDidChange(newWidth: CGFloat) { geometryChanged = true; schedule() }
    func layoutManagerYAdjustment(_ value: CGFloat) { adjustment += value; schedule() }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        origin = textView?.enclosingScrollView?.contentView.bounds.origin
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }
    private func flush() {
        scheduled = false
        let delta = adjustment
        let needsGeometry = geometryChanged
        let originalOrigin = origin
        adjustment = 0; geometryChanged = false; origin = nil
        guard let textView, textView.layoutManager.delegate === self else { return }
        let userDidNotScroll = textView.enclosingScrollView?.contentView.bounds.origin == originalOrigin
        if needsGeometry { textView.layoutManagerHeightDidUpdate(newHeight: textView.layoutManager.estimatedHeight()) }
        if delta != 0, userDidNotScroll { textView.layoutManagerYAdjustment(delta) }
    }
}
