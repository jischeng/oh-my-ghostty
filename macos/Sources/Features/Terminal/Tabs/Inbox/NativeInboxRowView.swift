import AppKit
import Combine

private let tabPresentationDidChangeNotification = Notification.Name("GhosttyTabPresentationDidChange")

/// Subtle 18×18pt close control rendered at the trailing edge of a hovered sidebar row.
/// Shows a plain `xmark` glyph on row hover and paints a subtle circular backing only
/// when the pointer is directly over (or pressing) the close button itself.
@MainActor
final class NativeInboxCloseButton: NSButton {
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    private var activePress: Bool {
        isPressed || (isHighlighted && NativePointerLocation.contains(self))
    }

    var showsHoverDisc: Bool { isHovered || activePress }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                isHovered = false
                isPressed = false
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        target = self
        action = #selector(invokePress)
        setAccessibilityRole(.button)
        setAccessibilityLabel(ChromeStrings.current.closeTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invokePress() {
        onPress?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingArea == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            trackingArea = area
            addTrackingArea(area)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
        isPressed = false
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        isHovered = false
        isPressed = false
    }

    override func mouseEntered(with event: NSEvent) {
        guard NativePointerLocation.contains(self, event: event) else {
            isHovered = false
            return
        }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = OMGNativeTheme.resolve(for: self)
        if showsHoverDisc {
            let bgAlpha: CGFloat = activePress ? 0.16 : 0.10
            theme.foreground.withAlphaComponent(bgAlpha).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }

        guard let base = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold)) else { return }
        let tint = showsHoverDisc ? theme.foreground : theme.secondary
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.withAlphaComponent(1).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        let scale = max(base.size.width, base.size.height) > 0
            ? min(1, 10 / max(base.size.width, base.size.height)) : 1
        let width = base.size.width * scale
        let height = base.size.height * scale
        let glyphRect = NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        tinted.draw(
            in: glyphRect,
            from: .zero,
            operation: .sourceOver,
            fraction: tint.alphaComponent,
            respectFlipped: true,
            hints: nil
        )
    }
}

/// Authentic Otty-style session row for the AppKit Inbox (`36pt` single-line, `52pt` two-line).
/// All Line-1 elements sit on `midY = 18pt`, Line-2 paths start flush-left beneath `iconView` at `x = 10pt`,
/// and hover and selection share the exact `bounds` pill (`cornerRadius = 8pt`).
@MainActor
final class NativeInboxRowView: NSView {
    static let cornerRadius = NativeInboxMetrics.rowCornerRadius

    let iconView = NativeTabIconView()
    let remoteCloudView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let statusView = NSImageView()
    let shortcutLabel = NSTextField(labelWithString: "")
    let closeButton = NativeInboxCloseButton()
    let subtitleCloudView = NSImageView()
    let subtitleLabel = NSTextField(labelWithString: "")

    private let themeObserver = OMGNativeThemeObserver()
    private var observations = Set<AnyCancellable>()
    private var surfaceObservations = Set<AnyCancellable>()
    private(set) var configuredTab: GhosttyOrganizedTab?
    private var presentationProvider: ((GhosttyOrganizedTab) -> GhosttyTabPresentation?)?
    private var refreshScheduled = false
    private var trackingClosePress = false

    private(set) var showsSubtitle = false
    private(set) var subtitleIsRemote = false
    private(set) var hasRemoteBreadcrumb = false
    private(set) var hasStatusBadge = false
    private(set) var trailingAccessory: NativeTabTrailingAccessory = .none

    var canClose = false {
        didSet {
            guard oldValue != canClose else { return }
            updateTrailingVisibility()
        }
    }

