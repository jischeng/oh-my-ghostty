import Foundation
import GhosttyKit

enum SessionRuntimeClose {
    /// Explicit pane removal terminates only the corresponding remote session.
    /// App termination, detach and transport loss deliberately do not call this.
    @MainActor
    static func close(_ view: Ghostty.SurfaceView) {
        guard view.runtimeDescriptor != nil, let surface = view.surface else { return }
        ghostty_surface_close_session(surface)
    }

    @MainActor
    static func close(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        for surface in node.leaves() { close(surface) }
    }
}
