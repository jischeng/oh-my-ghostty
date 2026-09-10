import AppKit

/// Reused native cells keep file identity and checkbox state explicit.
final class GitCollectionCell: NSTableCellView {
    let checkbox = GitStageCheckbox()
    private let progress = NSProgressIndicator()
    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let rule = NSView()
    private var row: GitCollectionRow?
    private var toggle: () -> Void = {}
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [name, subtitle, status, badge] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
        }
        name.font = .systemFont(ofSize: 11)
        subtitle.font = .systemFont(ofSize: 10)
        status.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        badge.font = .systemFont(ofSize: 9)
        badge.alignment = .right
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggleFolder)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        rule.wantsLayer = true
        [checkbox, progress, disclosure, icon, name, subtitle, status, badge, rule].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: GitCollectionRow, colors: GitCollectionColors, toggle: @escaping () -> Void,
                   stage: @escaping (GitDiffFile, Bool) -> Void) {
        self.row = row
        self.toggle = toggle
        let item = row.item
        [checkbox, progress, disclosure, icon, subtitle, status, badge, rule].forEach { $0.isHidden = true }
        progress.stopAnimation(nil)
        name.stringValue = item.title
        name.font = .systemFont(ofSize: 11, weight: item.isCategory ? .medium : .regular)
        name.textColor = item.isCategory ? colors.secondary : colors.text
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle?.isEmpty != false
        subtitle.textColor = colors.secondary
        status.textColor = colors.secondary
        badge.textColor = colors.secondary
        icon.contentTintColor = colors.secondary
        disclosure.contentTintColor = colors.secondary
        rule.layer?.backgroundColor = colors.separator.cgColor
        alphaValue = item.enabled || item.pending ? 1 : 0.55
        toolTip = item.tooltip
        setAccessibilityIdentifier(item.id)
        setAccessibilityLabel(item.tooltip)
        switch item.kind {
        case .category(let count):
            badge.stringValue = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            badge.isHidden = false; rule.isHidden = false
        case .folder(let count):
            disclosure.isHidden = false
            disclosure.image = NSImage(systemSymbolName: row.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: row.expanded ? "Collapse folder" : "Expand folder")?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
            setIcon("folder")
            badge.stringValue = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            badge.isHidden = false
        case .file(let file, let section):
            checkbox.configure(checked: section == .staged, enabled: item.enabled, colors: colors)
            checkbox.setAccessibilityIdentifier(item.id + "/checkbox")
            checkbox.setAccessibilityLabel((section == .staged ? "Unstage " : "Stage ") + file.path)
            checkbox.toolTip = item.pending ? "Updating index…" : (section == .staged ? "Unstage " : "Stage ") + file.path
            checkbox.activate = { stage(file, section != .staged) }
            checkbox.isHidden = item.pending
            if item.pending {
                progress.isHidden = false
                progress.setAccessibilityLabel("Updating index for " + file.path)
                progress.startAnimation(nil)
            }
            status.stringValue = file.isUntracked ? "?" : String(file.status.prefix(1))
            status.textColor = colors.status(file)
            status.isHidden = false
        case .branch(let branch, let paths):
            setIcon(branch.isCurrent ? "checkmark.circle" : branch.isRemote ? "network" : "arrow.triangle.branch")
            if branch.isCurrent { icon.contentTintColor = colors.accent }
            if !paths.isEmpty { badge.stringValue = "worktree"; badge.isHidden = false }
        case .worktree(let tree):
            setIcon(tree.isCurrent ? "checkmark.circle" : tree.lockedReason != nil ? "lock" : "folder")
            if tree.isCurrent { icon.contentTintColor = colors.accent }
            let states = [tree.branchRef == nil ? "Detached" : nil, tree.isCurrent ? "current" : nil, tree.isDirty == true ? "dirty" : nil]
            badge.stringValue = states.compactMap { $0 }.joined(separator: " · ")
            badge.isHidden = badge.stringValue.isEmpty
        case .scope:
            setIcon("clock.arrow.circlepath")
        case .notice(let error):
            name.textColor = error ? colors.deleted : colors.secondary
        }
        needsLayout = true
    }

    private func setIcon(_ symbol: String) {
        icon.isHidden = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }
    @objc private func toggleFolder() { toggle() }

    override func layout() {
        super.layout()
        guard let row else { return }
        let x: CGFloat = 10 + CGFloat(row.depth) * 12
        var textX = x
        let center = subtitle.isHidden ? bounds.height / 2 : 12
        if !checkbox.isHidden || !progress.isHidden || !status.isHidden {
            checkbox.frame = .init(x: x, y: center - 7, width: 14, height: 14)
            progress.frame = .init(x: x + 1, y: center - 6, width: 12, height: 12)
            status.frame = .init(x: x + 19, y: center - 6, width: 11, height: 13)
            textX = x + 35
        } else if !icon.isHidden {
            let iconX = x + (row.item.isFolder ? 14 : 0)
            disclosure.frame = .init(x: x - 3, y: center - 7, width: 14, height: 14)
            icon.frame = .init(x: iconX, y: center - 7, width: 14, height: 14)
            textX = iconX + 19
        }
        let badgeWidth = badge.isHidden ? 0 : min(100, ceil(badge.intrinsicContentSize.width) + 5)
        badge.frame = .init(x: max(textX, bounds.width - badgeWidth - 10), y: center - 7, width: badgeWidth, height: 14)
        let textWidth = max(1, bounds.width - textX - 10 - badgeWidth)
        if !subtitle.isHidden {
            name.frame = .init(x: textX, y: 4, width: textWidth, height: 15)
            subtitle.frame = .init(x: textX, y: 21, width: max(1, bounds.width - textX - 10), height: 13)
        } else {
            name.frame = .init(x: textX, y: center - 7, width: textWidth, height: 15)
        }
        rule.frame = .init(x: 10, y: bounds.height - 1, width: max(0, bounds.width - 20), height: 0.5)
    }
}
