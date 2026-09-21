import AppKit
import SwiftUI

/// Reproduces the terminal chrome color shown on screen for a translucent or
/// opaque window, so SwiftUI chrome matches the Zig-rendered terminal surface
/// instead of showing a sub-code-value mismatch.
///
/// On an opaque window the terminal emits P3-quantized code values; on a
/// translucent window (`backgroundOpacity < 1` or blur) the terminal surface
/// is first P3-quantized and then source-over blended against the window's
/// near-white backing at the configured opacity, while SwiftUI would otherwise
/// blend in sRGB. `matchingChrome` mirrors the terminal's two-step result so
/// the sidebar, QuickInput, settings window and dialogs all land on the same
/// final code values as the terminal.
enum OMGThemeBackground {
    /// The near-white backing `TerminalWindow.syncAppearance` uses on
    /// translucent windows.
    private static let translucentBacking = NSColor.white.withAlphaComponent(0.001)

    /// Chrome color for the given theme background/opacity and window opacity.
    /// Opaque windows paint the P3-quantized background (matching the terminal
    /// surface bit-for-bit). Translucent windows keep the theme color at the
    /// configured opacity as a translucent fill, preserving blur through the
    /// window — this is the same compositing path the terminal surface uses, so
    /// sidebar/QuickInput stay translucent and match instead of becoming opaque.
    static func matchingChrome(
        color: Color,
        opacity: Double,
        windowIsOpaque: Bool,
        colorspaceIsDisplayP3: Bool
    ) -> Color {
        if windowIsOpaque || opacity >= 1 {
            return TerminalRenderColorQuantizer.matchingRenderedColor(
                color, colorspaceIsDisplayP3: colorspaceIsDisplayP3
            ).opacity(1)
        }
        return color.opacity(max(0, min(1, opacity)))
    }

    /// The effective terminal window background color for settings/dialogs:
    /// prefers the active terminal window's presented background so these
    /// windows follow the live theme (including per-theme config and blur),
    /// falling back to the current Ghostty config background.
    @MainActor
    static func windowBackground() -> NSColor {
        let delegate = NSApp.delegate as? AppDelegate
        guard delegate != nil else { return .windowBackgroundColor }
        let controller = TerminalController.all.first(where: { $0.window?.isKeyWindow ?? false })
            ?? TerminalController.all.first
        if let controller,
           let window = controller.window as? TerminalWindow {
            return window.backgroundColor
        }
        let config = delegate?.ghostty.config
        let color = config.map { NSColor($0.backgroundColor) } ?? .windowBackgroundColor
        // Settings/dialogs use an OPAQUE theme background (never translucent),
        // so they render as the theme color instead of showing content behind.
        return TerminalRenderColorQuantizer.matchingRenderedNSColor(
            color, colorspaceIsDisplayP3: config?.windowColorspaceIsDisplayP3 ?? false
        ).withAlphaComponent(1)
    }
}
