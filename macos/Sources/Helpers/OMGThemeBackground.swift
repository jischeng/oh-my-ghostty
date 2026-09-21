import AppKit
import SwiftUI

/// Reproduces the terminal chrome color shown on screen, so SwiftUI chrome
/// matches the Zig-rendered terminal surface instead of showing a
/// sub-code-value mismatch.
///
/// Two rules keep both render stacks bit-identical:
/// - Opaque windows paint the Display-P3-quantized theme background.
/// - Translucent windows (`backgroundOpacity < 1` or blur) paint the
///   P3-quantized color WITH the configured alpha. The terminal surface emits
///   the same quantized code values and both it and the SwiftUI fill then
///   composite over the same blurred window backing at the same alpha, so the
///   final pixels match regardless of what is behind the window. Using the raw
///   sRGB color here instead caused a 1-code-value drift (SwiftUI and the
///   shader round the sRGB→P3 conversion differently).
enum OMGThemeBackground {
    /// Chrome color for the given theme background/opacity and window opacity.
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
        return quantized.opacity(max(0, min(1, opacity)))
    }

    /// The OPAQUE theme background color for settings windows and dialogs.
    ///
    /// This must be derived from the Ghostty config background color, NOT from
    /// `TerminalWindow.backgroundColor`: on translucent windows that property
    /// is `.white.withAlphaComponent(0.001)` (a nearly invisible white used as
    /// the blur backing), which previously made settings/dialogs render as a
    /// transparent wash instead of the theme color. Settings/dialogs are
    /// opaque windows, so they paint the quantized theme color at alpha 1.
    @MainActor
    static func windowBackground() -> NSColor {
        let delegate = NSApp.delegate as? AppDelegate
        let controller = TerminalController.all.first(where: { $0.window?.isKeyWindow ?? false })
            ?? TerminalController.all.first
        let config = controller?.ghostty.config ?? delegate?.ghostty.config
        let color = config.map { NSColor($0.backgroundColor) } ?? .windowBackgroundColor
        return TerminalRenderColorQuantizer.matchingRenderedNSColor(
            color, colorspaceIsDisplayP3: config?.windowColorspaceIsDisplayP3 ?? false
        ).withAlphaComponent(1)
    }

    /// Slightly separated chrome color for the settings sidebar, derived from
    /// the theme background (darker on dark themes, lighter on light themes).
    @MainActor
    static func sidebarBackground() -> NSColor {
        let background = windowBackground()
        guard let rgb = background.usingColorSpace(.deviceRGB) else { return background }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let target = luminance < 0.5 ? NSColor.black : NSColor.white
        return rgb.blended(withFraction: 0.92, of: target) ?? background
    }
}
