import AppKit
import Combine
import SwiftUI

struct OMGKeyboardShortcut: Equatable {
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control,
    ]

    static let quickInputHistory = OMGKeyboardShortcut(key: "h", modifiers: [.command, .shift])

    static let defaultQuickInput = OMGKeyboardShortcut(
        key: "e",
        modifiers: [.command, .shift]
    )

    static let defaultInspectorPanel1 = OMGKeyboardShortcut(
        key: "1",
        modifiers: [.option]
    )
    static let defaultInspectorPanel2 = OMGKeyboardShortcut(
        key: "2",
        modifiers: [.option]
    )
    static let defaultInspectorPanel3 = OMGKeyboardShortcut(
        key: "3",
        modifiers: [.option]
    )
    static let defaultInspectorPanel4 = OMGKeyboardShortcut(
        key: "4",
        modifiers: [.option]
    )

    static func defaultInspectorPanel(slot: Int) -> OMGKeyboardShortcut {
        switch slot {
        case 1: defaultInspectorPanel1
        case 2: defaultInspectorPanel2
        case 3: defaultInspectorPanel3
        case 4: defaultInspectorPanel4
        default: OMGKeyboardShortcut(key: "\(slot)", modifiers: [.option])
        }
    }

    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    init?(storageValue: String) {
        let parts = storageValue
            .lowercased()
            .split(separator: "+")
            .map(String.init)
        guard let key = parts.last, key.count == 1 else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "command", "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "alt": modifiers.insert(.option)
            case "control", "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1 else { return nil }
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        guard !modifiers.isEmpty else { return nil }
        self.init(key: characters, modifiers: modifiers)
    }

    var storageValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    var displayValue: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + key.uppercased()
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let shortcut = OMGKeyboardShortcut(event: event) else { return false }
        return shortcut == self
    }

    @MainActor
    func conflictingMenuItemTitle() -> String? {
        conflictingMenuItemTitle(in: NSApp.mainMenu)
    }

    @MainActor
    func conflictingMenuItemTitle(in menu: NSMenu?) -> String? {
        if self == .quickInputHistory { return "Quick Input History (⌘⇧H)" }
        guard let menu else { return nil }
        for item in menu.items {
            let itemModifiers = item.keyEquivalentModifierMask
                .intersection(Self.relevantModifiers)
            if item.keyEquivalent.lowercased() == key,
               itemModifiers == modifiers,
               !item.title.isEmpty {
                return item.title
            }
            if let conflict = conflictingMenuItemTitle(in: item.submenu) {
                return conflict
            }
        }
        return nil
    }
}

enum AgentQuickInputEditingCommand: Equatable {
    case selectAll
    case copy
    case paste
    case cut
    case undo
    case redo

    static func resolve(
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> Self? {
        switch (key.lowercased(), modifiers) {
        case ("a", [.command]): .selectAll
        case ("c", [.command]): .copy
        case ("v", [.command]): .paste
        case ("x", [.command]): .cut
        case ("z", [.command]): .undo
        case ("z", [.command, .shift]): .redo
        default: nil
        }
    }
}

enum AgentQuickInputDispatchPolicy {
    static func shouldDispatch(
        previous: TabActivityState?,
        next: TabActivityState?
    ) -> Bool {
        previous != .done && next == .done
    }
}

enum AgentQuickInputPresentationPolicy {
    static func shouldPresentForAgentStart(
        previous: TabActivity?,
        next: TabActivity?,
        enabled: Bool,
        isAlreadyPresented: Bool,
        isTargetFocused: Bool
    ) -> Bool {
        enabled && previous == nil && next != nil &&
            !isAlreadyPresented && isTargetFocused
    }

    static func shouldPresentForAgentCompletion(
        previous: TabActivityState?,
        next: TabActivityState?,
        enabled: Bool,
        isAlreadyPresented: Bool,
        isTargetFocused: Bool
    ) -> Bool {
        enabled && previous != .done && next == .done &&
            !isAlreadyPresented && isTargetFocused
    }
}

enum AgentQuickInputFocusDirection: Equatable {
    case up
    case down
    case left
    case right

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Self? {
        let relevant = modifiers.intersection([
            .command, .shift, .option, .control,
        ])
        guard relevant == [.command, .option] else { return nil }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default: return nil
        }
    }

    var splitDirection: Ghostty.SplitFocusDirection {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

enum AgentQuickInputMetrics {
    static let minimumHeight: CGFloat = 96
    static let defaultHeight: CGFloat = 165
    static let maximumHeight: CGFloat = 480
    static let minimumTerminalHeight: CGFloat = 160
    static let floatingHorizontalInset: CGFloat = 16
    static let floatingBottomInset: CGFloat = 12
    static let floatingStackSpacing: CGFloat = 8
    static let floatingTopMargin: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let queueLaneHeight: CGFloat = 60
    static let queueCardHeight: CGFloat = 38
    static let queueFloatingHeight: CGFloat = queueCardHeight + 8
    static let collapsedQueueHeight: CGFloat = 28
    static let collapsedQueueMinimumWidth: CGFloat = 96
    static let collapsedQueueMaximumWidth: CGFloat = 224
    static let minimumOpacity: Double = 0.05
    static let defaultOpacity: Double = 0.70
    static let maximumOpacity: Double = 1.0
    static let queueButtonHitSize: CGFloat = 30
    static let queueHoverDelayMilliseconds = 300
    static let queueMinimumWidth: CGFloat = 150
    static let queueMaximumWidth: CGFloat = 420
    static let queueHorizontalInset: CGFloat = 12
    static let editorLineSpacing: CGFloat = 1

    enum QuickInputGlassRole: Equatable {
        case composer
        case collapsedQueuePill(emphasized: Bool)
        case standaloneQueueCapsule(emphasized: Bool)
        case elevatedCapsule(emphasized: Bool)
    }

    struct QuickInputGlassRecipe: Equatable {
        let backdropOpacity: Double
        let tintOpacity: Double
    }

    /// Maps the user-facing Quick Input opacity setting into paired backdrop-blur
    /// and theme-tint alphas while keeping elevated capsules legible over text.
    static func glassRecipe(role: QuickInputGlassRole, opacity: Double) -> QuickInputGlassRecipe {
        let clamped = min(
            max(opacity.isFinite ? opacity : defaultOpacity, minimumOpacity),
            maximumOpacity
        )
        switch role {
        case .composer:
            return baseGlass(for: clamped)
        case .collapsedQueuePill(let emphasized):
            let base = baseGlass(for: min(maximumOpacity, clamped + 0.05))
            guard emphasized else { return base }
            return QuickInputGlassRecipe(
                backdropOpacity: min(maximumOpacity, base.backdropOpacity + 0.12),
                tintOpacity: min(maximumOpacity, base.tintOpacity + 0.12)
            )
        case .standaloneQueueCapsule(let emphasized):
            let base = baseGlass(for: min(maximumOpacity, clamped + 0.10))
            guard emphasized else { return base }
            return QuickInputGlassRecipe(
                backdropOpacity: min(maximumOpacity, base.backdropOpacity + 0.12),
                tintOpacity: min(maximumOpacity, base.tintOpacity + 0.14)
            )
        case .elevatedCapsule(let emphasized):
            let base = baseGlass(for: min(maximumOpacity, max(0.25, clamped + 0.20)))
            guard emphasized else { return base }
            return QuickInputGlassRecipe(
                backdropOpacity: min(maximumOpacity, base.backdropOpacity + 0.08),
                tintOpacity: min(maximumOpacity, base.tintOpacity + 0.12)
            )
        }
    }

    private static func baseGlass(for level: Double) -> QuickInputGlassRecipe {
        let clamped = min(max(level, minimumOpacity), maximumOpacity)
        let norm = (clamped - minimumOpacity) / (maximumOpacity - minimumOpacity)
        let backdrop = min(1.0, 0.14 + norm * 1.14)
        let tint = min(1.0, 0.03 + 0.97 * pow(norm, 2.2))
        return QuickInputGlassRecipe(backdropOpacity: backdrop, tintOpacity: tint)
    }

    static func queueCardWidth(
        previewCount: Int,
        availableWidth: CGFloat
    ) -> CGFloat {
        let estimated = CGFloat(previewCount) * 7.5 + 110
        let available = max(1, availableWidth - queueHorizontalInset * 2)
        return min(
            max(estimated, queueMinimumWidth),
            min(queueMaximumWidth, available)
        )
    }

    static func collapsedQueueWidth(
        labelCount: Int,
        availableWidth: CGFloat
    ) -> CGFloat {
        let estimated = CGFloat(labelCount) * 7.2 + 56
        let available = max(1, availableWidth - floatingHorizontalInset * 2)
        return min(
            max(estimated, collapsedQueueMinimumWidth),
            min(collapsedQueueMaximumWidth, available)
        )
    }

    static func reservedAccessoryHeight(
        dockHeight: CGFloat,
        isDockPresented: Bool,
        hasQueue: Bool,
        isPinned: Bool = false
    ) -> CGFloat {
        _ = dockHeight
        _ = isDockPresented
        _ = hasQueue
        _ = isPinned
        return 0
    }

    static func displayColumnCount(_ text: String) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            columns += isWideScalar(scalar.value) ? 2 : 1
        }
        return columns
    }

    private static func isWideScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F,
             0x2E80...0x303E,
             0x3040...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE6F,
             0xFF01...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            true
        default:
            false
        }
    }
}

