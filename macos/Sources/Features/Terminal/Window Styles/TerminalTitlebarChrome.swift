import AppKit
import SwiftUI

enum TerminalTitlebarMetrics {
    static let minimumHeight: CGFloat = 28
    static let leftAccessoryWidth: CGFloat = 58
    static let inspectorCollapsedWidth: CGFloat = 44
    static let inspectorOverflowBucket: CGFloat = 12
}

enum TerminalTitlebarControlStyle {
    static let iconSize: CGFloat = 16
    static let iconFontSize: CGFloat = 12
    static let controlHeight: CGFloat = 24
    static let iconControlWidth: CGFloat = 24
    static let cornerRadius: CGFloat = 4
    static let itemSpacing: CGFloat = 4
    static let contentSpacing: CGFloat = 5
    static let labelFontSize: CGFloat = 11.5
    static let labelWeight = Font.Weight.medium
    static let iconHorizontalPadding: CGFloat = 4
    static let horizontalLabelPadding: CGFloat = 8
    static let hoverOpacity = 0.06
    static let disabledOpacity = 0.45

    static func controlWidth(title: String?) -> CGFloat {
        guard let title else { return iconControlWidth }
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let titleWidth = ceil((title as NSString).size(
            withAttributes: [.font: font]
        ).width)
        return max(
            iconControlWidth,
            horizontalLabelPadding * 2 + iconSize + contentSpacing + titleWidth
        )
    }
}

struct TerminalTitlebarControlLabel: View {
    let systemName: String
    let title: String?
    let hovered: Bool

    var body: some View {
        HStack(spacing: TerminalTitlebarControlStyle.contentSpacing) {
            Image(systemName: systemName)
                .font(.system(size: TerminalTitlebarControlStyle.iconFontSize))
                .frame(
                    width: TerminalTitlebarControlStyle.iconSize,
                    height: TerminalTitlebarControlStyle.iconSize
                )
            if let title {
                Text(title)
                    .font(.system(
                        size: TerminalTitlebarControlStyle.labelFontSize,
                        weight: TerminalTitlebarControlStyle.labelWeight
                    ))
                    .lineLimit(1)
            }
        }
        .padding(
            .horizontal,
            title == nil
                ? TerminalTitlebarControlStyle.iconHorizontalPadding
                : TerminalTitlebarControlStyle.horizontalLabelPadding
        )
        .frame(
            minWidth: TerminalTitlebarControlStyle.iconControlWidth,
            minHeight: TerminalTitlebarControlStyle.controlHeight
        )
        .background(
            RoundedRectangle(cornerRadius: TerminalTitlebarControlStyle.cornerRadius)
                .fill(Color.primary.opacity(
                    hovered ? TerminalTitlebarControlStyle.hoverOpacity : 0
                ))
        )
    }
}

struct TerminalTitlebarButton: View {
    let systemName: String
    let title: String?
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            TerminalTitlebarControlLabel(
                systemName: systemName,
                title: title,
                hovered: hovered
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct TerminalTitlebarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        TerminalTitlebarButton(
            systemName: systemName,
            title: nil,
            help: help,
            action: action
        )
    }
}

protocol TerminalTitlebarControlsCentering {
    var contentCenterYInWindow: CGFloat? { get }
}

protocol TerminalTitlebarWidthSynchronizing {
    var titlebarWidth: CGFloat { get }
    func setTitlebarWidth(_ width: CGFloat)
}

final class AlignedTerminalTitlebarControlsView<Content: View>: NSView,
    TerminalTitlebarControlsCentering,
    TerminalTitlebarWidthSynchronizing {
    private let hostingView: NSHostingView<Content>
    private(set) var titlebarWidth: CGFloat

    init(minimumWidth: CGFloat, rootView: Content) {
        self.titlebarWidth = minimumWidth
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: minimumWidth,
            height: TerminalTitlebarMetrics.minimumHeight
        ))
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: titlebarWidth, height: titlebarHeight)
    }

    func setTitlebarWidth(_ width: CGFloat) {
        guard width != titlebarWidth else { return }
        titlebarWidth = width
        invalidateIntrinsicContentSize()
        setFrameSize(NSSize(width: width, height: frame.height))
        needsLayout = true
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
            return TerminalTitlebarMetrics.minimumHeight
        }
        return max(
            TerminalTitlebarMetrics.minimumHeight,
            titlebarContainer.bounds.height
        )
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
