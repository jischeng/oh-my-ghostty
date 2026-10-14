import Foundation

// Separate an immutable sent-history snapshot from the newest editable draft.
// Native TextKit owns visual-line boundaries; this state machine owns browsing.
enum QuickInputHistoryDirection {
    case older
    case newer
}

enum QuickInputHistoryInsertionMode: String, CaseIterable {
    case append
    case replace
}

struct QuickInputDraftSnapshot: Equatable {
    let text: String
    let selection: NSRange
}

enum QuickInputHistoryNavigationResult: Equatable {
    case unhandled
    case consumed
    case restore(QuickInputDraftSnapshot)
}

struct QuickInputHistoryNavigation {
    private var history: [String] = []
    private var latestDraft: QuickInputDraftSnapshot?
    private var index: Int?
    private var armedDirection: QuickInputHistoryDirection?
    private(set) var isContinuous = false

    mutating func edited() {
        self = .init()
    }

    mutating func caretMoved() {
        armedDirection = nil
        isContinuous = false
    }

    mutating func navigate(
        _ direction: QuickInputHistoryDirection,
        current: QuickInputDraftSnapshot,
        entries: [String],
        atBoundary: Bool,
        isRepeat: Bool
    ) -> QuickInputHistoryNavigationResult {
        guard !entries.isEmpty else {
            let saved = latestDraft
            self = .init()
            return saved.map(QuickInputHistoryNavigationResult.restore) ?? .unhandled
        }
        if let saved = latestDraft {
            let available = Set(entries)
            if history.contains(where: { !available.contains($0) }) {
                self = .init()
                return .restore(saved)
            }
        }
        guard direction == .older || index != nil else {
            armedDirection = nil
            return isContinuous ? .consumed : .unhandled
        }
        if !isContinuous {
            guard atBoundary else {
                armedDirection = nil
                return .unhandled
            }
            // Holding Up at a boundary must not accidentally satisfy the two
            // distinct presses. Once browsing, key repeat is deliberately fast.
            if isRepeat { return .consumed }
            guard armedDirection == direction else {
                armedDirection = direction
                return .consumed
            }
        }
        if latestDraft == nil {
            latestDraft = current
            history = entries
        }
        armedDirection = nil
        isContinuous = true
        switch direction {
        case .older:
            let next = (index ?? -1) + 1
            guard next < history.count else { return .consumed }
            index = next
            let text = history[next]
            return .restore(.init(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        case .newer:
            guard let index else { return .unhandled }
            if index == 0 {
                self.index = nil
                return latestDraft.map(QuickInputHistoryNavigationResult.restore) ?? .consumed
            }
            self.index = index - 1
            let text = history[index - 1]
            return .restore(.init(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        }
    }
}