enum AgentQuickInputMotion {
    static let queue = Animation.spring(
        response: 0.42,
        dampingFraction: 0.72,
        blendDuration: 0.12
    )
}

struct AgentQuickInputQueueItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }

    var preview: String {
        let line = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}

struct AgentQuickInputPaneState: Equatable, Sendable {
    var draft = ""
    var agentDraftShortcut: String?
    var agentDraftProcessID: Int?
    var queue: [AgentQuickInputQueueItem] = []
}

@MainActor
final class AgentQuickInputModel: ObservableObject {
    @Published private(set) var isPresented = false {
        didSet {
            if !isSynchronizingGlobal { globalPresentation?.setPresented(isPresented) }
        }
    }
    @Published private(set) var targetSurfaceID: UUID?
    @Published var draft = "" {
        didSet {
            guard !isApplyingState, let targetSurfaceID else { return }
            if isQueueExpanded { isQueueExpanded = false }
            if historyPresentation.isPresented { historyPresentation.close() }
            historyNavigation.edited()
            var state = paneStates[targetSurfaceID] ?? .init()
            state.draft = draft
            paneStates[targetSurfaceID] = state
        }
    }
    @Published private(set) var paneStates: [UUID: AgentQuickInputPaneState] = [:]
    @Published private(set) var statusMessage: String?
    @Published private(set) var dockHeight: CGFloat
    @Published private(set) var editingQueueItemID: UUID?
    @Published private(set) var focusRequestID = 0
    @Published private(set) var isPinned = false
    @Published var isQueueExpanded = false
    @Published var composerQueueLeadingOffset: CGFloat = 110
    @Published var composerHistoryLeadingOffset: CGFloat = 78
    let historyPresentation = QuickInputHistoryPresentation()
    private var historyNavigation = QuickInputHistoryNavigation()
    private var presentationObserver: AnyCancellable?
    private var globalObservers: Set<AnyCancellable> = []
    private var globalPresentation: QuickInputGlobalPresentation?
    private var isSynchronizingGlobal = false
    private var currentSurfaceID: (() -> UUID?)?

    private var draftBeforeEditing: String?
    private var isApplyingState = false
    private var pendingDockHeight: CGFloat?
    private var dockResizeWorkItem: DispatchWorkItem?
    let historyStore: QuickInputHistoryStore
    private(set) var historyTabID = UUID()
    private var historyObserver: AnyCancellable?

    init(dockHeight: CGFloat? = nil, historyStore: QuickInputHistoryStore? = nil,
         globalPresentation: QuickInputGlobalPresentation? = nil) {
        self.globalPresentation = globalPresentation
        self.historyStore = historyStore ?? QuickInputHistoryStore()
        self.dockHeight = dockHeight ?? CGFloat(
            OhMyGhosttySettings.shared.quickInputHeight
        )
        historyObserver = self.historyStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        presentationObserver = historyPresentation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        bindPresentation(globalPresentation)
    }

    func bindPresentation(_ presentation: QuickInputGlobalPresentation?) {
        guard globalPresentation !== presentation || globalObservers.isEmpty else { return }
        globalObservers.removeAll()
        globalPresentation = presentation
        if let globalPresentation = presentation {
            globalPresentation.$height.sink { [weak self] height in
                self?.dockResizeWorkItem?.cancel()
                self?.pendingDockHeight = nil
                if self?.dockHeight != CGFloat(height) { self?.dockHeight = CGFloat(height) }
            }.store(in: &globalObservers)
            globalPresentation.$isPresented.sink { [weak self] visible in
                self?.synchronizeGlobalPresentation(visible)
            }.store(in: &globalObservers)
            globalPresentation.$isPinned.sink { [weak self] pinned in
                if self?.isPinned != pinned { self?.isPinned = pinned }
            }.store(in: &globalObservers)
        }
    }

    func bindGlobalTarget(_ currentSurfaceID: @escaping () -> UUID?) {
        self.currentSurfaceID = currentSurfaceID
        if let globalPresentation { synchronizeGlobalPresentation(globalPresentation.isPresented) }
    }

    private func synchronizeGlobalPresentation(_ visible: Bool) {
        isSynchronizingGlobal = true
        defer { isSynchronizingGlobal = false }
        if visible {
            guard let surfaceID = currentSurfaceID?() ?? targetSurfaceID else { return }
            present(for: surfaceID, requestFocus: false)
        } else {
            if isEditingQueuedItem { cancelQueuedItemEdit() }
            isQueueExpanded = false
            historyPresentation.close()
            historyNavigation.edited()
            if isPresented { isPresented = false }
        }
    }

    func bindHistory(to tabID: UUID, paneIDs: Set<UUID>) {
        historyTabID = tabID
        historyStore.bind(paneIDs: paneIDs, to: tabID)
    }

    var targetQueue: [AgentQuickInputQueueItem] {
        guard let targetSurfaceID else { return [] }
        return paneStates[targetSurfaceID]?.queue ?? []
    }

    static let historyLimit = QuickInputHistoryStore.perPaneLimit

    // Pane-scoped projection for callers that need only this pane's sends.
    // Interactive history navigation uses the configured visibility scope.
    var targetHistory: [String] {
        historyStore.visibleEntries(paneID: targetSurfaceID, tabID: historyTabID, scope: .pane)
            .reversed().map(\.text)
    }

    func recordSentText(_ text: String, for surfaceID: UUID, historyID: UUID? = nil) {
        historyStore.record(text, paneID: surfaceID, tabID: historyTabID, id: historyID)
    }

    @discardableResult
    func recallLastSentText() -> Bool {
        guard draft.isEmpty, !isEditingQueuedItem,
              let text = targetHistory.last else { return false }
        useHistoryText(text)
        return true
    }

    func useHistoryText(_ text: String, mode: QuickInputHistoryInsertionMode = .append) {
        guard !isEditingQueuedItem, targetSurfaceID != nil else { return }
        draft = mode == .replace || draft.isEmpty
            ? text : draft + (draft.hasSuffix("\n") ? "" : "\n") + text
        statusMessage = nil
        requestFocus()
    }

    /// Agent imports are snapshots, unlike explicit history insertion.
    func importAgentDraft(_ text: String, shortcut: String = "control+g", processID: Int? = nil) {
        guard let targetSurfaceID, !isEditingQueuedItem else { return }
        var state = paneStates[targetSurfaceID] ?? .init()
        state.agentDraftShortcut = text.isEmpty ? nil : shortcut
        state.agentDraftProcessID = text.isEmpty ? nil : processID
        paneStates[targetSurfaceID] = state
        guard !text.isEmpty, !draft.hasPrefix(text), !draft.hasSuffix(text) else { return }
        useHistoryText(text)
    }

    func agentDraftShortcut(for surfaceID: UUID, foregroundPID: Int?) -> String? {
        guard let state = paneStates[surfaceID],
              state.agentDraftProcessID == nil || state.agentDraftProcessID == foregroundPID else { return nil }
        return state.agentDraftShortcut
    }

    func didSubmitAgentDraft(for surfaceID: UUID) {
        guard var state = paneStates[surfaceID] else { return }
        state.agentDraftShortcut = nil
        state.agentDraftProcessID = nil
        paneStates[surfaceID] = state
    }

    /// A send may finish after editing or switching panes. Clear only the
    /// submitted draft, leaving any newer text available for the next send.
    func completeSubmittedDraft(_ text: String, for surfaceID: UUID) {
        if targetSurfaceID == surfaceID, isEditingQueuedItem, draftBeforeEditing == text {
            draftBeforeEditing = ""
        }
        guard var state = paneStates[surfaceID], state.draft == text else { return }
        state.draft = ""
        paneStates[surfaceID] = state
        guard targetSurfaceID == surfaceID, draft == text, !isEditingQueuedItem else { return }
        completeSubmission(clearDraft: true)
    }

    func togglePinned() {
        if let globalPresentation { globalPresentation.togglePinned() } else { isPinned.toggle() }
    }

    func toggleHistory(scope: QuickInputHistoryScope) {
        guard !isEditingQueuedItem else { return }
        if historyPresentation.isPresented {
            historyPresentation.close()
            requestFocus()
        } else {
            isQueueExpanded = false
            historyPresentation.open(entries: historyStore.visibleEntries(
                paneID: targetSurfaceID, tabID: historyTabID, scope: scope,
                query: historyPresentation.isSearching ? historyPresentation.query : ""
            ))
        }
    }

    func toggleQueueExpanded() {
        if !isQueueExpanded {
            historyPresentation.close()
        }
        isQueueExpanded.toggle()
    }

    func collapseAccessoryStacks(restoreComposerFocus: Bool = false) {
        var didClose = false
        if isQueueExpanded {
            isQueueExpanded = false
            didClose = true
        }
        if historyPresentation.isPresented {
            historyPresentation.close()
            didClose = true
        }
        if didClose, restoreComposerFocus {
            requestFocus()
        }
    }

    func historyCaretMoved() { historyNavigation.caretMoved() }

