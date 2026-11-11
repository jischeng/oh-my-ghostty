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

    @Test func translucentChromeMatchesThePremultipliedRendererTarget() throws {
        let bg = Color(.sRGB, red: 33 / 255, green: 37 / 255, blue: 43 / 255, opacity: 1)
        let chrome = OMGThemeBackground.matchingChrome(
            color: bg, opacity: 0.85, windowIsOpaque: false, colorspaceIsDisplayP3: true)
        let color = try #require(NSColor(chrome).usingColorSpace(.displayP3))
        #expect(color.alphaComponent < 1)
        #expect(Int((color.alphaComponent * 255).rounded()) == 217)
        #expect(Int((color.redComponent * color.alphaComponent * 255).rounded()) == 28)
        #expect(Int((color.greenComponent * color.alphaComponent * 255).rounded()) == 31)
        #expect(Int((color.blueComponent * color.alphaComponent * 255).rounded()) == 37)
    }

    @Test func auxiliaryPaletteRetainsThemeHueAndAppearance() {
        let dark = OMGThemePalette(
            background: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1), foreground: .white)
        #expect(dark.colorScheme == .dark)
        #expect(dark.background.alphaComponent == 1)
        let sidebar = dark.sidebar.usingColorSpace(.sRGB)!
        #expect(sidebar.redComponent > 0.16)
        #expect(sidebar.redComponent < 0.25)
        #expect(sidebar.blueComponent > sidebar.redComponent)
        let light = OMGThemePalette(background: .white, foreground: .black)
        #expect(light.colorScheme == .light)
    }

    @MainActor
    @Test func themedDialogCancellationKeepsAccessoryAndReturnsOnce() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let alert = NSAlert()
        alert.messageText = "Create Branch"
        alert.informativeText = "Enter the new local branch name."
        let field = NSTextField(string: "feature/theme")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let result = Task { await OMGThemeDialog.present(alert, for: parent) }
        try await Task.sleep(for: .milliseconds(150))
        let sheet = try #require(parent.attachedSheet)
        // AppKit marks attached sheets non-opaque for their rounded edges;
        // the content and window backing must still paint an opaque theme.
        #expect(sheet.backgroundColor.alphaComponent == 1)
        #expect(sheet.titlebarAppearsTransparent)
        #expect(field.window === sheet)
        #expect(field.stringValue == "feature/theme")
        parent.endSheet(sheet)
        let response = await result.value
        #expect(response == .alertSecondButtonReturn)
        #expect(sheet.contentViewController == nil)
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

    @Test func unfocusedSplitMaskPreservesTranslucentBackgroundBytesWhileDimmingForeground() throws {
        // Catppuccin Mocha (#1e1e2e) at 0.85 opacity -> P3 premultiplied bytes (26, 26, 38, 217).
        let mocha = Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 46 / 255, opacity: 1)
        let mask = OMGThemeBackground.unfocusedSplitMask(
            dimmingAmount: 0.25,
            surfaceBackground: mocha,
            backgroundOpacity: 0.85,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: false
        )
        let overlay = try #require(NSColor(mask.overlayColor).usingColorSpace(.displayP3))
        let baseAlpha = 217.0 / 255.0
        let basePremulR = 26.0 / 255.0
        let basePremulG = 26.0 / 255.0
        let basePremulB = 38.0 / 255.0

        // Source-over compositing of overlay (overlayColor * overlayOpacity, overlayOpacity)
        // onto dimmed surface (basePremul * surfaceOpacity, baseAlpha * surfaceOpacity)
        // must preserve the exact background alpha and premultiplied RGB.
        let compositedAlpha = mask.overlayOpacity + (baseAlpha * mask.surfaceOpacity) * (1 - mask.overlayOpacity)
        let compositedR = overlay.redComponent * mask.overlayOpacity +
            (basePremulR * mask.surfaceOpacity) * (1 - mask.overlayOpacity)
        let compositedG = overlay.greenComponent * mask.overlayOpacity +
            (basePremulG * mask.surfaceOpacity) * (1 - mask.overlayOpacity)
        let compositedB = overlay.blueComponent * mask.overlayOpacity +
            (basePremulB * mask.surfaceOpacity) * (1 - mask.overlayOpacity)

        #expect(abs(compositedAlpha - baseAlpha) < 1e-6)
        #expect(abs(compositedR - basePremulR) < 1e-6)
        #expect(abs(compositedG - basePremulG) < 1e-6)
        #expect(abs(compositedB - basePremulB) < 1e-6)

        // Meanwhile an opaque white glyph pixel (1.0, 1.0) dims its foreground weight to (1 - 0.25) = 0.75.
        let glyphForegroundWeight = mask.surfaceOpacity * (1 - mask.overlayOpacity)
        #expect(abs(glyphForegroundWeight - 0.75) < 1e-6)
    }

    @Test func unfocusedSplitMaskHandlesGlassOpaqueAndExplicitFill() throws {
        let bg = Color(.sRGB, red: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, opacity: 1)

        // Liquid glass zeroes the overlay so no flat sRGB slab paints over NSGlassEffectView.
        let glass = OMGThemeBackground.unfocusedSplitMask(
            dimmingAmount: 0.2,
            surfaceBackground: bg,
            backgroundOpacity: 0.8,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: false,
            usesWindowGlass: true
        )
        #expect(glass.overlayOpacity == 0)
        #expect(abs(glass.surfaceOpacity - 0.8) < 1e-6)

        // Opaque windows keep surfaceOpacity = 1 and quantize the overlay fill.
        let opaque = OMGThemeBackground.unfocusedSplitMask(
            dimmingAmount: 0.15,
            surfaceBackground: bg,
            backgroundOpacity: 0.8,
            windowIsOpaque: true,
            colorspaceIsDisplayP3: false
        )
        #expect(opaque.surfaceOpacity == 1)
        #expect(abs(opaque.overlayOpacity - 0.15) < 1e-6)
        let expected = TerminalRenderColorQuantizer.matchingRenderedNSColor(NSColor(bg), colorspaceIsDisplayP3: false)
        #expect(components(opaque.overlayColor) == components(Color(expected)))

        // Explicit `unfocused-split-fill` keeps Ghostty's custom fill color verbatim.
        let custom = Color(.sRGB, red: 0.8, green: 0.1, blue: 0.2, opacity: 1)
        let explicit = OMGThemeBackground.unfocusedSplitMask(
            dimmingAmount: 0.3,
            explicitFill: custom,
            surfaceBackground: bg,
            backgroundOpacity: 0.7,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: false
        )
        #expect(explicit.surfaceOpacity == 1)
        #expect(explicit.overlayColor == custom)
        #expect(abs(explicit.overlayOpacity - 0.3) < 1e-6)
    }
}
