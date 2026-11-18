import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    /// Behind-window CoreAnimation blur view for classic radius/boolean blur modes
    private(set) var backdropBlurView: TerminalBackdropBlurView?
    private var derivedConfig: DerivedConfig?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    var shouldReduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        let hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            return initialContentSize
        }
        return hostingSize
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    func ghosttyConfigDidChange(
        _ config: Ghostty.Config,
        preferredBackgroundColor: NSColor?,
        isWindowOpaque: Bool = false,
        immediately: Bool = false
    ) {
        let newValue = DerivedConfig(
            config: config,
            preferredBackgroundColor: preferredBackgroundColor,
            cornerRadius: windowCornerRadius,
            isWindowOpaque: isWindowOpaque,
            reduceTransparency: shouldReduceTransparency
        )
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach or detach synchronously when missing, when forcing opaque
        // (e.g. fullscreen / Mission Control), or when explicitly requested
        // outside SwiftUI's render pass so window.isOpaque and the backdrop
        // view never diverge for a frame.
        if immediately || newValue == nil || (glassEffectView == nil && backdropBlurView == nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateGlassEffectIfNeeded()
            CATransaction.commit()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass & Backdrop Blur

/// Behind-window CoreAnimation backdrop blur (`NSVisualEffectView` / `CABackdropLayer`)
/// used for classic `background-blur = true` / `<radius>` configurations instead of
/// legacy private `CGSSetWindowBackgroundBlurRadius`, which washes out to gray and
/// flickers inside macOS Tahoe Mission Control when fullscreen spaces exist (`ghostty#9542`).
final class TerminalBackdropBlurView: NSView {
    private(set) var clipView: NSView
    private(set) var effectView: NSVisualEffectView
    private var topConstraint: NSLayoutConstraint!

    init(topOffset: CGFloat) {
        self.clipView = NSView()
        self.effectView = NSVisualEffectView()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Clip and round on the wrapper view rather than mutating
        // `NSVisualEffectView.layer` directly, keeping AppKit's internal
        // CUI `CABackdropLayer` hierarchy untouched.
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.clipsToBounds = true
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        clipView.addSubview(effectView)

        topConstraint = clipView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: clipView.topAnchor),
            effectView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        radius: Int,
        backgroundColor: NSColor,
        backgroundOpacity: Double = 0.85,
        cornerRadius: CGFloat?
    ) {
        let isLight = backgroundColor.isLightColor
        let blurStrength = min(1.0, max(0.0, CGFloat(radius) / 20.0))
        let clampedOpacity = min(1.0, max(0.0, CGFloat(backgroundOpacity)))
        effectView.material = .hudWindow
        effectView.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        effectView.alphaValue = blurStrength
        clipView.layer?.cornerRadius = cornerRadius ?? 0
        // Prevent raw `.clear` punch-through when `radius < 20` reduces
        // `effectView.alphaValue` below 1.0.
        let fallbackAlpha = (1.0 - blurStrength) * clampedOpacity * 0.35
        clipView.layer?.backgroundColor = fallbackAlpha > 0.001
            ? backgroundColor.withAlphaComponent(fallbackAlpha).cgColor
            : nil
    }

    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    func configure(
        style: BackportGlass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
        isKeyWindow _: Bool = true
    ) {
        configure(
            glass: style.official,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            cornerRadius: cornerRadius
        )
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func addBackdropBlurViewIfNeeded() -> TerminalBackdropBlurView? {
        if let existed = backdropBlurView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalBackdropBlurView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        backdropBlurView = effectView
        return effectView
    }

    private func updateGlassEffectIfNeeded() {
        guard let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            backdropBlurView?.removeFromSuperview()
            backdropBlurView = nil
            return
        }

        switch derivedConfig.effect {
        case .glass(let glass):
            backdropBlurView?.removeFromSuperview()
            backdropBlurView = nil
#if compiler(>=6.2)
            guard #available(macOS 26.0, *), let effectView = addGlassEffectViewIfNeeded() else {
                glassEffectView?.removeFromSuperview()
                glassEffectView = nil
                return
            }
            effectView.configure(
                glass: glass.official,
                backgroundColor: derivedConfig.backgroundColor,
                backgroundOpacity: derivedConfig.backgroundOpacity,
                cornerRadius: derivedConfig.cornerRadius
            )
#else
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
#endif
        case .blur(let radius):
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            guard let effectView = addBackdropBlurViewIfNeeded() else { return }
            effectView.configure(
                radius: radius,
                backgroundColor: derivedConfig.backgroundColor,
                backgroundOpacity: derivedConfig.backgroundOpacity,
                cornerRadius: derivedConfig.cornerRadius
            )
        }
    }

    private func updateGlassEffectTopInsetIfNeeded() {
        guard let themeFrameView = windowThemeFrameView else { return }
        let inset = -themeFrameView.safeAreaInsets.top
        backdropBlurView?.updateTopInset(inset)
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let effectView = glassEffectView as? TerminalGlassView {
            effectView.updateTopInset(inset)
        }
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        enum Effect: Equatable {
            case glass(BackportGlass)
            case blur(radius: Int)
        }

        let effect: Effect
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(
            config: Ghostty.Config,
            preferredBackgroundColor: NSColor?,
            cornerRadius: CGFloat?,
            isWindowOpaque: Bool = false,
            reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ) {
            guard !isWindowOpaque else { return nil }
            switch config.backgroundBlur {
            case .macosGlassRegular:
                effect = .glass(.regular)
            case .macosGlassClear:
                effect = .glass(.clear)
            case .radius(let radius) where radius > 0
                && config.backgroundOpacity < 1
                && !reduceTransparency:
                effect = .blur(radius: radius)
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
