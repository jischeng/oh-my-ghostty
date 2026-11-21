import AppKit
import SwiftUI

/// One scrolling document, reusable cells and a shared display/measurement font.
struct TerminalHistoryTable: NSViewRepresentable {
    let items: [InspectorHistoryItem]
    let jump: (InspectorHistoryItem) -> Void
    var copyOutput: ((InspectorHistoryItem) -> Void)?
    var openOutputInEditor: ((InspectorHistoryItem) -> Void)?
    var canExtractOutput: ((InspectorHistoryItem) -> Bool)?
    @ObservedObject private var settings = OhMyGhosttySettings.shared

    init(
        items: [InspectorHistoryItem],
        copyOutput: ((InspectorHistoryItem) -> Void)? = nil,
        openOutputInEditor: ((InspectorHistoryItem) -> Void)? = nil,
        canExtractOutput: ((InspectorHistoryItem) -> Bool)? = nil,
        jump: @escaping (InspectorHistoryItem) -> Void
    ) {
        self.items = items
        self.copyOutput = copyOutput
        self.openOutputInEditor = openOutputInEditor
        self.canExtractOutput = canExtractOutput
        self.jump = jump
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = HistoryScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = HistoryTable()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("history"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.activate)
        table.copyText = { [weak coordinator = context.coordinator, weak table] in
            guard let coordinator, let table,
                  coordinator.items.indices.contains(table.selectedRow) else { return nil }
            return coordinator.items[table.selectedRow].text
        }
        table.contextMenuBuilder = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        context.coordinator.table = table
        scroll.documentView = table
        scroll.widthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.updateWidth(width)
        }
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.jump = jump
        coordinator.copyOutput = copyOutput
        coordinator.openOutputInEditor = openOutputInEditor
        coordinator.canExtractOutput = canExtractOutput
        coordinator.updateWidth(scroll.contentSize.width)
        coordinator.update(items: items, strings: .init(language: settings.language))
    }

    final class HistoryScrollView: NSScrollView {
        var widthChanged: ((CGFloat) -> Void)?
        override func layout() {
            super.layout()
            widthChanged?(contentSize.width)
        }
    }

    final class HistoryTable: NSTableView {
        var copyText: (() -> String?)?
        var contextMenuBuilder: ((Int) -> NSMenu?)?

        @objc func copy(_ sender: Any?) {
            guard let text = copyText?() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let clicked = row(at: point)
            let targetRow = clicked >= 0 ? clicked : selectedRow
            guard targetRow >= 0 else { return nil }
            if clicked >= 0, !selectedRowIndexes.contains(clicked) {
                selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
            return contextMenuBuilder?(targetRow)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let responder = window?.firstResponder as? NSView,
               responder === self || responder.isDescendant(of: self),
               event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c", copyText?() != nil {
                copy(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    enum Metrics {
        static let inset = InspectorContentMetrics.leadingInset
        static let verticalInset: CGFloat = 8
        static let textDateGap: CGFloat = 6
        static let dateHeight: CGFloat = 14
        static let rowSpacing = verticalInset * 2 + textDateGap + dateHeight
        static let previewHeight: CGFloat = 72
        static func failureMarker(in bounds: NSRect) -> NSRect {
            NSRect(x: 4, y: verticalInset, width: 2, height: max(0, bounds.height - 2 * verticalInset))
        }
        static func font(for kind: InspectorHistoryItemKind) -> NSFont {
            kind == .command ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        }
        static func textHeight(_ item: InspectorHistoryItem, width: CGFloat) -> CGFloat {
            let label = NSTextField(wrappingLabelWithString: item.preview)
            label.font = font(for: item.kind)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 4
            return min(previewHeight, ceil(label.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: max(20, width), height: 10000
            )).height ?? 15))
        }
    }

    /// Compact row metadata. The full timestamp stays available on hover.
    enum Format {
        /// Today shows the time only; older rows add as much date as needed.
        static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if calendar.isDate(date, inSameDayAs: now) {
                formatter.dateFormat = "HH:mm"
            } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                formatter.dateFormat = "MM-dd HH:mm"
            } else {
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
            }
            return formatter.string(from: date)
        }

        static func fullTimestamp(_ date: Date, calendar: Calendar = .current) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }

        /// Sub-second commands are the norm, so only slower ones show a duration.
        static func duration(milliseconds: UInt64?) -> String? {
            guard let milliseconds, milliseconds >= 1_000 else { return nil }
            let seconds = milliseconds / 1_000
            if seconds < 60 {
                return String(format: "%.1fs", Double(milliseconds) / 1_000)
            }
            if seconds < 3_600 {
                return "\(seconds / 60)m \(seconds % 60)s"
            }
            return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m"
        }

        static func failed(_ item: InspectorHistoryItem) -> Bool {
            item.exitCode.map { $0 != 0 } ?? false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [InspectorHistoryItem] = []
        var jump: ((InspectorHistoryItem) -> Void)?
        var copyOutput: ((InspectorHistoryItem) -> Void)?
        var openOutputInEditor: ((InspectorHistoryItem) -> Void)?
        var canExtractOutput: ((InspectorHistoryItem) -> Bool)?
        weak var table: NSTableView?
        private var width: CGFloat = 300
        private var heights: [String: CGFloat] = [:]
        private var strings = InfoStrings()
        var now: () -> Date = Date.init
        var calendar = Calendar.current

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let menu = NSMenu()
            menu.autoenablesItems = false

            let copyTitle = item.kind == .command ? strings.copyCommand : strings.copyPrompt
            let copyItem = NSMenuItem(
                title: copyTitle,
                action: #selector(copyCommandAtMenuRow(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            copyItem.tag = row
            copyItem.isEnabled = !item.text.isEmpty
            menu.addItem(copyItem)

            if item.kind == .command {
                let outputAvailable = resolveCanExtractOutput(for: item)
                let copyOut = NSMenuItem(
                    title: strings.copyCommandOutput,
                    action: #selector(copyCommandOutputAtMenuRow(_:)),
                    keyEquivalent: ""
                )
                copyOut.target = self
                copyOut.tag = row
                copyOut.isEnabled = outputAvailable
                menu.addItem(copyOut)

                let openOut = NSMenuItem(
                    title: strings.openCommandOutputInEditor,
                    action: #selector(openCommandOutputAtMenuRow(_:)),
                    keyEquivalent: ""
                )
                openOut.target = self
                openOut.tag = row
                openOut.isEnabled = outputAvailable
                menu.addItem(openOut)

                menu.addItem(.separator())
                let jumpItem = NSMenuItem(
                    title: strings.jumpToCommand,
                    action: #selector(jumpAtMenuRow(_:)),
                    keyEquivalent: ""
                )
                jumpItem.target = self
                jumpItem.tag = row
                jumpItem.isEnabled = Self.canJump(item)
                menu.addItem(jumpItem)
            }

            return menu
        }

        private func resolveSurface(for item: InspectorHistoryItem) -> Ghostty.SurfaceView? {
            guard case .command(let surfaceID, _, _) = item.location else { return nil }
            return TerminalFocusRouter.findSurface(forUUID: surfaceID)
        }

        private func resolveCanExtractOutput(for item: InspectorHistoryItem) -> Bool {
            if let canExtractOutput {
                return canExtractOutput(item)
            }
            guard let surface = resolveSurface(for: item) else { return false }
            return TerminalCommandOutputActions.canExtractOutput(for: item, in: surface)
        }

        @objc private func copyCommandAtMenuRow(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            let text = items[sender.tag].text
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func copyCommandOutputAtMenuRow(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            let item = items[sender.tag]
            if let copyOutput {
                copyOutput(item)
                return
            }
            guard let surface = resolveSurface(for: item) else {
                NSSound.beep()
                return
            }
            _ = TerminalCommandOutputActions.copyCommandOutput(for: item, from: surface)
        }

        @objc private func openCommandOutputAtMenuRow(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            let item = items[sender.tag]
            if let openOutputInEditor {
                openOutputInEditor(item)
                return
            }
            guard let surface = resolveSurface(for: item) else {
                NSSound.beep()
                return
            }
            _ = TerminalCommandOutputActions.openCommandOutputInEditor(for: item, from: surface)
        }

        @objc private func jumpAtMenuRow(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag), Self.canJump(items[sender.tag]) else { return }
            jump?(items[sender.tag])
        }

        func update(items next: [InspectorHistoryItem], strings nextStrings: InfoStrings) {
            guard items != next || strings != nextStrings, let table else { return }
            let selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow].id : nil
            let origin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
            let topRow = table.row(at: NSPoint(x: 0, y: origin.y))
            let topID = items.indices.contains(topRow) ? items[topRow].id : nil
            let delta = topID == nil ? 0 : origin.y - table.rect(ofRow: topRow).minY
            items = next
            strings = nextStrings
            heights.removeAll(keepingCapacity: true)
            table.reloadData()
            // Never silently select a different occurrence at the same row index.
            table.deselectAll(nil)
            if let selected, let index = items.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            // At the top, follow newly prepended records; otherwise keep the
            // user's reading position rather than jumping when prompts arrive.
            if origin.y > 1, let topID, let index = items.firstIndex(where: { $0.id == topID }),
               let scroll = table.enclosingScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY + delta))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        func updateWidth(_ value: CGFloat) {
            guard value > 0, abs(width - value) > 0.5 else { return }
            width = value
            heights.removeAll(keepingCapacity: true)
            table?.tableColumns.first?.width = value
            table?.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: items.indices))
        }
        static func canJump(_ item: InspectorHistoryItem) -> Bool { item.location.isAvailable }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let item = items[row]
            if let height = heights[item.id] { return height }
            let height = Metrics.textHeight(item, width: width - 2 * Metrics.inset) + Metrics.rowSpacing
            heights[item.id] = height
            return height
        }
        @objc func activate() {
            guard let table, items.indices.contains(table.clickedRow),
                  Self.canJump(items[table.clickedRow]) else { return }
            jump?(items[table.clickedRow])
        }
        @objc func jumpButton(_ sender: NSButton) {
            guard items.indices.contains(sender.tag), Self.canJump(items[sender.tag]) else { return }
            jump?(items[sender.tag])
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let identifier = NSUserInterfaceItemIdentifier("history-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCell ?? HistoryCell()
            cell.identifier = identifier
            cell.text.stringValue = item.preview
            cell.text.font = Metrics.font(for: item.kind)
            let archived: Bool
            if case .unavailable(.expired) = item.location { archived = true } else { archived = false }
            let failed = Format.failed(item)
            let separator = "  ·  "
            var segments: [(String, NSColor)] = []
            if failed, let code = item.exitCode {
                segments.append((strings.exitCode(code), .systemRed))
            }
            segments.append((
                item.timestamp.map { Format.timestamp($0, now: now(), calendar: calendar) }
                    ?? strings.unknownHistoryDate,
                .secondaryLabelColor
            ))
            if let duration = Format.duration(milliseconds: item.duration) {
                segments.append((duration, .secondaryLabelColor))
            }
            if let origin = item.sourceLabel { segments.append((origin, .secondaryLabelColor)) }
            if archived { segments.append((strings.archivedCommandLabel, .secondaryLabelColor)) }
            let meta = NSMutableAttributedString()
            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    meta.append(.init(string: separator, attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
                }
                meta.append(.init(string: segment.0, attributes: [.foregroundColor: segment.1]))
            }
            meta.addAttribute(.font, value: HistoryCell.metaFont, range: NSRange(location: 0, length: meta.length))
            cell.date.attributedStringValue = meta
            cell.date.toolTip = [
                item.timestamp.map { Format.fullTimestamp($0, calendar: calendar) },
                item.exitCode.map(strings.exitCode),
                item.duration.map { strings.commandDuration(milliseconds: $0) },
                item.sourceLabel,
                archived ? strings.archivedCommandLabel : nil,
            ].compactMap { $0 }.joined(separator: separator)
            cell.failed = failed
            cell.jump.isEnabled = Self.canJump(item)
            let help = archived ? strings.archivedCommandHelp
                : (Self.canJump(item) ? strings.clickToJump : strings.noTerminalAnchor)
            cell.jump.setAccessibilityLabel(help)
            cell.jump.toolTip = help
            cell.toolTip = Self.canJump(item) ? strings.historyRowHelp : help
            cell.jump.target = self
            cell.jump.action = #selector(jumpButton(_:))
            cell.jump.tag = row
            cell.updateActionVisibility()
            return cell
        }
    }

    final class HistoryCell: NSTableCellView {
        let text = NSTextField(wrappingLabelWithString: "")
        let date = NSTextField(labelWithString: "")
        let jump = NSButton(title: "", target: nil, action: nil)
        static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        /// Failed commands carry a red edge so they stand out while scanning.
        var failed = false {
            didSet { if failed != oldValue { needsDisplay = true } }
        }
        private var hovered = false
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { updateActionVisibility() }
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            text.font = Metrics.font(for: .agentPrompt)
            text.lineBreakMode = .byWordWrapping
            text.maximumNumberOfLines = 4
            date.font = Self.metaFont
            date.textColor = .secondaryLabelColor
            date.lineBreakMode = .byTruncatingTail
            jump.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
            jump.imagePosition = .imageOnly
            jump.isBordered = false
            for view in [text, date, jump] { addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; updateActionVisibility() }
        override func mouseExited(with event: NSEvent) { hovered = false; updateActionVisibility() }
        func updateActionVisibility() {
            jump.isHidden = !jump.isEnabled || (!hovered && backgroundStyle != .emphasized)
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.separatorColor.withAlphaComponent(0.25).setFill()
            NSRect(x: Metrics.inset, y: bounds.height - 0.5,
                   width: max(0, bounds.width - 2 * Metrics.inset), height: 0.5).fill()
            if failed {
                NSColor.systemRed.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: Metrics.failureMarker(in: bounds), xRadius: 1, yRadius: 1).fill()
            }
        }
        override func layout() {
            super.layout()
            text.frame = NSRect(x: Metrics.inset, y: Metrics.verticalInset,
                                width: max(20, bounds.width - 2 * Metrics.inset),
                                height: max(0, bounds.height - Metrics.rowSpacing))
            date.frame = NSRect(x: Metrics.inset, y: text.frame.maxY + Metrics.textDateGap,
                                width: max(20, bounds.width - 44), height: Metrics.dateHeight)
            jump.frame = NSRect(x: bounds.width - 30, y: bounds.height - 26, width: 24, height: 20)
        }
    }
}
