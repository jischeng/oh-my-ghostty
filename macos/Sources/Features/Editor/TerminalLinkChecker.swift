import Foundation
import GhosttyKit

/// OMG: answers the core's Cmd-hover existence checks (VS Code / iTerm2 style).
///
/// The core only underlines, previews, and opens a path candidate after this
/// confirms it exists in the source pane's filesystem (local or SSH), using
/// the same resolution as `TerminalPathOpener`. The core caches answers per
/// Cmd press and ignores replies for candidates it no longer tracks.
@MainActor
enum TerminalLinkChecker {
    static func check(url: String, baseDirectory: String, from source: Ghostty.SurfaceView) {
        let reply: (Bool) -> Void = { [weak source] exists in
            guard let surface = source?.surface else { return }
            url.withCString { urlPtr in
                baseDirectory.withCString { basePtr in
                    ghostty_surface_omg_link_checked(
                        surface,
                        urlPtr, UInt(url.utf8.count),
                        basePtr, UInt(baseDirectory.utf8.count),
                        exists
                    )
                }
            }
        }
        guard TerminalPathTarget.isCandidate(url),
              let resolved = TerminalPathOpener.resolve(url, from: source, baseDirectory: baseDirectory) else {
            reply(false)
            return
        }
        let filesystem = resolved.filesystem, path = resolved.path
        Task {
            let exists = ((try? await filesystem.itemType(at: path)) ?? nil) != nil
            reply(exists)
        }
    }
}
