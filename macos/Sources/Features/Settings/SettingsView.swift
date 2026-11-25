import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum OhMyGhosttySettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case tabs
    case terminal
    case controls
    case editor
    case keyboard
    case git
    case mobile
    case ssh
    case agents
    case advanced

    static let navigationOrder: [Self] = [
        .general, .appearance, .tabs, .terminal, .controls, .editor,
        .keyboard, .agents, .git, .mobile, .ssh, .advanced
    ]

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .tabs: "rectangle.split.3x1"
        case .terminal: "terminal"
        case .controls: "cursorarrow"
        case .editor: "curlybraces.square"
        case .keyboard: "keyboard"
        case .git: "point.3.connected.trianglepath.dotted"
        case .mobile: "iphone"
        case .ssh: "network"
        case .agents: "sparkles"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
final class OhMyGhosttySettingsWindowController: NSWindowController {
    private var appearanceCancellables: Set<AnyCancellable> = []

    init(
        settings: OhMyGhosttySettings,
        initialSelection: OhMyGhosttySettingsTab = .general
    ) {
        let root = NativeSettingsController(settings: settings, initialSelection: initialSelection)
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsStrings(language: settings.language).windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.contentViewController = root
        window.minSize = NSSize(width: 820, height: 540)
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.setFrameAutosaveName("OhMyGhosttySettingsWindow")
        // The autosave restore can carry a frame from before a minimum-size
        // change. Clamp it after restore so every page keeps usable columns.
        if window.frame.width < 820 || window.frame.height < 540 {
            window.setContentSize(NSSize(width: 900, height: 680))
        }
        root.updateChromeInsets()
        super.init(window: window)

        applyAppearance(settings)
        settings.objectWillChange.sink { [weak self, weak settings] _ in
            DispatchQueue.main.async {
                guard let self, let settings else { return }
                self.applyAppearance(settings)
            }
        }.store(in: &appearanceCancellables)
        // Re-apply when the app appearance changes (theme/config switches), so a
        // settings window opened before the change follows the new OMG theme.
        NSApp.publisher(for: \.effectiveAppearance).sink { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            self.applyAppearance(settings)
        }.store(in: &appearanceCancellables)
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .filter { $0.object == nil }
            .sink { [weak self, weak settings] _ in
                // The notification precedes replacement of the app's config.
                DispatchQueue.main.async {
                    guard let self, let settings else { return }
                    self.applyAppearance(settings)
                }
            }.store(in: &appearanceCancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // Capture the invoking terminal before Settings becomes the key window.
        let source = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { $0.windowController is TerminalController }
        if let screen = source?.screen, let window, window.screen != screen {
            window.setFrame(Self.frame(window.frame, on: screen.visibleFrame), display: false)
        }
        super.showWindow(sender)
    }

    static func frame(_ frame: NSRect, on visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(frame.width, visibleFrame.width),
            height: min(frame.height, visibleFrame.height)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func resolvedPalette(
        for settings: OhMyGhosttySettings,
        terminalPalette: OMGThemePalette? = nil,
        systemAppearance: NSAppearance? = nil
    ) -> (palette: OMGThemePalette, appearance: NSAppearance?) {
        let terminalPalette = terminalPalette ?? OMGThemeBackground.palette()
        let systemAppearance = systemAppearance ?? NSApp.effectiveAppearance
        let desiredScheme: ColorScheme
        let appearance: NSAppearance?
        switch settings.windowThemeOverride {
        case .light:
            desiredScheme = .light
            appearance = NSAppearance(named: .aqua)
        case .dark:
            desiredScheme = .dark
            appearance = NSAppearance(named: .darkAqua)
        case .system:
            let match = systemAppearance.bestMatch(from: [.aqua, .darkAqua])
            desiredScheme = match == .darkAqua ? .dark : .light
            appearance = nil
        case nil:
            desiredScheme = terminalPalette.colorScheme
            appearance = NSAppearance(named: desiredScheme == .dark ? .darkAqua : .aqua)
        }
        if terminalPalette.colorScheme == desiredScheme {
            return (terminalPalette, appearance)
        }
        let configuredTheme = desiredScheme == .light ? settings.lightThemeOverride : settings.darkThemeOverride
        if let configuredTheme,
           let sample = SettingsThemeSample.load(configuredTheme),
           sample.background.isLightColor == (desiredScheme == .light) {
            return (OMGThemePalette(background: sample.background, foreground: sample.foreground), appearance)
        }
        let fallback = desiredScheme == .light
            ? OMGThemePalette(
                background: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 1),
                foreground: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
            )
            : OMGThemePalette(
                background: NSColor(srgbRed: 0.125, green: 0.13, blue: 0.145, alpha: 1),
                foreground: NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
            )
        return (fallback, appearance)
    }

    private func applyAppearance(_ settings: OhMyGhosttySettings) {
        guard let window else { return }
        let title = SettingsStrings(language: settings.language).windowTitle
        if window.title != title {
            window.title = title
        }
        let resolved = Self.resolvedPalette(for: settings)
        window.backgroundColor = resolved.palette.background
        (window.contentViewController as? NativeSettingsController)?.applyPalette(resolved.palette)
        window.appearance = resolved.appearance
        window.contentView?.needsDisplay = true
    }
}

final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Compatibility entry point for previews; the live window owns this controller directly.
struct SettingsView: NSViewControllerRepresentable {
    let settings: OhMyGhosttySettings
    var initialSelection: OhMyGhosttySettingsTab = .general
    var palette: OMGThemePalette?
    var initialSearch = ""

    func makeNSViewController(context: Context) -> NativeSettingsController {
        let controller = NativeSettingsController(settings: settings, initialSelection: initialSelection)
        _ = controller.view
        if let palette {
            controller.applyPalette(palette)
            controller.view.appearance = NSAppearance(named: palette.colorScheme == .dark ? .darkAqua : .aqua)
        }
        controller.searchFor(initialSearch)
        return controller
    }
    func updateNSViewController(_ controller: NativeSettingsController, context: Context) {}
}
