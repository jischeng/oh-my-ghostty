import Cocoa
import ApplicationServices
import CoreGraphics
import Carbon
import OSLog
import GhosttyKit

// Manages the event tap to monitor global events, currently only used for
// global keybindings.
class GlobalEventTap {
    static let shared = GlobalEventTap()
    static let stateDidChangeNotification = Notification.Name("OMGGlobalEventTapStateDidChange")
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: GlobalEventTap.self)
    )

    // The event tap used for global event listening. This is non-nil if it is
    // created.
    fileprivate var eventTap: CFMachPort?

    // Observers active only while waiting for Accessibility permission to be granted.
    private var activationObserver: NSObjectProtocol?
    private var workspaceDeactivationObserver: NSObjectProtocol?

    var isWaitingForPermission: Bool {
        activationObserver != nil || workspaceDeactivationObserver != nil
    }

    // Whether the active Ghostty configuration defines one or more global keybindings.
    private(set) var hasConfiguredGlobalKeybinds = false

    var isTapEnabled: Bool {
        eventTap != nil
    }

    var needsAccessibilityPermission: Bool {
        hasConfiguredGlobalKeybinds && !Self.isAccessibilityTrusted()
    }

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission(
        prompt: Bool = true,
        openSystemSettings: Bool = true
    ) -> Bool {
        let trusted: Bool
        if OMGApplicationEnvironment.isRunningTests {
            trusted = AXIsProcessTrusted()
        } else {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
            ] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted && openSystemSettings {
                NSWorkspace.shared.open(accessibilitySettingsURL)
            }
        }
        if trusted && shared.hasConfiguredGlobalKeybinds {
            shared.enable()
        } else {
            shared.notifyStateDidChange()
        }
        return trusted
    }

    func noteConfiguredGlobalKeybinds(_ configured: Bool) {
        guard hasConfiguredGlobalKeybinds != configured else { return }
        hasConfiguredGlobalKeybinds = configured
        notifyStateDidChange()
    }

    private func notifyStateDidChange() {
        NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
    }

    // Private init so it can't be constructed outside of our singleton
    private init() {}

    deinit {
        disable()
    }

    // Enable the global event tap. This is safe to call if it is already enabled or
    // waiting for Accessibility permission.
    func enable(isTrustedProvider: @escaping () -> Bool = GlobalEventTap.isAccessibilityTrusted) {
        let changed = !hasConfiguredGlobalKeybinds
        hasConfiguredGlobalKeybinds = true
        guard eventTap == nil else {
            if changed { notifyStateDidChange() }
            return
        }

        // Creating a CGEventTap without Accessibility permission leaks a Mach port
        // inside CoreGraphics on each failed attempt. Request permission once and
        // re-check on app/workspace activation transitions instead of a 1 Hz timer.
        if isTrustedProvider() {
            removePendingPermissionObservers()
            _ = tryEnable()
            notifyStateDidChange()
            return
        }

        guard !isWaitingForPermission else {
            if changed { notifyStateDidChange() }
            return
        }

        Self.logger.warning(
            "Global keybindings are configured, but Accessibility permission is missing; open OMG Doctor to grant access."
        )
        if !OMGApplicationEnvironment.isRunningTests {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        let checkTrust: () -> Void = { [weak self] in
            guard let self, isTrustedProvider() else { return }
            // Remove observers before attempting creation. If creation fails for a
            // reason other than permissions, we must not retry it indefinitely.
            self.removePendingPermissionObservers()
            _ = self.tryEnable()
            self.notifyStateDidChange()
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            checkTrust()
        }
        workspaceDeactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            checkTrust()
        }
        notifyStateDidChange()
    }

    private func removePendingPermissionObservers() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let workspaceDeactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceDeactivationObserver)
            self.workspaceDeactivationObserver = nil
        }
    }

    // Disable the global event tap. This is safe to call if it is already disabled.
    func disable() {
        let hadState = hasConfiguredGlobalKeybinds || isWaitingForPermission || eventTap != nil
        hasConfiguredGlobalKeybinds = false

        removePendingPermissionObservers()

        // Stop our event tap
        if let eventTap {
            Self.logger.debug("invalidating event tap mach port")
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if hadState {
            notifyStateDidChange()
        }
    }

    // Try to enable the global event type, returns false if it fails.
    private func tryEnable() -> Bool {
        // The events we care about
        let eventMask = [
            CGEventType.keyDown
        ].reduce(CGEventMask(0), { $0 | (1 << $1.rawValue)})

        // Try to create it
        guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: cgEventFlagsChangedHandler(proxy:type:cgEvent:userInfo:),
                userInfo: nil
        ) else {
            Self.logger.warning("creating global event tap failed despite Accessibility permission")
            return false
        }

        // Store our event tap
        self.eventTap = eventTap

        removePendingPermissionObservers()

        // Attach our event tap to the main run loop. Note if you don't do this then
        // the event tap will block every
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            CFMachPortCreateRunLoopSource(nil, eventTap, 0),
            .commonModes
        )

        Self.logger.info("global event tap enabled for global keybinds")
        return true
    }
}

private func cgEventFlagsChangedHandler(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let result = Unmanaged.passUnretained(cgEvent)

    // macOS disables the event tap if the callback is too slow or for other
    // internal reasons. When that happens it sends this event type. We need
    // to re-enable the tap or it stays dead forever.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        GlobalEventTap.logger.warning("global event tap was disabled by the system, re-enabling")
        if let machPort = GlobalEventTap.shared.eventTap {
            CGEvent.tapEnable(tap: machPort, enable: true)
        }
        return result
    }

    // We only care about keydown events
    guard type == .keyDown else { return result }

    // If our app is currently active then we don't process the key event.
    // This is because we already have a local event handler in AppDelegate
    // that processes all local events.
    guard !NSApp.isActive else { return result }

    // We need an app delegate to get the Ghostty app instance
    guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return result }
    guard let ghostty = appDelegate.ghostty.app else { return result }

    // We need an NSEvent for our logic below
    guard let event: NSEvent = .init(cgEvent: cgEvent) else { return result }

    // Build our event input and call ghostty
    let key_ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
    if ghostty_app_key(ghostty, key_ev) {
        GlobalEventTap.logger.info("global key event handled event=\(event, privacy: .public)")
        return nil
    }

    return result
}
