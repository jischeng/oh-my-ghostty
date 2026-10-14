import Combine
import Foundation

@MainActor
final class QuickInputHistoryPresentation: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published var isSearching = false
    @Published private(set) var selectedID: UUID?
    @Published private(set) var focusRequestID = 0
    @Published private(set) var keyboardSelectionRevision = 0

    func open(entries: [QuickInputHistoryEntry]) {
        reconcile(entries: entries)
        isPresented = true
        requestFocus()
    }

    func close() {
        // Search text and mode survive keyboard toggling and outside dismissal.
        isPresented = false
    }

    func requestFocus() { focusRequestID &+= 1 }

    func beginSearch(clearQuery: Bool = false) {
        if clearQuery { query = "" }
        isSearching = true
        requestFocus()
    }

    func endSearch() {
        isSearching = false
        requestFocus()
    }

    /// Returns true when Escape closed the popup, false when it only left search.
    @discardableResult
    func escape() -> Bool {
        if isSearching {
            endSearch()
            return false
        }
        close()
        return true
    }

    func select(_ id: UUID) { selectedID = id }

    func hover(_ id: UUID) {
        guard selectedID != id else { return }
        selectedID = id
    }

    func reconcile(entries: [QuickInputHistoryEntry]) {
        if !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id }
    }

    func moveSelection(by delta: Int, entries: [QuickInputHistoryEntry]) {
        defer { keyboardSelectionRevision &+= 1 }
        guard !entries.isEmpty else { selectedID = nil; return }
        guard let index = entries.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = entries.first?.id
            return
        }
        selectedID = entries[min(max(index + delta, 0), entries.count - 1)].id
    }
}
