import AppKit
import SwiftUI

struct AgentHistoryTranscriptToolbar: NSViewControllerRepresentable {
    let session: AgentHistorySession
    let strings: AgentHistoryStrings
    let query: String
    let isSearchVisible: Bool
    let focusRequestID: Int
    let matchCount: Int
    /// 1-based position of the match in view; 0 when there is none.
    var matchPosition = 0
    let onQueryChange: (String) -> Void
    /// Moves to the next (+1) or previous (-1) matching turn.
    var onStepMatch: (Int) -> Void = { _ in }
    let onToggleSearch: () -> Void
    let onEscape: () -> Void
    let onBack: () -> Void
    let onResume: () -> Void
    var onFork: (AgentHistoryForkPlacement) -> Void = { _ in }

    func makeNSViewController(context: Context) -> AgentHistoryTranscriptToolbarController {
        AgentHistoryTranscriptToolbarController()
    }

    func updateNSViewController(_ controller: AgentHistoryTranscriptToolbarController, context: Context) {
        controller.update(self)
    }
}

@MainActor
final class AgentHistoryTranscriptToolbarController: NSViewController, NSSearchFieldDelegate {
    private let stack = AgentHistoryTranscriptToolbarStack()
    private let header = NSStackView()
    private let searchRow = NSStackView()
    private let backButton = NSButton()
    private let agentIcon = NSImageView()
    private let agentName = NSTextField(labelWithString: "")
    private let findButton = NSButton()
    private let forkButton = NSButton()
    private let resumeButton = NSButton()
    private let searchField = AgentHistoryTranscriptSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let previousMatchButton = NSButton()
    private let nextMatchButton = NSButton()
    private var snapshot: AgentHistoryTranscriptToolbar?
    private var handledFocusRequestID = -1
    private weak var previousResponder: NSView?
    private var wasSearchVisible = false
    var searchFieldForTesting: AgentHistoryTranscriptSearchField { searchField }
    var backButtonForTesting: NSButton { backButton }
    var findButtonForTesting: NSButton { findButton }
    var forkButtonForTesting: NSButton { forkButton }
    var resumeButtonForTesting: NSButton { resumeButton }
    var matchLabelForTesting: NSTextField { matchLabel }
    var nextMatchButtonForTesting: NSButton { nextMatchButton }
    var previousMatchButtonForTesting: NSButton { previousMatchButton }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.onFind = { [weak self] in self?.snapshot?.onToggleSearch() }
        stack.edgeInsets = NSEdgeInsets(top: 8, left: InspectorContentMetrics.leadingInset,
                                        bottom: 6, right: InspectorContentMetrics.leadingInset)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.bezelStyle = .accessoryBar
        backButton.target = self
        backButton.action = #selector(back)
        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        agentName.lineBreakMode = .byTruncatingTail
        agentName.font = .systemFont(ofSize: 13, weight: .semibold)
        agentName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        findButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        findButton.bezelStyle = .accessoryBar
        findButton.target = self
        findButton.action = #selector(toggleSearch)
        forkButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        forkButton.bezelStyle = .accessoryBar
        forkButton.target = self
        forkButton.action = #selector(showForkMenu)
        resumeButton.bezelStyle = .rounded
        resumeButton.controlSize = .small
        resumeButton.target = self
        resumeButton.action = #selector(resume)
        header.addArrangedSubview(backButton)
        header.addArrangedSubview(agentIcon)
        header.addArrangedSubview(agentName)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(findButton)
        header.addArrangedSubview(forkButton)
        header.addArrangedSubview(resumeButton)
        agentIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        agentIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        backButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        findButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        forkButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 7
        searchField.placeholderString = AgentHistoryStrings.current.searchTranscriptPlaceholder
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.onEscape = { [weak self] in self?.snapshot?.onEscape() }
        searchField.onFind = { [weak self] in self?.snapshot?.onToggleSearch() }
        searchField.setAccessibilityLabel(AgentHistoryStrings.current.searchTranscriptPlaceholder)
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        for (button, symbol, action) in [
            (previousMatchButton, "chevron.up", #selector(previousMatch)),
            (nextMatchButton, "chevron.down", #selector(nextMatch)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.bezelStyle = .accessoryBar
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        searchRow.addArrangedSubview(searchField)
        searchRow.addArrangedSubview(matchLabel)
        searchRow.addArrangedSubview(previousMatchButton)
        searchRow.addArrangedSubview(nextMatchButton)
        searchRow.setCustomSpacing(2, after: previousMatchButton)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        matchLabel.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(searchRow)
        view = stack
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            searchRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func update(_ next: AgentHistoryTranscriptToolbar) {
        _ = view
        snapshot = next
        agentIcon.image = NSImage(named: next.session.agent.assetName)
        agentIcon.contentTintColor = agentIcon.image?.isTemplate == true ? .labelColor : nil
        agentName.stringValue = next.session.agent.displayName
        resumeButton.title = next.session.isActive ? next.strings.openLive : next.strings.resume
        forkButton.isHidden = !next.session.supportsFork
        forkButton.toolTip = next.strings.fork
        forkButton.setAccessibilityLabel(next.strings.fork)
        backButton.toolTip = next.strings.back
        backButton.setAccessibilityLabel(next.strings.back)
        findButton.toolTip = "⌘F"
        findButton.setAccessibilityLabel(next.strings.searchTranscriptPlaceholder)
        findButton.image = NSImage(
            systemSymbolName: next.isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass",
            accessibilityDescription: next.strings.searchTranscriptPlaceholder
        )
        searchField.placeholderString = next.strings.searchTranscriptPlaceholder
        searchField.onEscape = { [weak self] in self?.snapshot?.onEscape() }
        searchField.onFind = { [weak self] in self?.snapshot?.onToggleSearch() }
        if searchField.stringValue != next.query, !hasMarkedText {
            searchField.stringValue = next.query
        }
        matchLabel.stringValue = next.query.isEmpty ? ""
            : next.matchCount == 0 ? "0 \(next.strings.matchesCount)" : "\(next.matchPosition)/\(next.matchCount)"
        for (button, title) in [(previousMatchButton, next.strings.previousMatch),
                                (nextMatchButton, next.strings.nextMatch)] {
            button.isHidden = next.query.isEmpty
            button.isEnabled = next.matchCount > 1
            button.toolTip = title
            button.setAccessibilityLabel(title)
        }
        searchRow.isHidden = !next.isSearchVisible
        if wasSearchVisible && !next.isSearchVisible,
           let previousResponder,
           previousResponder.window === view.window {
            view.window?.makeFirstResponder(previousResponder)
            self.previousResponder = nil
        }
        wasSearchVisible = next.isSearchVisible
        if next.focusRequestID != handledFocusRequestID {
            handledFocusRequestID = next.focusRequestID
            if next.isSearchVisible {
                let requestedID = next.focusRequestID
                let requestedSessionID = next.session.id
                DispatchQueue.main.async { [weak self] in
                    guard let self, let latest = self.snapshot,
                          latest.isSearchVisible,
                          latest.focusRequestID == requestedID,
                          latest.session.id == requestedSessionID,
                          self.searchRow.window != nil else { return }
                    self.previousResponder = self.view.window?.firstResponder as? NSView
                    self.searchRow.window?.makeFirstResponder(self.searchField)
                }
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        snapshot?.onQueryChange(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            guard !textView.hasMarkedText() else { return false }
            snapshot?.onEscape()
            return true
        }
        if commandSelector == #selector(NSTextView.performFindPanelAction(_:)) {
            snapshot?.onToggleSearch()
            return true
        }
        // Return walks the matches, as in any find bar; Shift goes back.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard !textView.hasMarkedText() else { return false }
            snapshot?.onStepMatch(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !hasMarkedText, let snapshot, searchField.stringValue != snapshot.query else { return }
        searchField.stringValue = snapshot.query
    }

    private var hasMarkedText: Bool {
        (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        snapshot?.onQueryChange(sender.stringValue)
    }

    @objc private func previousMatch() { snapshot?.onStepMatch(-1) }
    @objc private func nextMatch() { snapshot?.onStepMatch(1) }
    @objc private func toggleSearch() { snapshot?.onToggleSearch() }
    @objc private func back() { snapshot?.onBack() }
    @objc private func resume() { snapshot?.onResume() }

    /// One item per placement, tagged with its index in `allCases`.
    func forkMenu() -> NSMenu? {
        guard let snapshot, snapshot.session.supportsFork else { return nil }
        let menu = NSMenu()
        for (index, placement) in AgentHistoryForkPlacement.allCases.enumerated() {
            let item = NSMenuItem(title: snapshot.strings.forkTitle(placement),
                                  action: #selector(fork(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showForkMenu() {
        forkMenu()?.popUp(positioning: nil, at: NSPoint(x: 0, y: forkButton.bounds.maxY + 4), in: forkButton)
    }

    @objc private func fork(_ sender: NSMenuItem) {
        let placements = AgentHistoryForkPlacement.allCases
        guard placements.indices.contains(sender.tag) else { return }
        snapshot?.onFork(placements[sender.tag])
    }
}

final class AgentHistoryTranscriptSearchField: NSSearchField {
    var onEscape: (() -> Void)?
    var onFind: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let hasMarkedText = (currentEditor() as? NSTextView)?.hasMarkedText() == true
        if event.keyCode == 53,
           event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
           !hasMarkedText {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.cancelOperation(sender)
        } else {
            onEscape?()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AgentHistoryFindShortcut.accepts(event, in: self) {
            onFind?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class AgentHistoryTranscriptToolbarStack: NSStackView {
    var onFind: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AgentHistoryFindShortcut.accepts(event, in: self) {
            onFind?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum AgentHistoryFindShortcut {
    static func accepts(_ event: NSEvent, in owner: NSView) -> Bool {
        guard !owner.isHiddenOrHasHiddenAncestor, let window = owner.window,
              event.type == .keyDown, event.modifierFlags.contains(.command),
              event.modifierFlags.isDisjoint(with: [.shift, .option, .control]),
              event.charactersIgnoringModifiers?.lowercased() == "f",
              let responder = window.firstResponder as? NSView else { return false }
        if let editor = responder as? NSTextView, editor.hasMarkedText() { return false }
        if responder === owner || responder.isDescendant(of: owner) { return true }
        // A window's field editor can live outside the control's view subtree.
        guard let editor = responder as? NSTextView, editor.isFieldEditor,
              let control = editor.delegate as? NSView else { return false }
        return control === owner || control.isDescendant(of: owner)
    }
}