    func navigateHistory(_ direction: QuickInputHistoryDirection, current: QuickInputDraftSnapshot,
                         scope: QuickInputHistoryScope, atBoundary: Bool,
                         isRepeat: Bool) -> QuickInputHistoryNavigationResult {
        guard !isEditingQueuedItem else { return .unhandled }
        let entries = historyStore.visibleEntries(paneID: targetSurfaceID, tabID: historyTabID, scope: scope)
        let result = historyNavigation.navigate(direction, current: current, entries: entries.map(\.text),
                                                atBoundary: atBoundary, isRepeat: isRepeat)
        if case .restore(let snapshot) = result {
            // Browsing changes the display only. Keep the newest unsent draft
            // in pane state for dismiss/reopen, pane switches and pane moves.
            // User edits go through draft.didSet and promote to that latest slot.
            applyDraft(snapshot.text)
        }
        return result
    }

    /// Pin changes automatic completion only; explicit dismiss always wins.
    func completeSubmission(clearDraft: Bool) {
        historyPresentation.close()
        historyNavigation.edited()
        if isPinned {
            if clearDraft { draft = "" }
            statusMessage = nil
            requestFocus()
        } else {
            dismiss(preservingDraft: !clearDraft)
        }
    }

    var isEditingQueuedItem: Bool { editingQueueItemID != nil }

    func present(for surfaceID: UUID, requestFocus: Bool = true) {
        if isPresented, targetSurfaceID == surfaceID {
            if requestFocus { self.requestFocus() }
            return
        }
        if isEditingQueuedItem, targetSurfaceID != surfaceID {
            let wasSynchronizingGlobal = isSynchronizingGlobal
            isSynchronizingGlobal = true
            cancelQueuedItemEdit()
            isSynchronizingGlobal = wasSynchronizingGlobal
        }
        historyNavigation.edited()
        if targetSurfaceID != surfaceID {
            historyPresentation.close()
            isQueueExpanded = false
        }
        targetSurfaceID = surfaceID
        applyDraft(paneStates[surfaceID]?.draft ?? "")
        statusMessage = nil
        isPresented = true
        if requestFocus { self.requestFocus() }
    }

    func requestFocus() {
        guard isPresented else { return }
        focusRequestID &+= 1
    }

    func dismiss(preservingDraft: Bool = true) {
        isQueueExpanded = false
        historyPresentation.close()
        historyNavigation.edited()
        if isEditingQueuedItem {
            cancelQueuedItemEdit()
            return
        }
        if !preservingDraft, let targetSurfaceID {
            var state = paneStates[targetSurfaceID] ?? .init()
            state.draft = ""
            paneStates[targetSurfaceID] = state
            applyDraft("")
        }
        statusMessage = nil
        isPresented = false
    }

    @discardableResult
    func enqueueDraft() -> AgentQuickInputQueueItem? {
        guard let targetSurfaceID,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Enter a message first."
            return nil
        }
        let item = AgentQuickInputQueueItem(text: draft)
        var state = paneStates[targetSurfaceID] ?? .init()
        state.queue.append(item)
        state.draft = ""
        paneStates[targetSurfaceID] = state
        historyStore.record(item.text, paneID: targetSurfaceID, tabID: historyTabID, id: item.id, delivery: .queued)
        applyDraft("")
        statusMessage = "Queued message \(state.queue.count)."
        return item
    }

    func dequeue(for surfaceID: UUID) -> AgentQuickInputQueueItem? {
        guard var state = paneStates[surfaceID], !state.queue.isEmpty else { return nil }
        let item = state.queue.removeFirst()
        paneStates[surfaceID] = state
        if targetSurfaceID == surfaceID, state.queue.isEmpty {
            isQueueExpanded = false
        }
        return item
    }

    func removeQueuedItem(_ itemID: UUID, for surfaceID: UUID) {
        guard var state = paneStates[surfaceID] else { return }
        if editingQueueItemID == itemID, targetSurfaceID == surfaceID {
            cancelQueuedItemEdit()
        }
        state.queue.removeAll { $0.id == itemID }
        paneStates[surfaceID] = state
        if targetSurfaceID == surfaceID, state.queue.isEmpty {
            isQueueExpanded = false
        }
        historyStore.cancelQueuedEntry(itemID)
    }

    func editQueuedItem(_ itemID: UUID, for surfaceID: UUID) {
        guard let state = paneStates[surfaceID],
              let item = state.queue.first(where: { $0.id == itemID }) else {
            return
        }
        isQueueExpanded = false
        historyNavigation.edited()
        historyPresentation.close()
        editingQueueItemID = itemID
        draftBeforeEditing = state.draft
        targetSurfaceID = surfaceID
        applyDraft(item.text)
        statusMessage = nil
        isPresented = true
        requestFocus()
    }

    @discardableResult
    func confirmQueuedItemEdit(moveToEnd: Bool) -> Bool {
        guard let surfaceID = targetSurfaceID,
              let itemID = editingQueueItemID,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var state = paneStates[surfaceID],
              let index = state.queue.firstIndex(where: { $0.id == itemID }) else {
            statusMessage = "Enter a message first."
            return false
        }
        let original = state.queue[index]
        let updated = AgentQuickInputQueueItem(
            id: original.id,
            text: draft,
            createdAt: original.createdAt
        )
        if moveToEnd {
            state.queue.remove(at: index)
            state.queue.append(updated)
        } else {
            state.queue[index] = updated
        }
        state.draft = draftBeforeEditing ?? ""
        paneStates[surfaceID] = state
        historyStore.record(updated.text, paneID: surfaceID, tabID: historyTabID, id: updated.id, delivery: .queued)
        finishQueuedItemEdit(restoredDraft: state.draft, automatically: true)
        return true
    }

    func cancelQueuedItemEdit() {
        guard isEditingQueuedItem else { return }
        let restoredDraft = draftBeforeEditing ?? ""
        if let targetSurfaceID {
            var state = paneStates[targetSurfaceID] ?? .init()
            state.draft = restoredDraft
            paneStates[targetSurfaceID] = state
        }
        finishQueuedItemEdit(restoredDraft: restoredDraft)
    }

    func updateDockHeight(
        _ proposedHeight: CGFloat,
        availableHeight: CGFloat,
        persist: Bool
    ) {
        let maximum = min(
            AgentQuickInputMetrics.maximumHeight,
            max(
                AgentQuickInputMetrics.minimumHeight,
                availableHeight - AgentQuickInputMetrics.minimumTerminalHeight
            )
        )
        let height = min(
            max(proposedHeight, AgentQuickInputMetrics.minimumHeight),
            maximum
        )
        pendingDockHeight = height
        if persist {
            dockResizeWorkItem?.cancel()
            dockResizeWorkItem = nil
            applyPendingDockHeight()
            globalPresentation?.setHeight(Double(height))
            if OhMyGhosttySettings.shared.quickInputHeight != Double(height) {
                OhMyGhosttySettings.shared.quickInputHeight = Double(height)
            }
            return
        }
        guard dockResizeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.dockResizeWorkItem = nil
            self?.applyPendingDockHeight()
        }
        dockResizeWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func applyConfiguredDockHeight(_ height: CGFloat, availableHeight: CGFloat) {
        updateDockHeight(height, availableHeight: availableHeight, persist: false)
    }

    func state(for surfaceID: UUID) -> AgentQuickInputPaneState? {
        paneStates[surfaceID]
    }

    func restore(_ state: AgentQuickInputPaneState?, for surfaceID: UUID) {
        if let state, state != AgentQuickInputPaneState() {
            paneStates[surfaceID] = state
        } else {
            paneStates.removeValue(forKey: surfaceID)
        }
        if targetSurfaceID == surfaceID {
            applyDraft(state?.draft ?? "")
        }
    }

    func removeState(for surfaceID: UUID) {
        paneStates.removeValue(forKey: surfaceID)
        if targetSurfaceID == surfaceID {
            isSynchronizingGlobal = true
            defer { isSynchronizingGlobal = false }
            isQueueExpanded = false
            historyPresentation.close()
            historyNavigation.edited()
            isPresented = false
            targetSurfaceID = nil
            editingQueueItemID = nil
            draftBeforeEditing = nil
            applyDraft("")
        }
    }

    func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    private func applyDraft(_ value: String) {
        isApplyingState = true
        draft = value
        isApplyingState = false
    }

    private func finishQueuedItemEdit(restoredDraft: String, automatically: Bool = false) {
        editingQueueItemID = nil
        draftBeforeEditing = nil
        historyNavigation.edited()
        applyDraft(restoredDraft)
        statusMessage = nil
        isPresented = automatically && isPinned
        if isPresented { requestFocus() }
    }

    private func applyPendingDockHeight() {
        guard let pendingDockHeight else { return }
        self.pendingDockHeight = nil
        guard dockHeight != pendingDockHeight else { return }
        dockHeight = pendingDockHeight
    }
}

struct OMGShortcutRecorder: NSViewRepresentable {
    @Binding var storageValue: String

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onCapture = { shortcut in
            storageValue = shortcut.storageValue
        }
        button.updateShortcut(storageValue)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onCapture = { shortcut in
            storageValue = shortcut.storageValue
        }
        button.updateShortcut(storageValue)
    }
}

