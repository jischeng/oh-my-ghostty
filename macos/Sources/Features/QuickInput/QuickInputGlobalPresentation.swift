import Combine

/// Process-wide chrome state. Drafts, targets and queues remain model-owned.
@MainActor
final class QuickInputGlobalPresentation: ObservableObject {
    static let shared = QuickInputGlobalPresentation()
    @Published private(set) var isPresented = false
    @Published private(set) var isPinned = false

    func setPresented(_ value: Bool) {
        guard value != isPresented else { return }
        isPresented = value
    }

    func togglePinned() { isPinned.toggle() }
}
