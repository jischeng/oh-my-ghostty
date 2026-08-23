import AppKit
import Combine
import SwiftUI

/// A terminal window that keeps AppKit tab grouping but renders tabs in the content sidebar.
final class VerticalTabsTerminalWindow: TransparentTitlebarTerminalWindow {
    override var supportsUpdateAccessory: Bool { false }

    private let sidebarToggleAccessory = NSTitlebarAccessoryViewController()
    private var sidebarToggleWidthConstraint: NSLayoutConstraint?
    private var titlebarDividerCancellable: AnyCancellable?
    private(set) var nativeTabBarRejectionCount = 0

    override func awakeFromNib() {
        super.awakeFromNib()
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var title: String {
        didSet { titleVisibility = .hidden }
    }

    override func becomeMain() {
        super.becomeMain()
        titleVisibility = .hidden
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        titleVisibility = .hidden
    }

    func installSidebarToggle(controller: TerminalController) {
        let isInstalled = titlebarAccessoryViewControllers.contains(sidebarToggleAccessory)
        sidebarToggleAccessory.layoutAttribute = .left
        sidebarToggleAccessory.view = AlignedTitlebarControlsView(
            rootView: VerticalTabsTitlebarControls(
                layoutState: controller.tabLayoutState,
                toggleSidebar: { [weak controller] in controller?.toggleSidebar(nil) },
                newTab: { [weak controller] in controller?.newVerticalTab() }
            )
        )
        if !isInstalled {
            addTitlebarAccessoryViewController(sidebarToggleAccessory)
        }
        sidebarToggleAccessory.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleWidthConstraint?.isActive = false
        let widthConstraint = sidebarToggleAccessory.view.widthAnchor.constraint(
            equalToConstant: 58
        )
        sidebarToggleWidthConstraint = widthConstraint
        widthConstraint.isActive = true
        installTitlebarSidebarDivider(layoutState: controller.tabLayoutState)
    }

    override func addTitlebarAccessoryViewController(
        _ childViewController: NSTitlebarAccessoryViewController
    ) {
        // AppKit creates this controller before displaying its horizontal tab strip.
        // Keep the NSWindowTabGroup, but never let the strip enter our view hierarchy.
        guard !isTabBar(childViewController) else {
            nativeTabBarRejectionCount += 1
            return
        }
        super.addTitlebarAccessoryViewController(childViewController)
    }

    var sidebarToggleIsInstalled: Bool {
        titlebarAccessoryViewControllers.contains(sidebarToggleAccessory)
    }

    var titlebarControlsCenterY: CGFloat? {
        (sidebarToggleAccessory.view as? TitlebarControlsCentering)?.contentCenterYInWindow
    }

    var titlebarControlsHeight: CGFloat? {
        guard sidebarToggleAccessory.view.window != nil else { return nil }
        return sidebarToggleAccessory.view.bounds.height
    }

    var titlebarSidebarDividerCenterX: CGFloat? {
        guard sidebarToggleAccessory.view.window != nil else { return nil }
        return sidebarToggleAccessory.view.convert(
            NSPoint(
                x: sidebarToggleAccessory.view.bounds.maxX -
                    TerminalShellStyle.resizeHitWidth / 2,
                y: sidebarToggleAccessory.view.bounds.midY
            ),
            to: nil
        ).x
    }

    var trafficLightsCenterY: CGFloat? {
        let buttons = [
            standardWindowButton(.closeButton),
            standardWindowButton(.miniaturizeButton),
            standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        guard !buttons.isEmpty else { return nil }
        let centers = buttons.compactMap { button -> CGFloat? in
            guard let superview = button.superview else { return nil }
            return superview.convert(
                NSPoint(x: button.frame.midX, y: button.frame.midY),
                to: nil
            ).y
        }
        guard !centers.isEmpty else { return nil }
        return centers.reduce(0, +) / CGFloat(centers.count)
    }

    var nativeTabBarIsSuppressed: Bool {
        !titlebarAccessoryViewControllers.contains(where: isTabBar) && tabBarView == nil
    }

    private func installTitlebarSidebarDivider(
        layoutState: VerticalTabWindowLayoutState
    ) {
        let resizeChanges = NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification,
            object: self
        )
        .map { _ in () }
        .prepend(())
        titlebarDividerCancellable = Publishers.CombineLatest(
            Publishers.CombineLatest(
                layoutState.$sidebarWidth,
                layoutState.$isSidebarVisible
            ),
            resizeChanges
        )
        .sink { [weak self] layout, _ in
            guard let self else { return }
            let (width, visible) = layout
            DispatchQueue.main.async { [weak self] in
                guard let self, let contentView else { return }
                let accessoryView = sidebarToggleAccessory.view
                let accessoryOriginX = accessoryView.convert(
                    NSPoint(x: accessoryView.bounds.minX, y: accessoryView.bounds.midY),
                    to: nil
                ).x
                let sidebarTrailingX = contentView.convert(
                    NSPoint(
                        x: width + TerminalShellStyle.resizeHitWidth,
                        y: contentView.bounds.midY
                    ),
                    to: nil
                ).x
                sidebarToggleWidthConstraint?.constant = visible
                    ? max(58, sidebarTrailingX - accessoryOriginX)
                    : 58
                titlebarContainer?.layoutSubtreeIfNeeded()
            }
        }
    }
}

protocol TitlebarControlsCentering {
    var contentCenterYInWindow: CGFloat? { get }
}

final class AlignedTitlebarControlsView<Content: View>: NSView, TitlebarControlsCentering {
    private static var fallbackHeight: CGFloat { 28 }

