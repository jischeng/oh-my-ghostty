import AppKit

/// Preserve the pane's last frame while a remote CLI briefly leaves its TUI
/// for the editor handshake. This covers pixels only; PTY processing continues.
@MainActor
final class QuickInputTerminalSnapshot {
    private var overlay: NSImageView?
    private var timeout: Task<Void, Never>?

    init(surface: Ghostty.SurfaceView) {
        guard let image = surface.asImage else { return }
        let overlay = NSImageView(frame: surface.bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        surface.addSubview(overlay)
        self.overlay = overlay
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.remove()
        }
    }

    func remove() {
        timeout?.cancel()
        timeout = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }
}
