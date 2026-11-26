import AppKit
import GhosttyKit

@MainActor
protocol OMGNativeThemeApplying: AnyObject {
    func applyTheme(_ theme: OMGNativeTheme)
}

/// One palette and state vocabulary for OMG-owned native surfaces and controls.
struct OMGNativeTheme: Equatable {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    var opacity: Double = 1 {
        didSet { configuredWantsBehindWindowBlur = nil }
    }
    var blur: Ghostty.Config.BackgroundBlur = .disabled {
        didSet { configuredWantsBehindWindowBlur = nil }
    }
    private var configuredWantsBehindWindowBlur: Bool?

    init(background: NSColor, foreground: NSColor, accent: NSColor = .controlAccentColor) {
        self.background = background.withAlphaComponent(1)
        self.foreground = foreground
        self.accent = accent
    }

    /// Configuration-level desire for non-opaque / behind-window blur/glass prior to
    /// any temporary Mission Control / off-Space opaque override, so auxiliary windows
    /// stay registered with `MissionControlPresentationMonitor` across Exposé.
    var wantsBehindWindowBlur: Bool {
        configuredWantsBehindWindowBlur ?? (blur.isGlassStyle || opacity < 1)
    }

    var secondary: NSColor { foreground.withAlphaComponent(0.62) }
    var disabled: NSColor { foreground.withAlphaComponent(0.30) }
    var border: NSColor { foreground.withAlphaComponent(0.14) }
    var controlFill: NSColor { foreground.withAlphaComponent(0.045) }
    var hoverFill: NSColor { foreground.withAlphaComponent(0.09) }
    var selectedFill: NSColor { accent.withAlphaComponent(0.17) }
    var appearance: NSAppearance? { NSAppearance(named: background.isLightColor ? .aqua : .darkAqua) }

    @MainActor
    static func resolve(
        for window: NSWindow?,
        presentationWindow: NSWindow? = nil,
        config: Ghostty.Config? = nil,
        missionControlMonitor: MissionControlPresentationMonitor = .shared
    ) -> OMGNativeTheme {
        let origin = window?.sheetParent ?? window
        let targetWindow = presentationWindow ?? origin
        let config = config ?? (origin?.windowController as? TerminalController)?.ghostty.config
            ?? (NSApp.delegate as? AppDelegate)?.ghostty.config
        guard let config else {
            var background = NSColor.windowBackgroundColor
            var foreground = NSColor.labelColor
            (origin?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                background = background.usingColorSpace(.deviceRGB) ?? background
                foreground = foreground.usingColorSpace(.deviceRGB) ?? foreground
            }
            return .init(background: background, foreground: foreground)
        }
        let palette = OMGThemeBackground.palette(for: origin, config: config)
        var theme = OMGNativeTheme(background: palette.background, foreground: palette.foreground,
                                   accent: config.nativeControlAccent(background: palette.background))
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let configForceOpaque = targetWindow?.styleMask.contains(.fullScreen) == true ||
            origin?.styleMask.contains(.fullScreen) == true ||
            (origin?.windowController as? TerminalController)?.isBackgroundOpaque == true ||
            reduceTransparency
        let configOpacity = config.backgroundOpacity.clamped(to: 0...1)
        let configBlur = config.backgroundBlur
        let wantsBehindWindowBlur = !configForceOpaque &&
            (configBlur.isGlassStyle || configOpacity < 1)
        let forceOpaque = configForceOpaque ||
            missionControlMonitor.shouldSuppressBehindWindowBlur(for: targetWindow)
        if !forceOpaque {
            theme.opacity = configOpacity
            theme.blur = configBlur
        }
        theme.configuredWantsBehindWindowBlur = wantsBehindWindowBlur
        return theme
    }

    @MainActor
    static func resolve(for view: NSView) -> OMGNativeTheme {
        var parent = view.superview
        while let current = parent {
            if let surface = current as? OMGNativeSurfaceView { return surface.theme }
            parent = current.superview
        }
        return resolve(for: view.window)
    }
}

/// Explicit popup origin avoids guessing the active window after a sheet becomes key.
@MainActor
final class OMGNativeThemeObserver: NSObject {
    weak var sourceWindow: NSWindow? {
        didSet {
            if oldValue !== sourceWindow {
                rebindWindowLifecycleObservers()
            }
        }
    }
    weak var hostWindow: NSWindow? {
        didSet {
            if oldValue !== hostWindow {
                rebindWindowLifecycleObservers()
            }
        }
    }
    var explicitConfig: Ghostty.Config?
    let missionControlMonitor: MissionControlPresentationMonitor
    private let notificationCenter: NotificationCenter
    private var windowTokens: [NSObjectProtocol] = []
    private var spaceToken: NSObjectProtocol?
    var onChange: ((OMGNativeTheme) -> Void)?

