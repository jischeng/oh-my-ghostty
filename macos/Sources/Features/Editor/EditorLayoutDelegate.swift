import AppKit
import CodeEditTextView

/// Forwards layout manager delegate calls to the text view while preventing
/// synchronous re-entrancy through clip-view notifications during layout passes.
@MainActor
final class EditorLayoutDelegate: @preconcurrency TextLayoutManagerDelegate {
    private weak var textView: TextView?
    private var isApplyingAdjustment = false

    init(textView: TextView) { self.textView = textView }

    var visibleRect: NSRect { textView?.visibleRect ?? .zero }

    func textViewportSize() -> CGSize { textView?.textViewportSize() ?? .zero }

    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any] {
        textView?.typingAttributes ?? [:]
    }

    func layoutManagerHeightDidUpdate(newHeight: CGFloat) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        var availableSize = scrollView.contentSize
        availableSize.height -= scrollView.contentInsets.top + scrollView.contentInsets.bottom
        let targetHeight = max(newHeight, availableSize.height)
        if textView.frame.size.height != targetHeight {
            textView.frame.size.height = targetHeight
        }
    }

    func layoutManagerMaxWidthDidChange(newWidth: CGFloat) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        guard !textView.layoutManager.wrapLines else { return }
        let availableWidth = scrollView.contentSize.width
        let targetWidth = max(newWidth, availableWidth)
        if textView.frame.size.width != targetWidth {
            let clipView = scrollView.contentView
            let oldPosts = clipView.postsFrameChangedNotifications
            clipView.postsFrameChangedNotifications = false
            textView.frame.size.width = targetWidth
            clipView.postsFrameChangedNotifications = oldPosts
        }
    }

    func layoutManagerYAdjustment(_ value: CGFloat) {
        guard !isApplyingAdjustment,
              let textView,
              let scrollView = textView.enclosingScrollView else { return }
        isApplyingAdjustment = true
        let clipView = scrollView.contentView
        let oldBoundsPosts = clipView.postsBoundsChangedNotifications
        clipView.postsBoundsChangedNotifications = false

        var point = scrollView.documentVisibleRect.origin
        point.y += value
        scrollView.documentView?.scroll(point)
        scrollView.reflectScrolledClipView(clipView)

        clipView.postsBoundsChangedNotifications = oldBoundsPosts
        isApplyingAdjustment = false
    }
}