    var isCommandHeld = false {
        didSet {
            guard oldValue != isCommandHeld else { return }
            updateTrailingVisibility()
        }
    }

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            refreshPresentationNow(notifyHeightChange: false)
            needsDisplay = true
        }
    }

    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            if !isHovered { closeButton.isHovered = false }
            updateTrailingVisibility()
            needsDisplay = true
        }
    }

    var isCloseHovered: Bool {
        get { closeButton.isHovered }
        set { closeButton.isHovered = newValue }
    }

    var selectAction: (() -> Void)?
    var doubleClickAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    var onHeightPreferenceChange: (() -> Void)?

    override var isFlipped: Bool { true }

    /// Both hover and selection paint the exact same pill rect (`row.bounds`).
    var highlightRect: NSRect { bounds }
    var selectionRect: NSRect { bounds }
    var hoverRect: NSRect { bounds }

    var preferredHeight: CGFloat {
        showsSubtitle ? NativeInboxMetrics.twoLineRowHeight : NativeInboxMetrics.singleLineRowHeight
    }

    var closeButtonHitRect: NSRect {
        closeButton.isHidden ? .zero : closeButton.frame
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconView.customSizing = NativeInboxMetrics.iconSizing

        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.alignment = .right

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.isHidden = true

        let cloudImage = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .regular))
        for cloud in [remoteCloudView, subtitleCloudView] {
            cloud.image = cloudImage
            cloud.imageScaling = .scaleProportionallyDown
            cloud.isHidden = true
        }

        statusView.imageScaling = .scaleProportionallyDown
        statusView.isHidden = true
        shortcutLabel.isHidden = true
        closeButton.isHidden = true
        closeButton.onPress = { [weak self] in
            self?.closeAction?()
        }

        for child in [
            iconView, remoteCloudView, titleLabel, statusView,
            shortcutLabel, closeButton, subtitleCloudView, subtitleLabel,
        ] {
            addSubview(child)
        }

        themeObserver.onChange = { [weak self] _ in
            guard let self else { return }
            self.applyTheme()
            self.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window
        applyTheme()
        needsDisplay = true
    }

    func configure(
        tab: GhosttyOrganizedTab,
        selected: Bool,
        canClose: Bool,
        presentation: @escaping (GhosttyOrganizedTab) -> GhosttyTabPresentation?
    ) {
        closeButton.setAccessibilityLabel(ChromeStrings.current.closeTab)
        let changedController = configuredTab?.controller !== tab.controller
        if changedController {
            observations.removeAll()
            surfaceObservations.removeAll()
        }
        configuredTab = tab
        presentationProvider = presentation
        isSelected = selected
        self.canClose = canClose
        if changedController {
            observe(tab.controller)
        }
        refreshPresentationNow(notifyHeightChange: false)
    }

    private func observe(_ controller: TerminalController) {
        controller.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &observations)
        controller.$surfaceTree
            .sink { [weak self] tree in
                guard let self else { return }
                self.observeSurfaces(in: tree)
                self.scheduleRefresh()
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: tabPresentationDidChangeNotification)
            .sink { [weak self, weak controller] note in
                guard let self, let controller else { return }
                if let sender = note.object as? BaseTerminalController, sender !== controller { return }
                if let surface = note.object as? Ghostty.SurfaceView,
                   !controller.surfaceTree.contains(where: { $0 === surface }) { return }
                self.scheduleRefresh()
            }
            .store(in: &observations)
    }

    private func observeSurfaces(in tree: SplitTree<Ghostty.SurfaceView>) {
        surfaceObservations.removeAll()
        for surface in tree {
            surface.$title.sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &surfaceObservations)
            surface.$pwd.sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &surfaceObservations)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshPresentationNow(notifyHeightChange: true)
        }
    }

    func refreshPresentationNow(notifyHeightChange: Bool) {
        guard let tab = configuredTab, let presentationProvider,
              let value = presentationProvider(tab) else { return }
        let previousShowsSubtitle = showsSubtitle
        let detail = value.showsSubtitle ? value.subtitle : nil
        showsSubtitle = detail != nil
        subtitleIsRemote = detail != nil && value.subtitleIsRemote
        hasRemoteBreadcrumb = detail == nil && value.remoteBreadcrumb != nil

        let displayTitle = value.remoteBreadcrumb?.title ?? value.title
        let titleWeight: NSFont.Weight = (isSelected || value.selected) ? .medium : .regular
        titleLabel.font = .systemFont(ofSize: 13, weight: titleWeight)
        titleLabel.lineBreakMode = showsSubtitle ? .byTruncatingTail : .byTruncatingMiddle
        titleLabel.stringValue = displayTitle

        subtitleLabel.stringValue = detail ?? ""
        subtitleLabel.isHidden = detail == nil
        subtitleCloudView.isHidden = !subtitleIsRemote
        remoteCloudView.isHidden = !hasRemoteBreadcrumb

        shortcutLabel.stringValue = value.shortcut ?? ""
        iconView.customSizing = NativeInboxMetrics.iconSizing
        iconView.configure(
            controller: tab.controller,
            icon: value.icon,
            selected: isSelected,
            activity: value.activity
        )

        let badge = AgentStatusBadge.resolve(value.activity)
        hasStatusBadge = badge != nil
        statusView.image = badge.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        statusView.contentTintColor = badge?.color
        statusView.toolTip = value.activity.map(AgentLogoStyle.localizedStatus)

        let headerTitle = detail.map { "\(displayTitle)\n\($0)" } ?? displayTitle
        toolTip = value.toolTip ?? AgentLogoStyle.toolTip(title: headerTitle, activity: value.activity)
        setAccessibilityRole(.row)
        setAccessibilityLabel(detail.map { "\(displayTitle), \($0)" } ?? displayTitle)

        applyTheme()
        updateTrailingVisibility()
        needsLayout = true
        if notifyHeightChange && previousShowsSubtitle != showsSubtitle {
            onHeightPreferenceChange?()
        }
    }

    private func applyTheme() {
        let theme = OMGNativeTheme.resolve(for: self)
        titleLabel.textColor = theme.foreground
        subtitleLabel.textColor = theme.secondary
        shortcutLabel.textColor = theme.foreground.withAlphaComponent(0.45)
        remoteCloudView.contentTintColor = theme.secondary
        subtitleCloudView.contentTintColor = theme.secondary
    }

    func updateTrailingVisibility() {
        let next = NativeTabTrailingAccessory.resolve(
            isHovered: isHovered,
            canClose: canClose,
            isCommandHeld: isCommandHeld,
            hasShortcut: !shortcutLabel.stringValue.isEmpty,
            hasStatus: hasStatusBadge
        )
        trailingAccessory = next
        closeButton.isHidden = next != .close
        shortcutLabel.isHidden = next != .shortcut
        statusView.isHidden = next != .status
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = NativeInboxMetrics.rowHorizontalPadding
        let topMidY = showsSubtitle ? NativeInboxMetrics.twoLineTopMidY : NativeInboxMetrics.singleLineMidY
        if iconView.customSizing != NativeInboxMetrics.iconSizing {
            iconView.customSizing = NativeInboxMetrics.iconSizing
        }
        let iconEdge = NativeInboxMetrics.iconSize
        iconView.frame = NSRect(
            x: pad,
            y: topMidY - iconEdge / 2,
            width: iconEdge,
            height: iconEdge
        )
        iconView.layoutSubtreeIfNeeded()

        let rightEdge = max(pad, bounds.width - pad)
        let closeEdge = NativeInboxMetrics.closeButtonSize
        closeButton.frame = NSRect(
            x: rightEdge - closeEdge,
            y: topMidY - closeEdge / 2,
            width: closeEdge,
            height: closeEdge
        )

        let shortcutSize = shortcutLabel.isHidden ? .zero : shortcutLabel.fittingSize
        shortcutLabel.frame = NSRect(
            x: rightEdge - shortcutSize.width,
            y: topMidY - shortcutSize.height / 2,
            width: shortcutSize.width,
            height: shortcutSize.height
        )

        let statusEdge = NativeInboxMetrics.statusBadgeSize
        let statusX = rightEdge - (closeEdge + statusEdge) / 2
        statusView.frame = statusView.isHidden
            ? .zero
            : NSRect(
                x: statusX,
                y: topMidY - statusEdge / 2,
                width: statusEdge,
                height: statusEdge
            )

        let titleMaxX: CGFloat
        switch trailingAccessory {
        case .close:
            titleMaxX = closeButton.frame.minX - 6
        case .shortcut:
            titleMaxX = shortcutLabel.frame.minX - 6
        case .status:
            titleMaxX = statusView.frame.minX - 6
        case .none:
            titleMaxX = rightEdge
        }

        var titleX = NativeInboxMetrics.textLeadingX
        if hasRemoteBreadcrumb {
            remoteCloudView.frame = NSRect(
                x: titleX,
                y: topMidY - NativeInboxMetrics.cloudIconHeight / 2,
                width: NativeInboxMetrics.cloudIconWidth,
                height: NativeInboxMetrics.cloudIconHeight
            )
            titleX = remoteCloudView.frame.maxX + NativeInboxMetrics.cloudIconGap
        } else {
            remoteCloudView.frame = .zero
        }

        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: topMidY - titleSize.height / 2,
            width: max(0, titleMaxX - titleX),
            height: titleSize.height
        )

        guard showsSubtitle else {
            subtitleCloudView.frame = .zero
            subtitleLabel.frame = .zero
            return
        }

        let bottomMidY = NativeInboxMetrics.twoLineBottomMidY
        var subX = NativeInboxMetrics.subtitleLeadingX
        if subtitleIsRemote {
            subtitleCloudView.frame = NSRect(
                x: subX,
                y: bottomMidY - NativeInboxMetrics.cloudIconHeight / 2,
                width: NativeInboxMetrics.cloudIconWidth,
                height: NativeInboxMetrics.cloudIconHeight
            )
            subX = subtitleCloudView.frame.maxX + NativeInboxMetrics.cloudIconGap
        } else {
            subtitleCloudView.frame = .zero
        }
        let subtitleSize = subtitleLabel.fittingSize
        subtitleLabel.frame = NSRect(
            x: subX,
            y: bottomMidY - subtitleSize.height / 2,
            width: max(0, rightEdge - subX),
            height: subtitleSize.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered, !bounds.isEmpty else { return }
        let theme = OMGNativeTheme.resolve(for: self)
        let fill = isSelected ? theme.selectedFill : theme.hoverFill
        fill.setFill()
        NSBezierPath(
            roundedRect: highlightRect,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        ).fill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden && closeButtonHitRect.contains(point) {
            trackingClosePress = true
            closeButton.isPressed = true
            return
        }
        trackingClosePress = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard trackingClosePress else { return }
        let point = convert(event.locationInWindow, from: nil)
        closeButton.isPressed = closeButtonHitRect.contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if trackingClosePress {
            let insideClose = closeButtonHitRect.contains(point)
            trackingClosePress = false
            closeButton.isPressed = false
            if insideClose { closeAction?() }
            return
        }
        guard bounds.contains(point) else { return }
        if event.clickCount == 2 {
            doubleClickAction?()
        } else {
            selectAction?()
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, canClose else {
            super.otherMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        closeAction?()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        selectAction?()
        return true
    }
}
