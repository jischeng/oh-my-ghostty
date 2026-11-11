import AppKit
import Foundation
import UserNotifications

enum AgentActivityNotification {
    enum Kind: Equatable {
        case completed
        case attention
    }

    struct SoundPlan: Equatable {
        let requestBannerSound: Bool
        let customTone: AgentNotificationSoundTone?
    }

    @MainActor
    private static var activeSound: NSSound?

    static func kind(previous: TabActivity?, next: TabActivity?,
                     completionEnabled: Bool, attentionEnabled: Bool) -> Kind? {
        guard let previous, let next, previous.source != next.source || previous.state != next.state else { return nil }
        switch next.state {
        case .done: return completionEnabled ? .completed : nil
        case .needsAttention: return attentionEnabled ? .attention : nil
        default: return nil
        }
    }

    static func soundPlan(enabled: Bool, tone: AgentNotificationSoundTone) -> SoundPlan {
        guard enabled else { return .init(requestBannerSound: false, customTone: nil) }
        if tone == .systemDefault {
            return .init(requestBannerSound: true, customTone: nil)
        }
        return .init(requestBannerSound: false, customTone: tone)
    }

    @MainActor
    static func makeSystemSound(for tone: AgentNotificationSoundTone) -> NSSound? {
        guard let path = tone.systemSoundPath else { return nil }
        if FileManager.default.fileExists(atPath: path),
           let sound = NSSound(contentsOfFile: path, byReference: true) {
            return sound
        }
        return NSSound(named: NSSound.Name(tone.rawValue))
    }

    @MainActor
    static func previewSound(_ tone: AgentNotificationSoundTone) {
        guard !OMGApplicationEnvironment.isRunningTests else { return }
        activeSound?.stop()
        activeSound = nil
        if tone == .systemDefault {
            NSSound.beep()
            return
        }
        guard let sound = makeSystemSound(for: tone) else {
            NSSound.beep()
            return
        }
        activeSound = sound
        _ = sound.play()
    }

    @MainActor
    static func deliver(previous: TabActivity?, next: TabActivity?, surface: Ghostty.SurfaceView) {
        guard !OMGApplicationEnvironment.isRunningTests else { return }
        let settings = OhMyGhosttySettings.shared
        guard let kind = kind(previous: previous, next: next, completionEnabled: settings.notifyTaskComplete,
                              attentionEnabled: settings.notifyAttention), let next else { return }
        let strings = SettingsStrings(language: settings.language)
        let action = kind == .completed ? strings.notifyTaskCompleteLabel : strings.notifyAttentionLabel
        let title = "\(next.label ?? next.source) · \(action)"
        let body = next.message ?? ""
        let plan = soundPlan(enabled: settings.notificationSound, tone: settings.notificationSoundTone)
        Task { @MainActor [weak surface] in
            do {
                let center = UNUserNotificationCenter.current()
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted, let surface else { return }
                surface.showUserNotification(title: title, body: body, playSound: plan.requestBannerSound)
                if let customTone = plan.customTone {
                    let notifSettings = await center.notificationSettings()
                    if notifSettings.soundSetting == .enabled {
                        previewSound(customTone)
                    }
                }
            } catch {
                Ghostty.logger.error("Agent notification authorization failed")
            }
        }
    }
}