final class ShortcutRecorderButton: NSButton {
    var onCapture: ((OMGKeyboardShortcut) -> Void)?
    private var isRecording = false
    private var currentStorageValue = OMGKeyboardShortcut.defaultQuickInput.storageValue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setButtonType(.momentaryPushIn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func updateShortcut(_ storageValue: String) {
        currentStorageValue = storageValue
        guard !isRecording else { return }
        title = OMGKeyboardShortcut(storageValue: storageValue)?.displayValue
            ?? OMGKeyboardShortcut.defaultQuickInput.displayValue
    }

    @objc private func beginRecording() {
        isRecording = true
        title = SettingsStrings(language: OhMyGhosttySettings.shared.language).t("Press shortcut…", "请按下快捷键…")
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        // Clicking elsewhere cancels, instead of leaving a stale "Press shortcut…".
        if isRecording {
            isRecording = false
            updateShortcut(currentStorageValue)
        }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            updateShortcut(currentStorageValue)
            return
        }
        guard let shortcut = OMGKeyboardShortcut(event: event) else {
            NSSound.beep()
            return
        }
        isRecording = false
        title = shortcut.displayValue
        onCapture?(shortcut)
        window?.makeFirstResponder(nil)
    }
}

struct AgentQuickInputDock<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @ObservedObject private var secureInput = SecureInput.shared
    let content: Content

    @State private var isQueueStackMounted = false
    @State private var queueUnmountTask: Task<Void, Never>?
    @State private var isHistoryStackMounted = false
    @State private var historyUnmountTask: Task<Void, Never>?

    init(
        controller: TerminalController,
        model: AgentQuickInputModel,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.model = model
        self.content = content()
    }

    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }
    private var shouldShowQueueStack: Bool {
        model.isPresented && model.isQueueExpanded && !model.targetQueue.isEmpty
    }
    private var hasRenderableQueue: Bool {
        model.isPresented && !model.targetQueue.isEmpty && model.targetSurfaceID != nil
    }
    private var shouldShowHistoryStack: Bool {
        model.isPresented && model.historyPresentation.isPresented
    }
    private var isPasswordLocked: Bool {
        _ = secureInput.enabled
        return controller.isQuickInputPasswordLocked(for: model.targetSurfaceID)
    }
    private var visibleHistoryEntries: [QuickInputHistoryEntry] {
        model.historyStore.visibleEntries(
            paneID: model.targetSurfaceID,
            tabID: model.historyTabID,
            scope: settings.quickInputHistoryScope,
            query: model.historyPresentation.isSearching ? model.historyPresentation.query : ""
        )
    }

    private struct OverlayConfiguration {
        let width: CGFloat?
        let height: CGFloat
        let origin: CGPoint?
        let view: AnyView
    }

    private func overlayConfiguration(
        availableWidth: CGFloat,
        maxStackHeight: CGFloat,
        queue: [AgentQuickInputQueueItem]
    ) -> OverlayConfiguration {
        let showHistoryHost = model.isPresented
            && (model.historyPresentation.isPresented || isHistoryStackMounted)
        let showQueueHost = !showHistoryHost && hasRenderableQueue && isQueueStackMounted

        if showHistoryHost {
            let entries = visibleHistoryEntries
            return OverlayConfiguration(
                width: QuickInputHistoryLayout.stackWidth(entries: entries, availableWidth: availableWidth),
                height: QuickInputHistoryLayout.stackHeight(
                    entryCount: entries.count,
                    storageError: model.historyStore.storageError != nil,
                    maxHeight: maxStackHeight
                ),
                origin: CGPoint(x: model.composerHistoryLeadingOffset, y: 38),
                view: AnyView(historyStackOverlay(availableWidth: availableWidth, maxHeight: maxStackHeight))
            )
        }
        if showQueueHost {
            return OverlayConfiguration(
                width: QuickInputQueueStackLayout.stackWidth(
                    items: queue,
                    editingItemID: model.editingQueueItemID,
                    availableWidth: availableWidth
                ),
                height: QuickInputQueueStackLayout.stackHeight(itemCount: queue.count, maxHeight: maxStackHeight),
                origin: CGPoint(x: model.composerQueueLeadingOffset, y: 38),
                view: AnyView(queueStackOverlay(availableWidth: availableWidth, maxHeight: maxStackHeight))
            )
        }
        return OverlayConfiguration(width: nil, height: 0, origin: nil, view: AnyView(EmptyView()))
    }

    var body: some View {
        let queue = model.targetQueue
        let availableWidth = controller.window?.contentLayoutRect.width ?? 1_000
        let maxStackHeight = max(80, controller.quickInputAvailableHeight() - 38)
        let overlay = overlayConfiguration(
            availableWidth: availableWidth,
            maxStackHeight: maxStackHeight,
            queue: queue
        )

        AgentQuickInputDockContainer(
            content: AnyView(content),
            composer: AnyView(composer),
            queue: overlay.view,
            composerHeight: model.isPresented ? model.dockHeight : 0,
            queueHeight: overlay.height,
            queueWidth: overlay.width,
            composerAccessoryOrigin: overlay.origin,
            onOutsideAccessoryMouseDown: { model.collapseAccessoryStacks() },
            isPinned: model.isPinned
        )
        .onAppear {
            syncQueueStackMount(expanded: shouldShowQueueStack, immediateDismiss: true)
            syncHistoryStackMount(expanded: shouldShowHistoryStack, immediateDismiss: true)
        }
        .onChange(of: model.isQueueExpanded) { _ in
            syncQueueStackMount(
                expanded: shouldShowQueueStack,
                immediateDismiss: !model.isPresented || queue.isEmpty || model.historyPresentation.isPresented
            )
        }
        .onChange(of: model.historyPresentation.isPresented) { open in
            if open {
                syncQueueStackMount(expanded: false, immediateDismiss: true)
            }
            syncHistoryStackMount(
                expanded: shouldShowHistoryStack,
                immediateDismiss: !model.isPresented || model.isQueueExpanded
            )
        }
        .onChange(of: model.isPresented) { presented in
            if !presented { model.isQueueExpanded = false }
            syncQueueStackMount(expanded: shouldShowQueueStack, immediateDismiss: !presented)
            syncHistoryStackMount(expanded: shouldShowHistoryStack, immediateDismiss: !presented)
        }
        .onChange(of: queue.isEmpty) { empty in
            if empty { model.isQueueExpanded = false }
            syncQueueStackMount(expanded: shouldShowQueueStack, immediateDismiss: empty)
        }
    }

    private func syncQueueStackMount(expanded: Bool, immediateDismiss: Bool) {
        queueUnmountTask?.cancel()
        queueUnmountTask = nil
        if expanded {
            isQueueStackMounted = true
            return
        }
        if immediateDismiss {
            isQueueStackMounted = false
            return
        }
        queueUnmountTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            isQueueStackMounted = false
        }
    }

    private func syncHistoryStackMount(expanded: Bool, immediateDismiss: Bool) {
        historyUnmountTask?.cancel()
        historyUnmountTask = nil
        if expanded {
            isHistoryStackMounted = true
            return
        }
        if immediateDismiss {
            isHistoryStackMounted = false
            return
        }
        historyUnmountTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            isHistoryStackMounted = false
        }
    }

    @ViewBuilder
    private func queueStackOverlay(availableWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if hasRenderableQueue, isQueueStackMounted, let surfaceID = model.targetSurfaceID {
            AgentQuickInputQueueCapsuleStack(
                items: model.targetQueue,
                editingItemID: model.editingQueueItemID,
                isSendLocked: isPasswordLocked,
                chromeBackground: controller.quickInputAccessoryBackground(isPinned: model.isPinned),
                strings: strings,
                isExpanded: model.isQueueExpanded,
                elevatedOverCard: true,
                alignment: .leading,
                scaleAnchor: .bottomLeading,
                availableWidth: availableWidth,
                maxHeight: maxHeight,
                send: { controller.sendQueuedQuickInput($0, from: surfaceID) },
                edit: { controller.editQueuedQuickInput($0, from: surfaceID) },
                remove: { controller.removeQueuedQuickInput($0, from: surfaceID) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            EmptyView()
        }
    }

    private func historyStackOverlay(availableWidth: CGFloat, maxHeight: CGFloat) -> some View {
        QuickInputHistoryView(
            model: model,
            store: model.historyStore,
            settings: settings,
            chromeBackground: controller.quickInputAccessoryBackground(isPinned: model.isPinned),
            isExpanded: model.historyPresentation.isPresented,
            availableWidth: availableWidth,
            maxHeight: maxHeight
        ) { text in
            model.historyPresentation.close()
            model.useHistoryText(text, mode: settings.quickInputHistoryInsertionMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var composer: some View {
        AgentQuickInputComposer(
            controller: controller,
            model: model
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
    }
}

struct AgentQuickInputPaneQueueOverlay: View {
    @Environment(\.editorTerminalController) private var controller
    let surfaceView: Ghostty.SurfaceView
    var availableWidth: CGFloat = 1_000
    var availableHeight: CGFloat = 1_000

    var body: some View {
        if let controller {
            AgentQuickInputPaneQueueBadgeHost(
                controller: controller,
                model: controller.quickInputModel,
                surfaceID: surfaceView.id,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )
        }
    }
}

private struct AgentQuickInputPaneQueueBadgeHost: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel
    let surfaceID: UUID
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @ObservedObject private var secureInput = SecureInput.shared
    @State private var isExpanded = false
    @State private var isStackMounted = false
    @State private var unmountTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }
    private var queue: [AgentQuickInputQueueItem] {
        model.state(for: surfaceID)?.queue ?? []
    }
    private var isTargetedByOpenComposer: Bool {
        model.isPresented && model.targetSurfaceID == surfaceID
    }
    private var shouldShow: Bool {
        !queue.isEmpty && !isTargetedByOpenComposer
    }
    private var isSendLocked: Bool {
        _ = secureInput.enabled
        return controller.isQuickInputPasswordLocked(for: surfaceID)
    }
    private var maxStackHeight: CGFloat {
        max(QuickInputQueueStackLayout.capsuleHeight, availableHeight - 68)
    }

    var body: some View {
        if shouldShow {
            let label = collapsedPillLabel(for: queue)
            let editingID = model.targetSurfaceID == surfaceID ? model.editingQueueItemID : nil
            let collapsedWidth = AgentQuickInputMetrics.collapsedQueueWidth(
                labelCount: AgentQuickInputMetrics.displayColumnCount(label),
                availableWidth: availableWidth
            )
            let expandedWidth = QuickInputQueueStackLayout.stackWidth(
                items: queue,
                editingItemID: editingID,
                availableWidth: availableWidth,
                minimumWidth: collapsedWidth
            )
            let activePillWidth = isExpanded ? expandedWidth : collapsedWidth
            let pillAnimation: Animation = reduceMotion
                ? .linear(duration: 0.01)
                : .spring(response: 0.28, dampingFraction: 0.80)
            let chromeBackground = controller.quickInputAccessoryBackground(isPinned: model.isPinned)
            VStack(alignment: .trailing, spacing: QuickInputQueueStackLayout.capsuleSpacing) {
                if isStackMounted {
                    AgentQuickInputQueueCapsuleStack(
                        items: queue,
                        editingItemID: editingID,
                        isSendLocked: isSendLocked,
                        chromeBackground: chromeBackground,
                        strings: strings,
                        isExpanded: isExpanded,
                        alignment: .trailing,
                        scaleAnchor: .bottomTrailing,
                        availableWidth: availableWidth,
                        maxHeight: maxStackHeight,
                        minimumWidth: collapsedWidth,
                        send: { controller.sendQueuedQuickInput($0, from: surfaceID) },
                        edit: { itemID in
                            collapseStack(immediate: true)
                            controller.editQueuedQuickInput(itemID, from: surfaceID)
                        },
                        remove: { controller.removeQueuedQuickInput($0, from: surfaceID) }
                    )
                }

                AgentQuickInputCollapsedQueuePill(
                    items: queue,
                    chromeBackground: chromeBackground,
                    strings: strings,
                    isExpanded: isExpanded,
                    toggle: toggleExpanded
                )
                .frame(width: activePillWidth, height: AgentQuickInputMetrics.collapsedQueueHeight)
                .animation(pillAnimation, value: isExpanded)
                .background(FloatingAccessoryAnchor())
            }
            .background(QuickInputScrollTrapBackground(isActive: isExpanded))
            .padding(.trailing, 16)
            .padding(.bottom, 14)
            .onChange(of: queue.isEmpty) { empty in
                if empty { collapseStack(immediate: true) }
            }
            .onChange(of: isTargetedByOpenComposer) { hidden in
                if hidden { collapseStack(immediate: true) }
            }
        }
    }

    private func toggleExpanded() {
        unmountTask?.cancel()
        unmountTask = nil
        if isExpanded {
            collapseStack(immediate: false)
        } else {
            isStackMounted = true
            isExpanded = true
        }
    }

    private func collapseStack(immediate: Bool) {
        unmountTask?.cancel()
        unmountTask = nil
        isExpanded = false
        if immediate {
            isStackMounted = false
            return
        }
        unmountTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            isStackMounted = false
        }
    }

    private func collapsedPillLabel(for items: [AgentQuickInputQueueItem]) -> String {
        let badge = strings.quickInputCollapsedQueueBadge(items.count)
        guard let preview = items.first?.preview, !preview.isEmpty else { return badge }
        return "\(badge) · \(preview)"
    }
}

private struct AgentQuickInputResizeHandle: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel
    let color: Color

    var body: some View {
        TerminalResizeBoundary(
            edge: .top,
            color: color,
            currentExtent: { model.dockHeight },
            resize: controller.updateQuickInputHeight,
            accessibilityLabel: "Resize Agent Quick Input",
            defersTerminalResize: false
        )
    }
}

enum QuickInputCapsuleStackViewport {
    static let stepStride: CGFloat = 41
    static let fanOutSettleDelay: Duration = .milliseconds(360)

    static func visibleIndexRange(
        itemCount: Int,
        maxVisible: Int,
        selectedIndex: Int? = nil,
        topScrolledRows: Int? = nil
    ) -> Range<Int> {
        guard itemCount > 0, maxVisible > 0 else { return 0..<0 }
        guard itemCount > maxVisible else { return 0..<itemCount }
        if let topScrolledRows {
            let topIndex = min(
                itemCount - 1,
                max(maxVisible - 1, itemCount - 1 - max(0, topScrolledRows))
            )
            let start = max(0, topIndex - (maxVisible - 1))
            return start..<(topIndex + 1)
        }
        let active = min(max(selectedIndex ?? 0, 0), itemCount - 1)
        if active < maxVisible {
            return 0..<maxVisible
        }
        let start = active - (maxVisible - 1)
        return start..<(start + maxVisible)
    }
}

enum QuickInputQueueStackLayout {
    static let capsuleHeight: CGFloat = 34
    static let capsuleSpacing: CGFloat = 7
    static let maxVisibleCapsules = 5
    static let minimumCapsuleWidth: CGFloat = 176
    static let maximumCapsuleWidth: CGFloat = 380
    static let scrollHorizontalShadowOutset: CGFloat = 14

    static func naturalStackHeight(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let visibleCount = min(itemCount, maxVisibleCapsules)
        return CGFloat(visibleCount) * capsuleHeight
            + CGFloat(max(0, visibleCount - 1)) * capsuleSpacing
    }

    static func stackHeight(
        itemCount: Int,
        maxHeight: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let natural = naturalStackHeight(itemCount: itemCount)
        guard natural > 0 else { return 0 }
        return min(maxHeight, natural)
    }

    static func capsuleWidth(
        previewCount: Int,
        isEditing: Bool = false,
        availableWidth: CGFloat
    ) -> CGFloat {
        let estimated = CGFloat(previewCount) * 7.4 + 132 + (isEditing ? 46 : 0)
        let maxAllowed = min(
            maximumCapsuleWidth,
            max(minimumCapsuleWidth, availableWidth - AgentQuickInputMetrics.floatingHorizontalInset * 2)
        )
        return min(max(estimated, minimumCapsuleWidth), maxAllowed)
    }

    static func stackWidth(
        items: [AgentQuickInputQueueItem],
        editingItemID: UUID?,
        availableWidth: CGFloat,
        minimumWidth: CGFloat = minimumCapsuleWidth
    ) -> CGFloat {
        let availableAfterInset = max(1, availableWidth - AgentQuickInputMetrics.floatingHorizontalInset * 2)
        let maxAllowed = availableAfterInset >= minimumCapsuleWidth
            ? min(maximumCapsuleWidth, availableAfterInset)
            : availableAfterInset
        let floorWidth = min(
            max(minimumWidth, AgentQuickInputMetrics.collapsedQueueMinimumWidth),
            maxAllowed
        )
        guard !items.isEmpty else { return floorWidth }
        let itemsMax = items.map { item in
            min(
                maxAllowed,
                capsuleWidth(
                    previewCount: AgentQuickInputMetrics.displayColumnCount(item.preview),
                    isEditing: item.id == editingItemID,
                    availableWidth: availableWidth
                )
            )
        }.max() ?? floorWidth
        return max(floorWidth, itemsMax)
    }
}

private struct AgentQuickInputQueueCapsuleStack: View {
    let items: [AgentQuickInputQueueItem]
    let editingItemID: UUID?
    let isSendLocked: Bool
    let chromeBackground: Color
    let strings: SettingsStrings
    let isExpanded: Bool
    var elevatedOverCard = false
    let alignment: HorizontalAlignment
    let scaleAnchor: UnitPoint
    let availableWidth: CGFloat
    let maxHeight: CGFloat
    var minimumWidth: CGFloat = QuickInputQueueStackLayout.minimumCapsuleWidth
    let send: (UUID) -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void

    @State private var visualExpanded = false
    @State private var isLiveScrolling = false
    @State private var isFanOutSettled = false
    @State private var topScrolledRows: Int?
    @State private var settleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stackHeight: CGFloat {
        QuickInputQueueStackLayout.stackHeight(itemCount: items.count, maxHeight: maxHeight)
    }

    private var unifiedWidth: CGFloat {
        QuickInputQueueStackLayout.stackWidth(
            items: items,
            editingItemID: editingItemID,
            availableWidth: availableWidth,
            minimumWidth: minimumWidth
        )
    }

    private var needsScroll: Bool {
        items.count > QuickInputQueueStackLayout.maxVisibleCapsules
            || maxHeight < QuickInputQueueStackLayout.naturalStackHeight(itemCount: items.count)
    }

    var body: some View {
        let horizontalOutset = QuickInputQueueStackLayout.scrollHorizontalShadowOutset
        let stackAlignment: Alignment = alignment == .trailing ? .bottomTrailing : .bottomLeading
        let visibleRange = QuickInputCapsuleStackViewport.visibleIndexRange(
            itemCount: items.count,
            maxVisible: QuickInputQueueStackLayout.maxVisibleCapsules,
            topScrolledRows: topScrolledRows
        )

        Group {
            if needsScroll {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        capsuleColumn(
                            width: unifiedWidth,
                            isScrollingContainer: true,
                            visibleRange: visibleRange
                        )
                        .quickInputScrollTargetLayout()
                        .background(
                            QuickInputScrollViewConfigurator(
                                onLiveScrollChanged: { live in
                                    isLiveScrolling = live
                                    if live, !isFanOutSettled {
                                        settleTask?.cancel()
                                        settleTask = nil
                                        withTransaction(Transaction(animation: nil)) {
                                            isFanOutSettled = true
                                        }
                                    }
                                },
                                onTopScrolledRowsChanged: { rows in
                                    if isFanOutSettled {
                                        topScrolledRows = rows
                                    }
                                }
                            )
                        )
                        .padding(.horizontal, horizontalOutset)
                    }
                    .quickInputDefaultBottomScrollAnchor()
                    .quickInputViewAlignedScroll()
                    .quickInputScrollClipDisabled(!isFanOutSettled)
                    .frame(
                        width: unifiedWidth + horizontalOutset * 2,
                        height: stackHeight
                    )
                    .padding(.horizontal, -horizontalOutset)
                    .onAppear {
                        if let firstID = items.first?.id {
                            proxy.scrollTo(firstID, anchor: .bottom)
                        }
                    }
                }
                .frame(width: unifiedWidth, height: stackHeight, alignment: stackAlignment)
            } else {
                capsuleColumn(
                    width: unifiedWidth,
                    isScrollingContainer: false,
                    visibleRange: visibleRange
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued Agent Messages")
        .onAppear {
            startFanOutTransition(expanded: isExpanded)
        }
        .onChange(of: isExpanded) { expanded in
            startFanOutTransition(expanded: expanded)
        }
        .onDisappear {
            settleTask?.cancel()
            settleTask = nil
        }
    }

    private func startFanOutTransition(expanded: Bool) {
        settleTask?.cancel()
        settleTask = nil
        if expanded {
            withTransaction(Transaction(animation: nil)) {
                isFanOutSettled = false
                topScrolledRows = nil
            }
            Task { @MainActor in
                visualExpanded = true
            }
            let delay: Duration = reduceMotion
                ? .milliseconds(30)
                : QuickInputCapsuleStackViewport.fanOutSettleDelay
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                withTransaction(Transaction(animation: nil)) {
                    isFanOutSettled = true
                }
            }
        } else {
            isLiveScrolling = false
            withTransaction(Transaction(animation: nil)) {
                isFanOutSettled = false
            }
            visualExpanded = false
        }
    }

    private func capsuleColumn(
        width: CGFloat,
        isScrollingContainer: Bool,
        visibleRange: Range<Int>
    ) -> some View {
        let bottomUpItems = Array(items.enumerated().reversed())
        let visibleCount = max(1, visibleRange.count)
        return VStack(alignment: alignment, spacing: QuickInputQueueStackLayout.capsuleSpacing) {
            ForEach(bottomUpItems, id: \.element.id) { index, item in
                let isVisibleSlot = !isScrollingContainer || visibleRange.contains(index)
                let slot = max(0, min(index - visibleRange.lowerBound, QuickInputQueueStackLayout.maxVisibleCapsules - 1))
                let hiddenOffscreen = isScrollingContainer && !isFanOutSettled && !isVisibleSlot
                let travel = CGFloat(min(slot + 1, 5)) * 24
                AgentQuickInputQueueItemCapsule(
                    index: index + 1,
                    item: item,
                    width: width,
                    isEditing: editingItemID == item.id,
                    isSendLocked: isSendLocked,
                    isExpanded: isExpanded && (isFanOutSettled || isVisibleSlot),
                    elevatedOverCard: elevatedOverCard,
                    suppressHover: isLiveScrolling,
                    chromeBackground: chromeBackground,
                    strings: strings,
                    send: { send(item.id) },
                    edit: { edit(item.id) },
                    remove: { remove(item.id) }
                )
                .id(item.id)
                .quickInputScrollCapsuleTransition(
                    enabled: isScrollingContainer && isFanOutSettled,
                    anchor: alignment == .trailing ? .trailing : .leading
                )
                .scaleEffect(visualExpanded ? 1.0 : 0.80, anchor: scaleAnchor)
                .offset(y: visualExpanded ? 0 : travel)
                .opacity(hiddenOffscreen ? 0.0 : (visualExpanded ? 1.0 : 0.0))
                .animation(
                    capsuleAnimation(
                        opening: visualExpanded,
                        distanceFromSwitch: slot,
                        totalCount: visibleCount
                    ),
                    value: visualExpanded
                )
            }
        }
        .frame(width: width)
        .animation(AgentQuickInputMotion.queue, value: items.map(\.id))
    }

    private func capsuleAnimation(
        opening: Bool,
        distanceFromSwitch: Int,
        totalCount: Int
    ) -> Animation {
        if reduceMotion {
            return .linear(duration: 0.01)
        }
        if opening {
            let delay = Double(min(distanceFromSwitch, 6)) * 0.035
            return .spring(response: 0.30, dampingFraction: 0.76).delay(delay)
        }
        let reverseOrder = max(0, min(totalCount - 1 - distanceFromSwitch, 4))
        return .spring(response: 0.22, dampingFraction: 0.88).delay(Double(reverseOrder) * 0.022)
    }
}

private struct AgentQuickInputQueueItemCapsule: View {
    let index: Int
    let item: AgentQuickInputQueueItem
    let width: CGFloat
    let isEditing: Bool
    let isSendLocked: Bool
    let isExpanded: Bool
    var elevatedOverCard = false
    var suppressHover = false
    let chromeBackground: Color
    let strings: SettingsStrings
    let send: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var isHovered = false

    private var colorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    private var fullTooltip: String {
        guard item.text.count > 4_000 else { return item.text }
        return String(item.text.prefix(4_000)) + "\n…"
    }

    var body: some View {
        let materialOverride: NSVisualEffectView.Material? = elevatedOverCard
            ? (colorScheme == .light ? .popover : .hudWindow)
            : nil
        let emphasized = isHovered || isEditing
        let role: AgentQuickInputMetrics.QuickInputGlassRole = elevatedOverCard
            ? .elevatedCapsule(emphasized: emphasized)
            : .standaloneQueueCapsule(emphasized: emphasized)
        let glass = AgentQuickInputMetrics.glassRecipe(
            role: role,
            opacity: settings.quickInputOpacity
        )

        return HStack(spacing: 6) {
            Text("#\(index)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
            if isEditing {
                Text(strings.quickInputEditingBadge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .fixedSize()
            }
            Text(item.preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(fullTooltip)
            Spacer(minLength: 2)
            HStack(spacing: 1) {
                QuickInputQueueIconButton(
                    symbol: isSendLocked ? "lock.fill" : "arrow.turn.down.right",
                    helpText: isSendLocked ? strings.quickInputPasswordLockedMessage : "Send now",
                    hitSize: 26,
                    boxSize: 22,
                    action: send
                )
                .disabled(isSendLocked)

                QuickInputQueueIconButton(
                    symbol: "pencil",
                    helpText: "Edit queued message",
                    hitSize: 26,
                    boxSize: 22,
                    action: edit
                )

                QuickInputQueueIconButton(
                    symbol: "trash",
                    helpText: "Remove queued message",
                    isDestructive: true,
                    hitSize: 26,
                    boxSize: 22,
                    action: remove
                )
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(width: width, height: QuickInputQueueStackLayout.capsuleHeight)
        .background(
            QuickInputGlassSurface(
                cornerRadius: QuickInputQueueStackLayout.capsuleHeight * 0.5,
                themeColor: chromeBackground,
                tintOpacity: glass.tintOpacity,
                colorScheme: colorScheme,
                borderColor: isEditing ? Color.accentColor.opacity(0.65) : nil,
                materialOverride: materialOverride,
                backdropOpacity: glass.backdropOpacity,
                shadowOpacity: elevatedOverCard ? 0.18 : 0.15,
                shadowRadius: 3.5,
                shadowOffsetY: 1.5
            )
        )
        .contentShape(Capsule())
        .onHover { hovering in
            guard !(suppressHover && hovering) else { return }
            isHovered = hovering
        }
        .background(FloatingAccessoryAnchor(isActive: isExpanded))
        .allowsHitTesting(isExpanded)
        .environment(\.colorScheme, colorScheme)
    }
}

struct QuickInputOuterShadowView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let opacity: Float
    var radius: CGFloat = 3.5
    var offsetY: CGFloat = 1.5

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.configure(
            cornerRadius: cornerRadius,
            opacity: opacity,
            radius: radius,
            offsetY: offsetY
        )
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.configure(
            cornerRadius: cornerRadius,
            opacity: opacity,
            radius: radius,
            offsetY: offsetY
        )
    }

    final class HostView: NSView {
        let shadowLayer = CALayer()
        private let maskShape = CAShapeLayer()
        private var cornerRadius: CGFloat = 0
        private var shadowOpacityValue: Float = 0
        private var shadowRadiusValue: CGFloat = 3.5
        private var shadowOffsetYValue: CGFloat = 1.5

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            shadowLayer.backgroundColor = NSColor.clear.cgColor
            shadowLayer.isOpaque = false
            shadowLayer.masksToBounds = false
            shadowLayer.isHidden = true
            maskShape.fillRule = .evenOdd
            shadowLayer.mask = maskShape
            layer?.addSublayer(shadowLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(
            cornerRadius: CGFloat,
            opacity: Float,
            radius: CGFloat,
            offsetY: CGFloat
        ) {
            self.cornerRadius = cornerRadius
            self.shadowOpacityValue = opacity
            self.shadowRadiusValue = radius
            self.shadowOffsetYValue = offsetY
            updateShadowLayer()
        }

        override func layout() {
            super.layout()
            updateShadowLayer()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateShadowLayer()
        }

        private func updateShadowLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            guard !bounds.isEmpty, shadowOpacityValue > 0 else {
                shadowLayer.shadowOpacity = 0
                shadowLayer.shadowPath = nil
                shadowLayer.mask = nil
                shadowLayer.isHidden = true
                return
            }

            let pad = ceil(shadowRadiusValue * 3 + abs(shadowOffsetYValue) + 4)
            shadowLayer.frame = bounds.insetBy(dx: -pad, dy: -pad)
            let cardRect = CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height)
            let clampedCorner = min(cornerRadius, min(bounds.width, bounds.height) * 0.5)
            let cardPath = CGPath(
                roundedRect: cardRect,
                cornerWidth: clampedCorner,
                cornerHeight: clampedCorner,
                transform: nil
            )
            shadowLayer.shadowColor = NSColor.black.cgColor
            shadowLayer.shadowOpacity = shadowOpacityValue
            shadowLayer.shadowRadius = shadowRadiusValue
            shadowLayer.shadowOffset = CGSize(width: 0, height: -shadowOffsetYValue)
            shadowLayer.shadowPath = cardPath
            shadowLayer.isHidden = false

            let maskPath = CGMutablePath()
            maskPath.addRect(shadowLayer.bounds)
            maskPath.addPath(cardPath)
            maskShape.frame = shadowLayer.bounds
            maskShape.path = maskPath
            shadowLayer.mask = maskShape
        }
    }
}

struct QuickInputBackdropBlurView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let isLight: Bool
    var materialOverride: NSVisualEffectView.Material?
    var backdropOpacity: Double = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = materialOverride ?? (isLight ? .selection : .hudWindow)
        view.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        view.alphaValue = CGFloat(min(max(backdropOpacity, 0), 1))
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

struct QuickInputGlassSurface: View {
    let cornerRadius: CGFloat
    let themeColor: Color
    let tintOpacity: Double
    let colorScheme: ColorScheme
    var borderOpacity: Double?
    var borderColor: Color?
    var materialOverride: NSVisualEffectView.Material?
    var backdropOpacity: Double = 1.0
    var shadowOpacity: Float = 0
    var shadowRadius: CGFloat = 3.5
    var shadowOffsetY: CGFloat = 1.5
    var isBackdropActive: Bool = true
    @ObservedObject private var missionControl = MissionControlPresentationMonitor.shared

    var body: some View {
        if !isBackdropActive {
            Color.clear
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let topRim = colorScheme == .light ? 0.52 : 0.22
            let bottomRim = colorScheme == .light ? 0.10 : 0.08
            let rimStroke = LinearGradient(
                colors: [
                    Color.white.opacity(topRim),
                    Color.primary.opacity(bottomRim)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            let suppressBackdrop = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ||
                missionControl.isMissionControlActive

            ZStack {
                if shadowOpacity > 0 {
                    QuickInputOuterShadowView(
                        cornerRadius: cornerRadius,
                        opacity: shadowOpacity,
                        radius: shadowRadius,
                        offsetY: shadowOffsetY
                    )
                    .allowsHitTesting(false)
                }
                if suppressBackdrop {
                    shape.fill(themeColor)
                } else {
                    QuickInputBackdropBlurView(
                        cornerRadius: cornerRadius,
                        isLight: colorScheme == .light,
                        materialOverride: materialOverride,
                        backdropOpacity: backdropOpacity
                    )
                    shape.fill(themeColor.opacity(tintOpacity))
                }
            }
            .overlay {
                if let borderColor {
                    shape
                        .strokeBorder(borderColor, lineWidth: 1.2)
                        .allowsHitTesting(false)
                } else if let borderOpacity {
                    shape
                        .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1)
                        .allowsHitTesting(false)
                } else {
                    shape
                        .strokeBorder(rimStroke, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct AgentQuickInputCollapsedQueuePill: View {
    let items: [AgentQuickInputQueueItem]
    let chromeBackground: Color
    let strings: SettingsStrings
    var isExpanded = false
    let toggle: () -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var isHovered = false

    private var colorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    private var label: String {
        let badge = strings.quickInputCollapsedQueueBadge(items.count)
        guard let preview = items.first?.preview, !preview.isEmpty else { return badge }
        return "\(badge) · \(preview)"
    }

    var body: some View {
        let glass = AgentQuickInputMetrics.glassRecipe(
            role: .collapsedQueuePill(emphasized: isHovered || isExpanded),
            opacity: settings.quickInputOpacity
        )
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .fixedSize()
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary.opacity(0.88))
                Spacer(minLength: 2)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                QuickInputGlassSurface(
                    cornerRadius: AgentQuickInputMetrics.collapsedQueueHeight * 0.5,
                    themeColor: chromeBackground,
                    tintOpacity: glass.tintOpacity,
                    colorScheme: colorScheme,
                    backdropOpacity: glass.backdropOpacity,
                    shadowOpacity: 0.15,
                    shadowRadius: 3.5,
                    shadowOffsetY: 1.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointingHandCursor()
        .help(strings.quickInputCollapsedQueueHelp)
        .accessibilityLabel(strings.quickInputCollapsedQueueBadge(items.count))
        .environment(\.colorScheme, colorScheme)
    }
}

private struct QuickInputQueueIconButtonStyle: ButtonStyle {
    var isDestructive = false
    var hitSize: CGFloat = AgentQuickInputMetrics.queueButtonHitSize
    var boxSize: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let boxFill: Color = if !isEnabled {
            .clear
        } else if isDestructive {
            Color.red.opacity(configuration.isPressed ? 0.22 : (isHovered ? 0.14 : 0))
        } else {
            Color.primary.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.11 : 0))
        }
        let iconColor: Color = if !isEnabled {
            .secondary
        } else if isDestructive && (isHovered || configuration.isPressed) {
            Color.red.opacity(0.9)
        } else if isHovered || configuration.isPressed {
            .primary
        } else {
            .secondary
        }

        return configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: hitSize, height: hitSize)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(boxFill)
                    .frame(width: boxSize, height: boxSize)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

private struct QuickInputQueueIconButton: View {
    let symbol: String
    let helpText: String
    var isDestructive = false
    var hitSize: CGFloat = AgentQuickInputMetrics.queueButtonHitSize
    var boxSize: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(
            QuickInputQueueIconButtonStyle(
                isDestructive: isDestructive,
                hitSize: hitSize,
                boxSize: boxSize
            )
        )
        .help(helpText)
        .accessibilityLabel(helpText)
        .pointingHandCursor()
    }
}

private struct QuickInputPointingHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}

    final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

struct QuickInputScrollViewConfigurator: NSViewRepresentable {
    var onLiveScrollChanged: ((Bool) -> Void)?
    var onTopScrolledRowsChanged: ((Int) -> Void)?

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.onLiveScrollChanged = onLiveScrollChanged
        view.onTopScrolledRowsChanged = onTopScrolledRowsChanged
        return view
    }

    func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.onLiveScrollChanged = onLiveScrollChanged
        view.onTopScrolledRowsChanged = onTopScrolledRowsChanged
        view.configureEnclosingScrollView()
    }

    static func dismantleNSView(_ view: ConfiguratorView, coordinator: ()) {
        view.teardown()
    }

    final class ConfiguratorView: NSView {
        var onLiveScrollChanged: ((Bool) -> Void)?
        var onTopScrolledRowsChanged: ((Int) -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var startObserver: NSObjectProtocol?
        private var endObserver: NSObjectProtocol?
        private var boundsObserver: NSObjectProtocol?
        private var lastReportedTopRows = -1

        deinit {
            detachObservers()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureEnclosingScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureEnclosingScrollView()
        }

        func configureEnclosingScrollView() {
            let scrollView = enclosingScrollView
            if let scrollView {
                scrollView.verticalScrollElasticity = .none
                scrollView.horizontalScrollElasticity = .none
                scrollView.drawsBackground = false
            }
            guard observedScrollView !== scrollView else { return }
            let hadObservedScrollView = observedScrollView != nil
            detachObservers()
            observedScrollView = scrollView
            guard let scrollView else {
                if hadObservedScrollView {
                    let notify = onLiveScrollChanged
                    DispatchQueue.main.async {
                        notify?(false)
                    }
                }
                return
            }
            let center = NotificationCenter.default
            startObserver = center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onLiveScrollChanged?(true)
                }
            }
            endObserver = center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onLiveScrollChanged?(false)
                }
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak clipView = scrollView.contentView] _ in
                guard let clipView else { return }
                let rows = max(0, Int(round(clipView.bounds.minY / QuickInputCapsuleStackViewport.stepStride)))
                Task { @MainActor in
                    guard let self, rows != self.lastReportedTopRows else { return }
                    self.lastReportedTopRows = rows
                    self.onTopScrolledRowsChanged?(rows)
                }
            }
        }

        func teardown() {
            detachObservers()
            observedScrollView = nil
            onLiveScrollChanged = nil
            onTopScrolledRowsChanged = nil
        }

        private func detachObservers() {
            let center = NotificationCenter.default
            if let startObserver {
                center.removeObserver(startObserver)
                self.startObserver = nil
            }
            if let endObserver {
                center.removeObserver(endObserver)
                self.endObserver = nil
            }
            if let boundsObserver {
                center.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            lastReportedTopRows = -1
        }
    }
}

extension View {
    @ViewBuilder
    func pointingHandCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            background(QuickInputPointingHandCursorView())
        }
    }

    @ViewBuilder
    func quickInputScrollTargetLayout() -> some View {
        if #available(macOS 14.0, *) {
            scrollTargetLayout()
        } else {
            self
        }
    }

    @ViewBuilder
    func quickInputViewAlignedScroll() -> some View {
        if #available(macOS 14.0, *) {
            scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }

    @ViewBuilder
    func quickInputDefaultBottomScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            defaultScrollAnchor(.bottom)
        } else {
            self
        }
    }

    @ViewBuilder
    func quickInputScrollClipDisabled(_ disabled: Bool) -> some View {
        if #available(macOS 14.0, *) {
            scrollClipDisabled(disabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func quickInputScrollCapsuleTransition(
        enabled: Bool,
        anchor: UnitPoint
    ) -> some View {
        if enabled, #available(macOS 14.0, *) {
            scrollTransition(.interactive, axis: .vertical) { content, phase in
                content
                    .scaleEffect(phase.isIdentity ? 1.0 : 0.94, anchor: anchor)
                    .opacity(phase.isIdentity ? 1.0 : max(0, 1.0 - abs(phase.value) * 1.15))
            }
        } else {
            self
        }
    }
}

