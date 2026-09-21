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
    /// When the window is opaque (or opacity >= 1) this is the P3-quantized
    /// background. Otherwise it is the P3-quantized background blended with
    /// the translucent backing at `opacity`, matching the terminal's output.
    static func matchingChrome(
        color: Color,
        opacity: Double,
        windowIsOpaque: Bool,
        colorspaceIsDisplayP3: Bool
    ) -> Color {
        let quantized = TerminalRenderColorQuantizer.matchingRenderedColor(
            color, colorspaceIsDisplayP3: colorspaceIsDisplayP3
        )
        if windowIsOpaque || opacity >= 1 {
            return quantized.opacity(1)
        }
        let alpha = max(0, min(1, opacity))
        guard let backing = translucentBacking.usingColorSpace(.deviceRGB),
              let fill = NSColor(quantized).usingColorSpace(.deviceRGB) else {
            return quantized.opacity(alpha)
        }
        let blended = fill.blended(withFraction: alpha, of: backing) ?? fill
        // Re-quantize so Core Animation emits the exact code values the
        // terminal surface produced after its own blend.
        return Color(.displayP3,
                     red: TerminalRenderColorQuantizer.quantize8(Double(blended.redComponent)),
                     green: TerminalRenderColorQuantizer.quantize8(Double(blended.greenComponent)),
                     blue: TerminalRenderColorQuantizer.quantize8(Double(blended.blueComponent)),
                     opacity: 1)
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
        let opacity = config?.backgroundOpacity ?? 1
        if opacity >= 1 {
            return TerminalRenderColorQuantizer.matchingRenderedNSColor(
                color, colorspaceIsDisplayP3: config?.windowColorspaceIsDisplayP3 ?? false
            ).withAlphaComponent(1)
        }
        return NSColor(matchingChrome(color: Color(color), opacity: opacity,
            windowIsOpaque: false, colorspaceIsDisplayP3: config?.windowColorspaceIsDisplayP3 ?? false))
    }
}
