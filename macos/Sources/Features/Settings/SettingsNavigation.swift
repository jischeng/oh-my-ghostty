import AppKit

extension Notification.Name {
    static let omgSelectSettingsTab = Notification.Name("omgSelectSettingsTab")
}

@MainActor
enum SettingsNavigation {
    static func open(_ tab: OhMyGhosttySettingsTab) {
        (NSApp.delegate as? AppDelegate)?.openSettings(nil)
        // Allow a newly created hosting view to install its subscription first.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .omgSelectSettingsTab, object: tab)
        }
    }
}
