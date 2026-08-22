import Foundation

@MainActor
final class InspectorPresentationStore {
    struct Snapshot: Codable, Equatable {
        var isVisible = false
        var width = Double(RightInspectorMetrics.defaultWidth)
        var selectedPaneID: String?
    }

    static let shared = InspectorPresentationStore()
    static let defaultsKey = "OhMyGhosttyInspectorPresentation"

    private let defaults: UserDefaults
    private(set) var snapshot: Snapshot

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = Self.clamped(decoded)
        } else {
            snapshot = .init()
        }
    }

    func replace(with snapshot: Snapshot) {
        self.snapshot = Self.clamped(snapshot)
        save()
    }

    func setVisible(_ visible: Bool) {
        guard snapshot.isVisible != visible else { return }
        snapshot.isVisible = visible
        save()
    }

    func setWidth(_ width: CGFloat) {
        let clamped = min(
            max(width, RightInspectorMetrics.minimumWidth),
            RightInspectorMetrics.maximumWidth
        )
        guard snapshot.width != Double(clamped) else { return }
        snapshot.width = Double(clamped)
        save()
    }

    func selectPane(_ paneID: String?) {
        guard snapshot.selectedPaneID != paneID else { return }
        snapshot.selectedPaneID = paneID
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func clamped(_ snapshot: Snapshot) -> Snapshot {
        var result = snapshot
        result.width = min(
            max(result.width, Double(RightInspectorMetrics.minimumWidth)),
            Double(RightInspectorMetrics.maximumWidth)
        )
        return result
    }
}
