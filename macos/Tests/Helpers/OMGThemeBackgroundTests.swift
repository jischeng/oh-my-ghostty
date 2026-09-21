import AppKit
import SwiftUI
import Testing
@testable import Ghostty

struct OMGThemeBackgroundTests {
    /// The translucent chrome must stay a translucent fill (preserving blur),
    /// not an opaque pre-blended color. Settings/dialogs use the opaque variant.

    private func components(_ color: Color) -> (Int, Int, Int) {
        let c = NSColor(color).usingColorSpace(.deviceRGB)!
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    @Test func translucentChromeStaysTranslucent() {
        // The sidebar/QuickInput chrome keeps the theme color at the configured
        // opacity (translucent, preserving blur), NOT an opaque blend.
        let bg = NSColor(red: 0x21 / 255, green: 0x25 / 255, blue: 0x2b / 255, alpha: 1)
        let chrome = OMGThemeBackground.matchingChrome(
            color: Color(bg), opacity: 0.85, windowIsOpaque: false, colorspaceIsDisplayP3: false)
        #expect(abs(NSColor(chrome).alphaComponent - 0.85) < 0.001)
        #expect(components(chrome) == components(Color(bg)))
    }

    @Test func opaqueChromeIsQuantizedBackground() {
        let bg = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1) // Catppuccin Mocha
        let expected = TerminalRenderColorQuantizer.matchingRenderedNSColor(bg, colorspaceIsDisplayP3: false)
        let chrome = OMGThemeBackground.matchingChrome(
            color: Color(bg), opacity: 1, windowIsOpaque: true, colorspaceIsDisplayP3: false)
        #expect(components(chrome) == components(Color(expected)))
    }

    @Test func opaqueFullOpacityTranslucentWindowAlsoQuantizes() {
        // opacity >= 1 on a translucent (blur) window still matches the opaque path.
        let bg = NSColor(red: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1)
        let opaque = OMGThemeBackground.matchingChrome(
            color: Color(bg), opacity: 1, windowIsOpaque: false, colorspaceIsDisplayP3: false)
        let expected = TerminalRenderColorQuantizer.matchingRenderedNSColor(bg, colorspaceIsDisplayP3: false)
        #expect(components(opaque) == components(Color(expected)))
    }
}
