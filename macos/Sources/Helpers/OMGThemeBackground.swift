import AppKit
import GhosttyKit
import SwiftUI

/// Shared terminal chrome and opaque auxiliary-window theme policy.
enum OMGThemeBackground {
    struct UnfocusedSplitMask: Equatable {
        let surfaceOpacity: Double
        let overlayColor: Color
        let overlayOpacity: Double

        static let identity = Self(surfaceOpacity: 1, overlayColor: .clear, overlayOpacity: 0)
    }

    static func matchingChrome(
        color: Color,
        opacity: Double,
        windowIsOpaque: Bool,
        colorspaceIsDisplayP3: Bool,
        linearBlending: Bool = false,
        usesWindowGlass: Bool = false
    ) -> Color {
        if windowIsOpaque {
            return TerminalRenderColorQuantizer.matchingRenderedColor(
                color, colorspaceIsDisplayP3: colorspaceIsDisplayP3
            ).opacity(1)
        }
        // Window-level liquid glass (`TerminalGlassView`) already tints the entire
        // window at `backgroundOpacity`, and the Metal renderer zeroes terminal
        // background alpha (`src/renderer/generic.zig`). Keep adjacent chrome clear
        // so sidebars, titlebar, quick input, and editor do not double-tint.
        if usesWindowGlass {
            return .clear
        }
        if opacity >= 1 {
            return TerminalRenderColorQuantizer.matchingRenderedColor(
                color, colorspaceIsDisplayP3: colorspaceIsDisplayP3
            ).opacity(1)
        }
        // The premultiplied-byte matcher models native (gamma) blending.
        // Keep the existing fill policy for explicitly selected linear modes.
        if linearBlending { return color.opacity(max(0, min(1, opacity))) }
        return TerminalRenderColorQuantizer.matchingTranslucentColor(
            color, opacity: opacity, colorspaceIsDisplayP3: colorspaceIsDisplayP3
        )
    }

    /// Computes surface and overlay opacities for an unfocused split pane so empty
    /// background pixels retain the exact same alpha and quantized RGB as focused
    /// splits and sidebars, while foreground glyphs fade by `dimmingAmount`.
    static func unfocusedSplitMask(
        dimmingAmount: Double,
        explicitFill: Color? = nil,
        surfaceBackground: Color,
        backgroundOpacity: Double,
        windowIsOpaque: Bool,
        colorspaceIsDisplayP3: Bool,
        linearBlending: Bool = false,
        usesWindowGlass: Bool = false
    ) -> UnfocusedSplitMask {
        let dim = min(max(dimmingAmount, 0), 1)
        guard dim > 0 else { return .identity }

        if let explicitFill {
            return .init(surfaceOpacity: 1, overlayColor: explicitFill, overlayOpacity: dim)
        }

        if windowIsOpaque || (!usesWindowGlass && backgroundOpacity >= 1) {
            let fill = TerminalRenderColorQuantizer.matchingRenderedColor(
                surfaceBackground, colorspaceIsDisplayP3: colorspaceIsDisplayP3
            ).opacity(1)
            return .init(surfaceOpacity: 1, overlayColor: fill, overlayOpacity: dim)
        }

        if usesWindowGlass {
            return .init(surfaceOpacity: max(0, 1 - dim), overlayColor: .clear, overlayOpacity: 0)
        }

        let clampedOpacity = min(max(backgroundOpacity, 0), 1)
        let effectiveAlpha: Double
        let straightFill: Color
        if linearBlending {
            guard clampedOpacity > 0 else {
                return .init(surfaceOpacity: max(0, 1 - dim), overlayColor: .clear, overlayOpacity: 0)
            }
            effectiveAlpha = clampedOpacity
            straightFill = surfaceBackground.opacity(1)
        } else {
            let alphaByte = Int((clampedOpacity * 255).rounded())
            guard alphaByte > 0 else {
                return .init(surfaceOpacity: max(0, 1 - dim), overlayColor: .clear, overlayOpacity: 0)
            }
            effectiveAlpha = Double(alphaByte) / 255.0
            let matched = NSColor(TerminalRenderColorQuantizer.matchingTranslucentColor(
                surfaceBackground,
                opacity: clampedOpacity,
                colorspaceIsDisplayP3: colorspaceIsDisplayP3
            )).withAlphaComponent(1)
            straightFill = Color(nsColor: matched)
        }

        let overlayOpacity = effectiveAlpha * dim
        let denominator = 1 - overlayOpacity
        let surfaceOpacity = denominator > 1e-6 ? min(max((1 - dim) / denominator, 0), 1) : 0
        return .init(
            surfaceOpacity: surfaceOpacity,
            overlayColor: straightFill,
            overlayOpacity: overlayOpacity
        )
    }