    init(
        missionControlMonitor: MissionControlPresentationMonitor = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.missionControlMonitor = missionControlMonitor
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.addObserver(self, selector: #selector(configChanged(_:)),
                                       name: .ghosttyConfigDidChange, object: nil)
        notificationCenter.addObserver(self, selector: #selector(missionControlChanged),
                                       name: MissionControlPresentationMonitor.didChangeNotification,
                                       object: missionControlMonitor)
        notificationCenter.addObserver(self, selector: #selector(missionControlChanged),
                                       name: MissionControlPresentationMonitor.windowSpaceOrStateDidSettleNotification,
                                       object: missionControlMonitor)
        spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWindowSpaceOrOcclusionChange() }
        }
    }

    deinit {
        for token in windowTokens {
            notificationCenter.removeObserver(token)
        }
        if let spaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceToken)
        }
        notificationCenter.removeObserver(self)
    }

    private func rebindWindowLifecycleObservers() {
        for token in windowTokens {
            notificationCenter.removeObserver(token)
        }
        windowTokens.removeAll()
        var targets: [NSWindow] = []
        if let sourceWindow { targets.append(sourceWindow) }
        if let hostWindow, hostWindow !== sourceWindow { targets.append(hostWindow) }
        for target in targets {
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                windowTokens.append(
                    notificationCenter.addObserver(
                        forName: name,
                        object: target,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.handleWindowSpaceOrOcclusionChange() }
                    }
                )
            }
        }
    }

    private func handleWindowSpaceOrOcclusionChange() {
        let effectiveWindow = hostWindow ?? sourceWindow
        missionControlMonitor.refreshBeforeWindowAppearanceSync(for: effectiveWindow)
        refresh()
    }

    func refresh() {
        onChange?(
            OMGNativeTheme.resolve(
                for: sourceWindow ?? hostWindow,
                presentationWindow: hostWindow,
                config: explicitConfig,
                missionControlMonitor: missionControlMonitor
            )
        )
    }

    @objc private func missionControlChanged() { refresh() }

    @objc private func configChanged(_ notification: Notification) {
        if let object = notification.object as AnyObject? {
            guard object === sourceWindow || object === sourceWindow?.windowController else { return }
        }
        let config = (notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config)
            ?? explicitConfig
        onChange?(
            OMGNativeTheme.resolve(
                for: sourceWindow ?? hostWindow,
                presentationWindow: hostWindow,
                config: config,
                missionControlMonitor: missionControlMonitor
            )
        )
    }
}

