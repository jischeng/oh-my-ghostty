import Darwin
import Foundation

/// Centralizes password/secure-input detection so programmatic PTY writers
/// never inject text or keystrokes into active password prompts, even when a
/// secondary UI (such as Quick Input, Git sidebar, or Editor) holds focus.
enum ProgrammaticInputGuard {
    static var isGlobalSecureInputActive: Bool {
        SecureInput.shared.enabled || SecureInput.shared.global
    }

    /// Mirrors Ghostty's termios heuristic (`ICANON && !ECHO`) directly on the
    /// local PTY device so programmatic writers fail closed immediately without
    /// waiting for asynchronous termios polling or `auto-secure-input` focus state.
    static func isLocalTTYCanonicalNoEcho(_ ttyName: String?) -> Bool {
        guard let ttyName, !ttyName.isEmpty, !ttyName.contains("\0") else {
            return false
        }
        let path = ttyName.hasPrefix("/") ? ttyName : "/dev/\(ttyName)"
        let fd = Darwin.open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var state = termios()
        guard tcgetattr(fd, &state) == 0 else { return false }
        return isCanonicalNoEcho(localFlags: state.c_lflag)
    }

    static func isCanonicalNoEcho(localFlags: tcflag_t) -> Bool {
        let canonical = (localFlags & tcflag_t(ICANON)) != 0
        let echo = (localFlags & tcflag_t(ECHO)) != 0
        return canonical && !echo
    }
}

extension Ghostty.SurfaceView {
    /// True when this terminal surface is waiting for password/no-echo input,
    /// regardless of whether the terminal view currently has AppKit responder focus.
    var isPasswordInputActive: Bool {
        passwordInput ||
            runtimeInlineSession?.passwordInput == true ||
            (runtimeInlineSession == nil &&
                ProgrammaticInputGuard.isLocalTTYCanonicalNoEcho(surfaceModel?.ttyName))
    }

    /// True when programmatic text/keystroke injection into this surface must be refused.
    var blocksProgrammaticInput: Bool {
        isPasswordInputActive || ProgrammaticInputGuard.isGlobalSecureInputActive
    }
}