    @MainActor
    static func palette(for window: NSWindow? = nil, config: Ghostty.Config? = nil) -> OMGThemePalette {
        let controller = (window?.windowController as? TerminalController)
            ?? ([NSApp.keyWindow, NSApp.mainWindow].compactMap { $0?.windowController as? TerminalController }.first)
        let config = config ?? controller?.ghostty.config ?? (NSApp.delegate as? AppDelegate)?.ghostty.config
        let background = config.map { NSColor($0.backgroundColor) } ?? .windowBackgroundColor
        let rendered = TerminalRenderColorQuantizer.matchingRenderedNSColor(
            background, colorspaceIsDisplayP3: config?.windowColorspaceIsDisplayP3 ?? false
        ).withAlphaComponent(1)
        var foreground = rendered.isLightColor ? NSColor.black : NSColor.white
        if let config {
            var value = ghostty_config_color_s()
            let key = "foreground"
            if ghostty_config_get(config.config, &value, key, UInt(key.utf8.count)) {
                foreground = TerminalRenderColorQuantizer.matchingRenderedNSColor(
                    NSColor(srgbRed: Double(value.r) / 255, green: Double(value.g) / 255,
                            blue: Double(value.b) / 255, alpha: 1),
                    colorspaceIsDisplayP3: config.windowColorspaceIsDisplayP3
                )
            }
        }
        return OMGThemePalette(background: rendered, foreground: foreground)
    }

    @MainActor
    static func windowBackground() -> NSColor { palette().background }

    @MainActor
    static func sidebarBackground() -> NSColor { palette().sidebar }
}

extension Ghostty.Config {
    var usesLinearAlphaBlending: Bool {
        guard let config else { return false }
        var value: UnsafePointer<Int8>?
        let key = "alpha-blending"
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value else { return false }
        return ["linear", "linear-corrected"].contains(String(cString: value))
    }

    var explicitUnfocusedSplitFill: Color? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        let key = "unfocused-split-fill"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return Color(
            red: Double(color.r) / 255,
            green: Double(color.g) / 255,
            blue: Double(color.b) / 255
        )
    }
}

struct OMGThemePalette {
    let background: NSColor
    let foreground: NSColor

    var sidebar: NSColor { background.blended(withFraction: 0.08, of: foreground) ?? background }
    var colorScheme: ColorScheme { background.isLightColor ? .light : .dark }
}

/// Auxiliary windows stay opaque even when the invoking terminal is translucent.
/// Listen to config notifications, not just light/dark appearance changes: two
/// dark themes can have entirely different palettes.
private struct OMGThemedSurface: ViewModifier {
    @State private var palette: OMGThemePalette

    init(palette: OMGThemePalette) { _palette = State(initialValue: palette) }

    func body(content: Content) -> some View {
        content
            // Native semantic text keeps primary/secondary/disabled contrast.
            // A terminal foreground used as a hierarchical style compounds
            // dimming, and using it as tint makes enabled controls look disabled.
            .foregroundStyle(.primary)
            .tint(Color.accentColor)
            .background(Color(palette.background))
            // Drive the subtree's semantic colors from the theme palette without
            // taking over the window appearance: preferredColorScheme pushes onto
            // the hosting NSWindow and would override an explicit window-theme
            // setting, while the environment key is what AppKit-backed controls
            // read when resolving primary/secondary colors.
            .environment(\.colorScheme, palette.colorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)) { notification in
                guard notification.object == nil,
                      let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config else { return }
                palette = OMGThemeBackground.palette(config: config)
            }
    }
}

extension View {
    @MainActor
    func omgThemedSurface(palette: OMGThemePalette) -> some View {
        modifier(OMGThemedSurface(palette: palette))
    }
}

/// A themed presentation adapter for OMG's two-button Git prompts. The existing
/// accessory controls and return codes are retained; no operation semantics move
/// into the presentation layer. System-owned alerts/file choosers remain native.
@MainActor
enum OMGThemeDialog {
    static func present(_ alert: NSAlert, for window: NSWindow?) async -> NSApplication.ModalResponse {
        precondition(alert.buttons.count == 2)
        let palette = OMGThemeBackground.palette(for: window)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = alert.messageText
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = palette.background
        panel.isOpaque = true
        panel.isReleasedWhenClosed = false
        if let accessory = alert.accessoryView { themeControls(accessory, palette: palette) }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                guard !finished else { return }
                finished = true
                if let window { window.endSheet(panel) } else { NSApp.stopModal() }
                panel.orderOut(nil)
                panel.contentViewController = nil
                continuation.resume(returning: response)
            }
            let host = OMGNativeDialogController(alert: alert, finish: finish)
            host.bindTheme(to: window)
            panel.contentViewController = host
            panel.setContentSize(host.view.fittingSize)
            if let window {
                window.beginSheet(panel) { _ in finish(.alertSecondButtonReturn) }
            } else {
                panel.center()
                NSApp.runModal(for: panel)
            }
        }
    }

    private static func themeControls(_ view: NSView, palette: OMGThemePalette) {
        if let field = view as? NSTextField {
            field.textColor = .labelColor
            if field.drawsBackground { field.backgroundColor = palette.sidebar }
        }
        view.subviews.forEach { themeControls($0, palette: palette) }
    }
}

/// The native grouped Form paints its own opaque system-gray canvas and cards.
/// Use explicit themed sections instead, with wrapping captions and no native
/// column layout (which can give long captions an unbounded horizontal size).
struct OMGSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
        .fixedSize(horizontal: false, vertical: true)
        .id(title)
    }
}

struct OMGSettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { configuration.content }
                .toggleStyle(OMGSettingsToggleStyle())
                .buttonStyle(OMGSettingsButtonStyle())
                .textFieldStyle(OMGSettingsTextFieldStyle())
                .controlSize(.small)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }
}