    private let hostingView: NSHostingView<Content>
    private let contentWidth: CGFloat

    init(width: CGFloat = 58, rootView: Content) {
        self.contentWidth = width
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: width,
            height: Self.fallbackHeight
        ))
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth, height: titlebarHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: bounds.width, height: bounds.height)
        let centerY = trafficLightsCenterYInLocalCoordinates ?? bounds.midY
        hostingView.frame = NSRect(
            x: bounds.minX,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    var contentCenterYInWindow: CGFloat? {
        guard window != nil else { return nil }
        return convert(
            NSPoint(x: hostingView.frame.midX, y: hostingView.frame.midY),
            to: nil
        ).y
    }

    private var titlebarHeight: CGFloat {
        guard let titlebarContainer = (window as? TerminalWindow)?.titlebarContainer else {
            return Self.fallbackHeight
        }
        return max(Self.fallbackHeight, titlebarContainer.bounds.height)
    }

    private var trafficLightsCenterYInLocalCoordinates: CGFloat? {
        guard let window else { return nil }
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        let centers = buttons.compactMap { button -> CGFloat? in
            guard let superview = button.superview else { return nil }
            let centerInWindow = superview.convert(
                NSPoint(x: button.frame.midX, y: button.frame.midY),
                to: nil
            )
            return convert(centerInWindow, from: nil).y
        }
        guard !centers.isEmpty else { return nil }
        return centers.reduce(0, +) / CGFloat(centers.count)
    }
}

private struct VerticalTabsTitlebarControls: View {
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    let toggleSidebar: () -> Void
    let newTab: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: SidebarToolbarStyle.itemSpacing) {
                SidebarIconButton(
                    systemName: "sidebar.left",
                    help: layoutState.isSidebarVisible ? "Hide Tabs" : "Show Tabs",
                    action: toggleSidebar
                )
                SidebarIconButton(
                    systemName: "plus",
                    help: "New Tab",
                    action: newTab
                )
                Spacer(minLength: 0)
            }
            if layoutState.isSidebarVisible {
                TerminalSidebarDividerLine()
                    .frame(width: TerminalShellStyle.resizeHitWidth)
            }
        }
    }
}
