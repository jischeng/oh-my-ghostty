import AppKit

extension Notification.Name {
    static let omgSelectSettingsTab = Notification.Name("omgSelectSettingsTab")
    static let omgSelectAgentIntegrationTarget = Notification.Name("omgSelectAgentIntegrationTarget")
}

@MainActor
enum SettingsNavigation {
    // Retained until consumed so a newly created settings view cannot miss navigation.
    private(set) static var pendingAgentTarget: String?

    static func openAgentIntegration(target: String) {
        pendingAgentTarget = target
        open(.agents)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .omgSelectAgentIntegrationTarget, object: nil)
        }
    }

    static func consumeAgentTarget() -> String? {
        defer { pendingAgentTarget = nil }
        return pendingAgentTarget
    }

    static func open(_ tab: OhMyGhosttySettingsTab) {
        (NSApp.delegate as? AppDelegate)?.openSettings(nil)
        // Allow a newly created hosting view to install its subscription first.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .omgSelectSettingsTab, object: tab)
        }
    }
}
