import AppKit
import SwiftUI
import Testing
@testable import Ghostty

struct OMGThemeBackgroundTests {
    /// Replicates the terminal renderer's translucent output: P3-quantize the
    /// theme background, then source-over blend against the near-white backing.
    private func terminalCodeValues(_ bg: NSColor, opacity: Double) -> (Int, Int, Int) {
        let quantized = TerminalRenderColorQuantizer.matchingRenderedNSColor(bg, colorspaceIsDisplayP3: false)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        quantized.usingColorSpace(.deviceRGB)!.getRed(&r, green: &g, blue: &b, alpha: nil)
        let p: [CGFloat] = [r, g, b]
        let back = NSColor.white.withAlphaComponent(0.001).usingColorSpace(.deviceRGB)!
        let blended = NSColor(deviceRed: p[0], green: p[1], blue: p[2], alpha: 1)
            .blended(withFraction: opacity, of: back)!
        return (Int((blended.redComponent * 255).rounded()),
                Int((blended.greenComponent * 255).rounded()),
                Int((blended.blueComponent * 255).rounded()))
    }

    private func components(_ color: Color) -> (Int, Int, Int) {
        let c = NSColor(color).usingColorSpace(.deviceRGB)!
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    @Test func translucentChromeMatchesTerminalBlend() {
        // Atom One Dark #21252b at 0.85 opacity.
        let bg = NSColor(red: 0x21 / 255, green: 0x25 / 255, blue: 0x2b / 255, alpha: 1)
        let expected = terminalCodeValues(bg, opacity: 0.85)
        let chrome = OMGThemeBackground.matchingChrome(
            color: Color(bg), opacity: 0.85, windowIsOpaque: false, colorspaceIsDisplayP3: false)
        let actual = components(chrome)
        #expect(actual == expected)
        // Translucent windows paint an opaque blended chrome (no further alpha
        // blending by Core Animation), so opacity must be forced to 1.
        #expect(abs(NSColor(chrome).alphaComponent - 1) < 0.001)
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
