import Combine

/// Shared chrome within a workspace. Drafts, targets and queues remain model-owned.
@MainActor
final class QuickInputGlobalPresentation: ObservableObject {
    static let shared = QuickInputGlobalPresentation()
    @Published private(set) var isPresented = false
    @Published private(set) var isPinned = false
    @Published private(set) var height = 252.0
    var onChange: (() -> Void)?

    func setHeight(_ value: Double) {
        let value = min(max(value, 140), 480)
        guard value != height else { return }
        height = value
        onChange?()
    }

    func setPresented(_ value: Bool) {
        guard value != isPresented else { return }
        isPresented = value
        onChange?()
    }

    func togglePinned() {
        isPinned.toggle()
        onChange?()
    }
}
