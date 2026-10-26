import AppKit
import GhosttyKit
import IOSurface

extension TerminalController {
    /// Prepare only the tab about to replace the closing/selected window. Hidden
    /// tabs retain their last IOSurface, which may predate a window enlargement.
    /// Its top-left gravity leaves the newly exposed area transparent until a
    /// new frame arrives, so layout and fill that frame before AppKit reveals it.
    func prepareTabPresentation(from outgoingWindow: NSWindow) {
        guard let targetWindow = window, targetWindow !== outgoingWindow,
              outgoingWindow.tabGroup?.windows.contains(targetWindow) == true else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if !targetWindow.styleMask.contains(.fullScreen), targetWindow.frame != outgoingWindow.frame {
                targetWindow.setFrame(outgoingWindow.frame, display: false)
            }
            targetWindow.contentView?.superview?.layoutSubtreeIfNeeded()

            for surfaceView in surfaceTree {
                // A zoomed split can leave other panes detached/hidden. They
                // are not part of the incoming picture and must remain idle.
                guard surfaceView.window === targetWindow,
                      !surfaceView.isHiddenOrHasHiddenAncestor,
                      let layer = surfaceView.layer,
                      let surface = surfaceView.surface else { continue }
                let width = Int((layer.bounds.width * layer.contentsScale).rounded(.down))
                let height = Int((layer.bounds.height * layer.contentsScale).rounded(.down))
                guard width > 0, height > 0 else { continue }
                if let image = layer.contents as? IOSurface,
                   image.width == width, image.height == height { continue }

                // Unlike an automatic hidden-layer display callback, this
                // explicit request is allowed to draw while still occluded.
                // Draw once at the final size, without forcing opacity or
                // stretching the old terminal image.
                ghostty_surface_draw(surface)
            }
        }
    }
}
