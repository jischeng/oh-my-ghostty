import AppKit

/// Shared Otty-inspired geometry for the flipped-document AppKit Inbox sidebar.
enum NativeInboxMetrics {
    static let sidebarHorizontalMargin: CGFloat = 8
    static let topContentPadding: CGFloat = 2
    static let bottomContentPadding: CGFloat = 8

    static let sectionHeaderHeight: CGFloat = 26
    static let sectionTopMargin: CGFloat = 6
    static let sectionBottomGap: CGFloat = 2
    static let headerChevronLeading: CGFloat = 4
    static let headerChevronSize: CGFloat = 11
    static let headerChevronGap: CGFloat = 5
    static let headerCountTrailing: CGFloat = 8

    static let singleLineRowHeight: CGFloat = 34
    static let singleLineMidY: CGFloat = 17
    static let twoLineRowHeight: CGFloat = 48
    static let twoLineTopMidY: CGFloat = 16
    static let twoLineBottomMidY: CGFloat = 34.5
    static let rowVerticalGap: CGFloat = 2
    static let rowCornerRadius: CGFloat = 6
    static let rowHorizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 18
    static let iconToTitleGap: CGFloat = 7
    static let textLeadingX: CGFloat = rowHorizontalPadding + iconSize + iconToTitleGap // 33pt
    static let statusBadgeSize: CGFloat = 14
    static let closeButtonSize: CGFloat = 18
    static let cloudIconWidth: CGFloat = 13
    static let cloudIconHeight: CGFloat = 11
    static let cloudIconGap: CGFloat = 4
}

/// Quiet collapsible section header (`Continue`, `Today`, `Yesterday`, `Earlier`, or project name)
/// aligned flush with Inbox row margins and trailing shortcut numbers.
@MainActor
final class NativeInboxSectionHeaderView: NSView {
    let chevronContainer = NSView()
    private let chevronLayer = CALayer()
    let titleLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    private let themeObserver = OMGNativeThemeObserver()

    private(set) var groupID = ""
    private(set) var isCollapsed = false
    private(set) var chevronRotationAngle: CGFloat = 0
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            applyTheme()
        }
    }
    var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        chevronContainer.wantsLayer = true
        chevronLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        chevronLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        chevronLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: NativeInboxMetrics.headerChevronSize,
            height: NativeInboxMetrics.headerChevronSize
        )
        chevronLayer.position = CGPoint(
            x: NativeInboxMetrics.headerChevronSize / 2,
            y: NativeInboxMetrics.headerChevronSize / 2
        )
        chevronLayer.contentsGravity = .resizeAspect
        chevronContainer.layer?.addSublayer(chevronLayer)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right

        addSubview(chevronContainer)
        addSubview(titleLabel)
        addSubview(countLabel)

        themeObserver.onChange = { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window
        chevronLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        applyTheme()
    }

    func configure(id: String, title: String, count: Int?, collapsed: Bool, animated: Bool = false) {
        groupID = id
        titleLabel.stringValue = title
        if let count {
            countLabel.stringValue = "\(count)"
            countLabel.isHidden = false
            setAccessibilityLabel("\(title) (\(count))")
        } else {
            countLabel.stringValue = ""
            countLabel.isHidden = true
            setAccessibilityLabel(title)
        }
        let stateChanged = isCollapsed != collapsed
        isCollapsed = collapsed
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityValue(collapsed ? 0 : 1)
        if stateChanged || chevronRotationAngle != (collapsed ? -.pi / 2 : 0) {
            updateChevronRotation(collapsed: collapsed, animated: animated && stateChanged)
        }
        applyTheme()
        needsLayout = true
    }

    private func updateChevronRotation(collapsed: Bool, animated: Bool) {
        let angle: CGFloat = collapsed ? -.pi / 2 : 0
        chevronRotationAngle = angle
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.14)
        chevronLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    private func applyTheme() {
        let theme = OMGNativeTheme.resolve(for: self)
        let primaryTint = isHovered ? theme.foreground : theme.secondary
        titleLabel.textColor = primaryTint
        countLabel.textColor = theme.foreground.withAlphaComponent(0.45)
        if let base = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold)) {
            let tinted = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                primaryTint.withAlphaComponent(1).setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            chevronLayer.contents = tinted
        }
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        let chevronSize = NativeInboxMetrics.headerChevronSize
        chevronContainer.frame = NSRect(
            x: NativeInboxMetrics.headerChevronLeading,
            y: midY - chevronSize / 2,
            width: chevronSize,
            height: chevronSize
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevronLayer.position = CGPoint(x: chevronSize / 2, y: chevronSize / 2)
        CATransaction.commit()

        let countRight = bounds.width - NativeInboxMetrics.headerCountTrailing
        let countSize = countLabel.isHidden ? .zero : countLabel.fittingSize
        countLabel.frame = NSRect(
            x: countRight - countSize.width,
            y: midY - countSize.height / 2,
            width: countSize.width,
            height: countSize.height
        )

        let titleX = chevronContainer.frame.maxX + NativeInboxMetrics.headerChevronGap
        let titleMaxX = countLabel.isHidden ? countRight : max(titleX, countLabel.frame.minX - 6)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: midY - titleSize.height / 2,
            width: max(0, titleMaxX - titleX),
            height: titleSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onToggle?()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}