private struct QuickInputPillButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = if isPrimary {
            Color.accentColor.opacity(
                isEnabled && (isHovered || configuration.isPressed)
                    ? (configuration.isPressed ? 0.30 : 0.24)
                    : 0.16
            )
        } else {
            Color.primary.opacity(
                isEnabled && (isHovered || configuration.isPressed)
                    ? (configuration.isPressed ? 0.16 : 0.10)
                    : 0.055
            )
        }
        let stroke: Color = isPrimary
            ? Color.accentColor.opacity(isEnabled ? 0.36 : 0.16)
            : Color.primary.opacity(0.11)

        return configuration.label
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .foregroundStyle(isPrimary ? Color.primary : Color.secondary)
            .background(fill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

private struct QuickInputQueueButtonMinXPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct QuickInputHistoryButtonMinXPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct AgentQuickInputComposer: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel

    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @ObservedObject private var secureInput = SecureInput.shared
    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }
    private var isPasswordLocked: Bool {
        _ = secureInput.enabled
        return controller.isQuickInputPasswordLocked(for: model.targetSurfaceID)
    }
    private var isSendDisabled: Bool {
        isPasswordLocked && !model.isEditingQueuedItem
    }

    /// Paints the terminal-theme translucent frosted glass card over the terminal.
    private var chromeBackground: Color {
        controller.quickInputAccessoryBackground(isPinned: model.isPinned)
    }

    private var cardColorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    var body: some View {
        let cardShape = RoundedRectangle(
            cornerRadius: AgentQuickInputMetrics.cardCornerRadius,
            style: .continuous
        )

        let glass = AgentQuickInputMetrics.glassRecipe(
            role: .composer,
            opacity: settings.quickInputOpacity
        )
        return VStack(alignment: .leading, spacing: 6) {
            AgentQuickInputTextEditor(
                text: $model.draft,
                placeholder: model.isEditingQueuedItem
                    ? strings.quickInputEditQueuedPlaceholder
                    : strings.quickInputPlaceholder,
                isPresented: model.isPresented,
                focusRequestID: model.focusRequestID,
                font: editorFont,
                textColor: OMGThemeBackground.palette(for: controller.window, config: controller.ghostty.config).foreground,
                onPasteImage: { file, completion in
                    guard let surfaceID = model.targetSurfaceID else {
                        completion(Ghostty.Shell.escape(file.path))
                        return
                    }
                    controller.resolveImagePastePath(
                        for: file,
                        surfaceID: surfaceID,
                        reportFailure: true,
                        completion: completion
                    )
                },
                onSend: controller.sendQuickInputDraft,
                onQueue: controller.queueQuickInputDraft,
                onCancel: controller.dismissQuickInput,
                onNavigateHistory: { direction, snapshot, atBoundary, isRepeat in
                    model.navigateHistory(direction, current: snapshot, scope: settings.quickInputHistoryScope,
                                          atBoundary: atBoundary, isRepeat: isRepeat)
                },
                onHistoryCaretMoved: model.historyCaretMoved,
                companionSurfaceID: model.targetSurfaceID,
                onEditorMouseDown: { model.collapseAccessoryStacks() }
            )
            .background(.clear)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: QuickInputFooterStyle.itemSpacing) {
                if !settings.quickInputImportShortcut.isEmpty, !model.isEditingQueuedItem {
                    QuickInputFooterIconButton(
                        title: strings.quickInputImportDraftHelp,
                        symbol: "square.and.arrow.down",
                        isActive: controller.quickInputDraftImportTask != nil
                    ) {
                        controller.importQuickInputDraftFromTerminal(for: model.targetSurfaceID)
                    }
                    .disabled(isPasswordLocked)
                }
                QuickInputFooterIconButton(
                    title: model.isPinned ? strings.quickInputUnpinHelp : strings.quickInputPinHelp,
                    symbol: model.isPinned ? "pin.fill" : "pin",
                    isActive: model.isPinned,
                    action: model.togglePinned
                )
                QuickInputHistoryButton(title: strings.quickInputHistoryButtonHelp,
                                        isActive: model.historyPresentation.isPresented) {
                    controller.toggleQuickInputHistory()
                }
                .disabled(model.isEditingQueuedItem)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: QuickInputHistoryButtonMinXPreferenceKey.self,
                            value: proxy.frame(in: .named("quickInputComposerCard")).minX
                        )
                    }
                )
                if !model.targetQueue.isEmpty {
                    QuickInputQueueButton(
                        title: strings.quickInputQueueButtonHelp,
                        count: model.targetQueue.count,
                        isActive: model.isQueueExpanded,
                        action: model.toggleQueueExpanded
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: QuickInputQueueButtonMinXPreferenceKey.self,
                                value: proxy.frame(in: .named("quickInputComposerCard")).minX
                            )
                        }
                    )
                }
                if isPasswordLocked {
                    Text("·")
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(QuickInputFooterStyle.iconFont)
                        Text(strings.quickInputPasswordLockedMessage)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                } else if let statusMessage = model.statusMessage {
                    Text("·")
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button(action: controller.dismissQuickInput) {
                        QuickInputShortcutHint(
                            symbols: ["escape"],
                            title: strings.quickInputCancelTitle
                        )
                    }
                    .buttonStyle(QuickInputPillButtonStyle())
                    .help("Esc " + strings.quickInputCancelTitle)

                    Button(action: controller.queueQuickInputDraft) {
                        QuickInputShortcutHint(
                            symbols: ["option", "command", "return"],
                            title: model.isEditingQueuedItem
                                ? strings.quickInputMoveTitle
                                : strings.quickInputQueueTitle
                        )
                    }
                    .buttonStyle(QuickInputPillButtonStyle())
                    .help(
                        model.isEditingQueuedItem
                            ? "⌥⌘↩ " + strings.quickInputMoveTitle
                            : "⌥⌘↩ " + strings.quickInputQueueTitle
                    )

                    Button(action: controller.sendQuickInputDraft) {
                        QuickInputShortcutHint(
                            symbols: ["command", "return"],
                            title: model.isEditingQueuedItem
                                ? strings.quickInputSaveTitle
                                : strings.quickInputSendTitle
                        )
                    }
                    .buttonStyle(QuickInputPillButtonStyle(isPrimary: true))
                    .disabled(isSendDisabled)
                    .help(
                        isSendDisabled
                            ? strings.quickInputPasswordLockedMessage
                            : (model.isEditingQueuedItem
                                ? "⌘↩ " + strings.quickInputSaveTitle
                                : "⌘↩ " + strings.quickInputSendTitle)
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .font(QuickInputFooterStyle.font)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            QuickInputGlassSurface(
                cornerRadius: AgentQuickInputMetrics.cardCornerRadius,
                themeColor: chromeBackground,
                tintOpacity: glass.tintOpacity,
                colorScheme: cardColorScheme,
                backdropOpacity: glass.backdropOpacity,
                isBackdropActive: model.isPresented
            )
        )
        .overlay(alignment: .top) {
            AgentQuickInputResizeHandle(
                controller: controller,
                model: model,
                color: .clear
            )
        }
        .coordinateSpace(name: "quickInputComposerCard")
        .onPreferenceChange(QuickInputQueueButtonMinXPreferenceKey.self) { minX in
            guard let minX else { return }
            Task { @MainActor in
                if abs(model.composerQueueLeadingOffset - minX) > 0.5 {
                    model.composerQueueLeadingOffset = minX
                }
            }
        }
        .onPreferenceChange(QuickInputHistoryButtonMinXPreferenceKey.self) { minX in
            guard let minX else { return }
            Task { @MainActor in
                if abs(model.composerHistoryLeadingOffset - minX) > 0.5 {
                    model.composerHistoryLeadingOffset = minX
                }
            }
        }
        .contentShape(cardShape)
        .environment(\.colorScheme, cardColorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Quick Input")
    }

    private var editorFont: NSFont {
        QuickInputTypography.font(family: controller.ghostty.config.fontFamily,
                                  size: CGFloat(controller.ghostty.config.fontSize))
    }
}
