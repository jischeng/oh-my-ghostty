import AppKit
import SwiftUI

struct GitCollectionColors: Equatable {
    var text = NSColor.labelColor
    var accent = NSColor.controlAccentColor
    var selection = NSColor.selectedContentBackgroundColor
    var background = NSColor.windowBackgroundColor
    var added = GitDiffChangeKind.added.color
    var modified = GitDiffChangeKind.modified.color
    var deleted = GitDiffChangeKind.deleted.color
    var renamed = GitDiffChangeKind.renamed.color
    var secondary: NSColor { text.withAlphaComponent(0.62) }
    var separator: NSColor { text.withAlphaComponent(0.13) }
    var hover: NSColor { text.withAlphaComponent(0.055) }

    init() {}
    init(config: Ghostty.Config, background: NSColor) {
        let theme = config.editorTheme(background: background)
        text = theme.text; accent = theme.commands; selection = theme.selection
        self.background = background
        added = theme.strings; modified = theme.numbers; deleted = theme.variables; renamed = theme.commands
    }

    func status(_ file: GitDiffFile) -> NSColor {
        guard !file.isUntracked else { return secondary }
        let color: NSColor = switch file.kind {
        case .added, .copied: added
        case .modified, .typeChanged: modified
        case .deleted, .unmerged: deleted
        case .renamed: renamed
        case .unknown: secondary
        }
        return color.withAlphaComponent(0.75)
    }
}

private struct GitCollectionColorsKey: EnvironmentKey {
    static let defaultValue = GitCollectionColors()
}
extension EnvironmentValues {
    var gitCollectionColors: GitCollectionColors {
        get { self[GitCollectionColorsKey.self] }
        set { self[GitCollectionColorsKey.self] = newValue }
    }
}

/// One compact mode control is used in Changes, Branches and the History picker.
struct GitCollectionModePicker: View {
    @Binding var mode: GitCollectionMode
    @Environment(\.gitCollectionColors) private var colors
    var body: some View {
        HStack(spacing: 2) {
            ForEach(GitCollectionMode.allCases, id: \.self) { value in
                Button { mode = value } label: {
                    Image(systemName: value.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(mode == value ? colors.text : colors.secondary))
                        .frame(width: 23, height: 23)
                        .background(Color(colors.text).opacity(mode == value ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(value.title + " view")
                .accessibilityLabel(value.title + " view")
                .accessibilityValue(mode == value ? "Selected" : "")
            }
        }
        .fixedSize()
    }
}

final class GitStageCheckbox: NSButton {
    private var hovered = false
    private var colors = GitCollectionColors()
    private var tracking: NSTrackingArea?
    var activate: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        setAccessibilityRole(.checkBox)
        target = self
        action = #selector(clicked)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(checked: Bool, enabled: Bool, colors: GitCollectionColors) {
        self.colors = colors
        state = checked ? .on : .off
        isEnabled = enabled
        setAccessibilityValue(NSNumber(value: checked))
        updateImage()
    }
    private func updateImage() {
        image = NSImage(systemSymbolName: state == .on ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        contentTintColor = state == .on || (hovered && isEnabled) ? colors.accent : colors.secondary
        alphaValue = isEnabled ? 1 : 0.4
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateImage() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateImage() }
    @objc private func clicked() { if isEnabled { activate() } }
}

final class GitCollectionRowView: NSTableRowView {
    var colors = GitCollectionColors() { didSet { needsDisplay = true } }
    var showsHighlight = true
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        guard showsHighlight, hovered, !isSelected else { return }
        colors.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 3, yRadius: 3).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard showsHighlight else { return }
        colors.selection.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 3, yRadius: 3).fill()
    }
}