class OMGNativeSurfaceView: NSView {
    /// Embedded chrome inherits the terminal backdrop; only popup roots paint one.
    var paintsBackground = true { didSet { updateBackdrop(); needsDisplay = true } }
    private let themeObserver: OMGNativeThemeObserver
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    var onThemeChange: ((OMGNativeTheme) -> Void)?
    private var hasExplicitSource = false
    private var backdrop: NSView?
    private var backdropBlur: Ghostty.Config.BackgroundBlur?

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, missionControlMonitor: .shared, notificationCenter: .default)
    }

    init(
        frame frameRect: NSRect,
        missionControlMonitor: MissionControlPresentationMonitor,
        notificationCenter: NotificationCenter = .default
    ) {
        self.themeObserver = OMGNativeThemeObserver(
            missionControlMonitor: missionControlMonitor,
            notificationCenter: notificationCenter
        )
        super.init(frame: frameRect)
        wantsLayer = true
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }

    func bindTheme(to window: NSWindow?, config: Ghostty.Config? = nil) {
        hasExplicitSource = true
        themeObserver.sourceWindow = window
        themeObserver.explicitConfig = config
        themeObserver.refresh()
    }

    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        appearance = theme.appearance
        needsDisplay = true
        updateBackdrop()
        func update(_ parent: NSView) {
            for child in parent.subviews {
                if child === backdrop { continue }
                if let customized = child as? OMGNativeThemeApplying {
                    customized.applyTheme(theme)
                    continue
                }
                if let surface = child as? OMGNativeSurfaceView {
                    surface.applyTheme(theme)
                    continue
                }
                if let button = child as? NativeActionControl { button.applyTheme(theme) }
                if let search = child as? OMGNativeSearchField { search.applyTheme(theme) }
                if let field = child as? NSTextField, !(field is NSSearchField) {
                    // Preserve semantic error/warning/success colors owned by a form.
                    if ![NSColor.systemRed, .systemOrange, .systemGreen].contains(where: { $0 == field.textColor }) {
                        field.textColor = theme.foreground
                    }
                    if field.isEditable { field.backgroundColor = theme.background; field.focusRingType = .none }
                }
                child.needsDisplay = true
                update(child)
            }
        }
        update(self)
        onThemeChange?(theme)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.hostWindow = window
        if !hasExplicitSource { themeObserver.sourceWindow = window }
        themeObserver.refresh()
    }

    @objc private func accessibilityChanged() { updateBackdrop(); needsDisplay = true }

    var effectiveOpacity: Double { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : theme.opacity }

    private func updateBackdrop() {
        let blur: Ghostty.Config.BackgroundBlur = !paintsBackground || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ||
            (effectiveOpacity >= 1 && !theme.blur.isGlassStyle) ? .disabled : theme.blur
        if backdropBlur != blur {
            backdrop?.removeFromSuperview()
            backdrop = nil
            backdropBlur = blur
#if compiler(>=6.2)
            if #available(macOS 26.0, *), blur.isGlassStyle {
                backdrop = TerminalGlassView(topOffset: 0)
            } else if case .radius(let radius) = blur, radius > 0 {
                backdrop = TerminalBackdropBlurView(topOffset: 0)
            }
#else
            if case .radius(let radius) = blur, radius > 0 {
                backdrop = TerminalBackdropBlurView(topOffset: 0)
            }
#endif
            if let backdrop {
                backdrop.frame = bounds
                backdrop.autoresizingMask = [.width, .height]
                addSubview(backdrop, positioned: .below, relativeTo: nil)
            }
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backdrop as? TerminalGlassView {
            glass.configure(style: blur == .macosGlassClear ? .clear : .regular,
                            backgroundColor: theme.background, backgroundOpacity: effectiveOpacity,
                            cornerRadius: 0, isKeyWindow: window?.isKeyWindow ?? true)
        }
#endif
        if let blurView = backdrop as? TerminalBackdropBlurView, case .radius(let radius) = blur {
            blurView.configure(
                radius: radius,
                backgroundColor: theme.background,
                backgroundOpacity: effectiveOpacity,
                cornerRadius: 0
            )
        }
        // Only configure an auxiliary window owned by this surface, never its terminal origin.
        if paintsBackground, let window, window.contentViewController?.view === self ||
            (hasExplicitSource && window !== themeObserver.sourceWindow) {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            let wantsBlur = !reduceTransparency && theme.wantsBehindWindowBlur
            let monitor = themeObserver.missionControlMonitor
            monitor.updateWindowEligibility(
                window,
                wantsBehindWindowBlur: wantsBlur
            )
            let isAuxOpaque = reduceTransparency ||
                (effectiveOpacity >= 1 && !blur.isGlassStyle) ||
                monitor.shouldSuppressBehindWindowBlur(for: window)
            window.isOpaque = isAuxOpaque
            window.setAutoFlattenLayerTreeEnabled(!wantsBlur || isAuxOpaque)
            window.backgroundColor = isAuxOpaque ? theme.background : theme.background.withAlphaComponent(0.001)
        }
    }

    override func updateLayer() {
        let usesGlassBackdrop: Bool
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            usesGlassBackdrop = backdrop is TerminalGlassView
        } else {
            usesGlassBackdrop = false
        }
#else
        usesGlassBackdrop = false
#endif
        let solidFill = paintsBackground && !usesGlassBackdrop && effectiveOpacity >= 1
        layer?.isOpaque = solidFill
        layer?.backgroundColor = (paintsBackground && !usesGlassBackdrop ? theme.background.withAlphaComponent(effectiveOpacity) : .clear).cgColor
    }
}

class OMGNativeSearchField: NSSearchField {
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    private let themeObserver = OMGNativeThemeObserver()
    private var hovered = false
    private var tracking: NSTrackingArea?
    var isInputFocused: Bool { currentEditor() != nil }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = OMGNativeSearchCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = false
        focusRingType = .none
        controlSize = .small
        font = .systemFont(ofSize: 11)
        sendsSearchStringImmediately = true
        sendsWholeSearchString = false
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        textColor = theme.foreground
        if let placeholder = placeholderAttributedString?.string ?? placeholderString {
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: theme.secondary,
            ])
        }
        (currentEditor() as? NSTextView)?.textColor = theme.foreground
        (currentEditor() as? NSTextView)?.drawsBackground = false
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window
        applyTheme(.resolve(for: self))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    fileprivate func drawSurface(in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (hovered && isEnabled ? theme.hoverFill : theme.controlFill).setFill()
        shape.fill()
        (isInputFocused ? theme.accent.withAlphaComponent(0.5) : theme.border).setStroke()
        shape.lineWidth = isInputFocused ? 1 : 0.5
        shape.stroke()
    }
}

private final class OMGNativeSearchCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        (controlView as? OMGNativeSearchField)?.drawSurface(in: cellFrame)
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}
