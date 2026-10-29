import AppKit

/// Preserve the pane's last frame while a CLI briefly leaves its TUI
/// for the editor handshake. This covers pixels only; PTY processing continues.
@MainActor
final class QuickInputTerminalSnapshot {
    private final class Overlay: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private var overlay: NSImageView?
    private var timeout: Task<Void, Never>?
    private var frameObserver: NSObjectProtocol?

    init(surface: Ghostty.SurfaceView, maximumDuration: Duration = .seconds(6)) {
        guard let image = surface.asImage else { return }
        let overlay = Overlay(frame: surface.bounds)
        overlay.image = image
        overlay.imageScaling = .scaleNone
        overlay.imageAlignment = .alignTopLeft
        overlay.autoresizingMask = [.width, .height]
        // Use a sibling above the Metal surface. A child of the renderer-backed
        // view can be obscured by its drawable during the screen transition.
        guard let parent = surface.superview else { return }
        overlay.frame = surface.frame
        parent.addSubview(overlay, positioned: .above, relativeTo: surface)
        self.overlay = overlay
        let capturedSize = surface.bounds.size
        surface.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: surface, queue: .main
        ) { [weak self, weak surface] _ in
            MainActor.assumeIsolated {
                guard let surface, surface.bounds.size != capturedSize else { return }
                // A pre-resize image is no longer a valid representation of
                // this pane. Never stretch it over the new terminal geometry.
                self?.remove()
            }
        }
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: maximumDuration)
            guard !Task.isCancelled else { return }
            self?.remove()
        }
    }

    func removeAfterRedraw() {
        // Retain until the delayed removal even when the import task returns.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.remove()
        }
    }

    deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }

    func remove() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        timeout?.cancel()
        timeout = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }
}
