import AppKit

/// One policy for the application and its windows. Separate writers must not
/// alternate the application between nil (system) and the configured appearance:
/// effectiveAppearance drives libghostty's conditional-theme config reload.
struct OMGAppearancePolicy {
    let appearance: NSAppearance?
    let overridesEveryWindow: Bool

    init(override: OhMyGhosttyWindowTheme?, configured: NSAppearance?) {
        overridesEveryWindow = override != nil
        switch override {
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .system: appearance = nil
        case nil: appearance = configured
        }
    }

    func needsUpdate(current: NSAppearance?) -> Bool {
        current?.name != appearance?.name
    }

    @MainActor
    func apply(to application: NSApplication) {
        if needsUpdate(current: application.appearance) {
            application.appearance = appearance
        }
        for window in application.windows where overridesEveryWindow || window.windowController is BaseTerminalController {
            if needsUpdate(current: window.appearance) { window.appearance = appearance }
        }
    }
}

/// Record before calling into libghostty: a color-scheme change can synchronously
/// reload configuration and reenter the effectiveAppearance observer.
final class OMGColorSchemeTracker {
    private var lastDark: Bool?

    func consume(isDark: Bool) -> Bool {
        guard lastDark != isDark else { return false }
        lastDark = isDark
        return true
    }
}
