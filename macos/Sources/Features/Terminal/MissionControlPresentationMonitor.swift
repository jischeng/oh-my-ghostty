import AppKit
import Combine
import CoreGraphics
import os

/// Tracks whether macOS Mission Control / Spaces Exposé is actively presenting
/// so non-opaque terminal windows can temporarily switch to solid renderer-matched
/// theme backing and pause decorative layer animations.
///
/// Why this is needed:
/// On macOS 26/27 (`SkyLight`), behind-window blur (`CABackdropLayer` via
/// `NSVisualEffectView(.behindWindow)`, `TerminalGlassView`, or `CGS` window blur)
/// loses live wallpaper sampling during Mission Control on displays that have
/// Fullscreen Spaces in the top Spaces bar, washing translucent windows out to
/// milky gray and ping-ponging ("flickering") whenever any layer inside the window
/// commits a frame. Opaque windows have zero Exposé backdrop dependency.
///
/// Overhead contract:
/// - When all OMG windows are opaque, occluded, miniaturized, in native fullscreen,
///   or closed (or displays are asleep), NO timers and NO event monitors are active
///   (`isMonitoring == false`, zero wakeups).
/// - While at least one visible window uses behind-window blur/glass, monitoring
///   combines immediate event-driven probes (space/occlusion notifications, swipe/key
///   gestures, hot-corner proximity) with a low-duty coalesced watchdog timer
///   (`250ms` + `60ms` leeway, `< 0.05%` CPU) so programmatic triggers such as
///   `Mission Control.app` are caught as reliably as trackpad gestures.
@MainActor
final class MissionControlPresentationMonitor: ObservableObject {
    static let shared = MissionControlPresentationMonitor()

    static let didChangeNotification = Notification.Name(
        "com.jischeng.omg.missionControlPresentationDidChange"
    )

    struct WindowSnapshot: Equatable {
        let ownerPID: pid_t
        let ownerName: String
        let layer: Int
        let bounds: CGRect
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jischeng.omg",
        category: "mission-control"
    )

    @Published private(set) var isMissionControlActive: Bool = false
    private(set) var isMonitoring: Bool = false
    private(set) var probeCount: Int = 0

    /// Optional testing override; when non-nil, forces `isMissionControlActive`.
    var overrideForTesting: Bool? {
        didSet {
            if let overrideForTesting {
                applyActiveState(overrideForTesting, reason: "testing-override")
            } else {
                probeNow(reason: "testing-override-cleared")
            }
        }
    }

    private let eligibleWindows = NSHashTable<NSWindow>.weakObjects()
    private var observedWindowTokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var timer: DispatchSourceTimer?
    private var timerIntervalMilliseconds: Int = 0
    private var burstWorkItems: [DispatchWorkItem] = []
    private var displaysAwake: Bool = true
    private var bundleIDCache: [pid_t: String] = [:]

    private let snapshotProvider: () -> [WindowSnapshot]
    private let screenSizesProvider: () -> [CGSize]
    private let bundleIdentifierProvider: (pid_t) -> String?
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let enableEventMonitors: Bool

    init(
        snapshotProvider: @escaping () -> [WindowSnapshot] = MissionControlPresentationMonitor.liveOnScreenSnapshots,
        screenSizesProvider: @escaping () -> [CGSize] = MissionControlPresentationMonitor.liveScreenSizes,
        bundleIdentifierProvider: @escaping (pid_t) -> String? = { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        enableEventMonitors: Bool = true
    ) {
        self.snapshotProvider = snapshotProvider
        self.screenSizesProvider = screenSizesProvider
        self.bundleIdentifierProvider = bundleIdentifierProvider
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.enableEventMonitors = enableEventMonitors
        installWorkspaceObservers()
    }

    deinit {
        for token in workspaceTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        for tokens in observedWindowTokens.values {
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        timer?.cancel()
    }

    // MARK: - Window Eligibility Registration

    /// Registers or unregisters `window` according to whether its configuration
    /// uses behind-window blur or liquid glass when in normal desktop mode.
    ///
    /// Callers must pass the configuration-level desire for behind-window blur
    /// (excluding `isMissionControlActive` itself) so the window stays registered
    /// while Mission Control temporarily forces it opaque.
    func updateWindowEligibility(_ window: NSWindow, wantsBehindWindowBlur: Bool) {
        if wantsBehindWindowBlur {
            if !eligibleWindows.contains(window) {
                eligibleWindows.add(window)
                observeWindowLifecycle(window)
            }
        } else {
            removeWindow(window)
        }
        reevaluateMonitoring()
    }

    func unregisterWindow(_ window: NSWindow) {
        removeWindow(window)
        reevaluateMonitoring()
    }

    private func removeWindow(_ window: NSWindow) {
        eligibleWindows.remove(window)
        let key = ObjectIdentifier(window)
        if let tokens = observedWindowTokens.removeValue(forKey: key) {
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
        }
    }

    private func observeWindowLifecycle(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard observedWindowTokens[key] == nil else { return }

        var tokens: [NSObjectProtocol] = []
        let stateNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in stateNames {
            tokens.append(
                notificationCenter.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handleWindowLifecycleEvent()
                    }
                }
            )
        }
        tokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let closing = notification.object as? NSWindow else { return }
                    self.unregisterWindow(closing)
                }
            }
        )
        observedWindowTokens[key] = tokens
    }

    private func installWorkspaceObservers() {
        workspaceTokens.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reevaluateMonitoring()
                    if self.isMonitoring {
                        self.scheduleBurstProbes(reason: "active-space-changed")
                    }
                }
            }
        )
        for sleepName in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspaceTokens.append(
                workspaceNotificationCenter.addObserver(
                    forName: sleepName,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.displaysAwake = false
                        self?.reevaluateMonitoring()
                    }
                }
            )
        }
        for wakeName in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspaceTokens.append(
                workspaceNotificationCenter.addObserver(
                    forName: wakeName,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.displaysAwake = true
                        self?.reevaluateMonitoring()
                    }
                }
            )
        }
    }

    private func handleWindowLifecycleEvent() {
        pruneDeallocatedWindowTokens()
        reevaluateMonitoring()
        if isMonitoring {
            scheduleBurstProbes(reason: "window-lifecycle")
        }
    }

    private func pruneDeallocatedWindowTokens() {
        let liveKeys = Set(eligibleWindows.allObjects.map(ObjectIdentifier.init))
        for (key, tokens) in observedWindowTokens where !liveKeys.contains(key) {
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
            observedWindowTokens.removeValue(forKey: key)
        }
    }

    // MARK: - Monitoring State Machine

    var hasVisibleEligibleBlurredWindow: Bool {
        for window in eligibleWindows.allObjects {
            guard window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  window.occlusionState.contains(.visible) else {
                continue
            }
            return true
        }
        return false
    }

    func reevaluateMonitoring() {
        pruneDeallocatedWindowTokens()
        let hasAnyRegisteredWindow = !eligibleWindows.allObjects.isEmpty
        if !hasAnyRegisteredWindow && isMissionControlActive && overrideForTesting == nil {
            applyActiveState(false, reason: "no-eligible-windows")
        }

        // Keep monitoring while Mission Control is currently active so an occlusion
        // change mid-Exposé never strands `isMissionControlActive == true`.
        let shouldMonitor = displaysAwake && (
            hasVisibleEligibleBlurredWindow || (isMissionControlActive && hasAnyRegisteredWindow)
        )

        if shouldMonitor {
            startMonitoringIfNeeded()
        } else {
            stopMonitoring()
            if isMissionControlActive && overrideForTesting == nil {
                applyActiveState(false, reason: "monitoring-stopped")
            }
        }
    }

    private func startMonitoringIfNeeded() {
        let desiredInterval = isMissionControlActive ? 100 : 250
        let wasMonitoring = isMonitoring
        isMonitoring = true

        if enableEventMonitors {
            installEventMonitorsIfNeeded()
        }
        if timer == nil || timerIntervalMilliseconds != desiredInterval {
            armTimer(intervalMilliseconds: desiredInterval)
        }
        if !wasMonitoring {
            Self.logger.info("monitoring_enabled=true interval_ms=\(desiredInterval, privacy: .public)")
            probeNow(reason: "monitoring-started")
        }
    }

    private func stopMonitoring() {
        guard isMonitoring || timer != nil || globalEventMonitor != nil || localEventMonitor != nil else {
            return
        }
        isMonitoring = false
        cancelBurstProbes()
        timer?.cancel()
        timer = nil
        timerIntervalMilliseconds = 0
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        Self.logger.info("monitoring_enabled=false")
    }

    static func logWindowSync(isOpaque: Bool, hasBackdropBlur: Bool, hasGlass: Bool) {
        logger.info(
            "window_sync active=\(shared.isMissionControlActive, privacy: .public) is_opaque=\(isOpaque, privacy: .public) backdrop_blur=\(hasBackdropBlur, privacy: .public) glass=\(hasGlass, privacy: .public)"
        )
    }

    private func armTimer(intervalMilliseconds: Int) {
        timer?.cancel()
        timerIntervalMilliseconds = intervalMilliseconds
        let source = DispatchSource.makeTimerSource(queue: .main)
        let leewayMilliseconds = intervalMilliseconds <= 100 ? 20 : 60
        source.schedule(
            deadline: .now() + .milliseconds(intervalMilliseconds),
            repeating: .milliseconds(intervalMilliseconds),
            leeway: .milliseconds(leewayMilliseconds)
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.probeNow(reason: "watchdog")
            }
        }
        timer = source
        source.resume()
    }

    private func installEventMonitorsIfNeeded() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .systemDefined, .gesture, .swipe, .mouseMoved]
        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                let shouldProbe = Self.shouldTriggerImmediateProbe(for: event)
                guard shouldProbe else { return }
                Task { @MainActor [weak self] in
                    self?.scheduleBurstProbes(reason: "global-input")
                }
            }
        }
        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                if Self.shouldTriggerImmediateProbe(for: event) {
                    self?.scheduleBurstProbes(reason: "local-input")
                }
                return event
            }
        }
    }

    nonisolated private static func shouldTriggerImmediateProbe(for event: NSEvent) -> Bool {
        switch event.type {
        case .gesture, .swipe, .systemDefined:
            return true
        case .keyDown:
            // F3 / Mission Control keycodes (160, 131) or Control+Arrow shortcuts.
            let code = event.keyCode
            if code == 160 || code == 131 || code == 99 { return true }
            return event.modifierFlags.contains(.control)
        case .mouseMoved:
            // Only probe mouse movement near screen corners (Hot Corners).
            let loc = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                let f = screen.frame
                let nearX = abs(loc.x - f.minX) <= 6 || abs(loc.x - f.maxX) <= 6
                let nearY = abs(loc.y - f.minY) <= 6 || abs(loc.y - f.maxY) <= 6
                if nearX && nearY { return true }
            }
            return false
        default:
            return false
        }
    }

    private func scheduleBurstProbes(reason: String) {
        guard isMonitoring else { return }
        cancelBurstProbes()
        for delayMs in [16, 110] {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.probeNow(reason: reason)
                }
            }
            burstWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
        }
    }

    private func cancelBurstProbes() {
        for item in burstWorkItems {
            item.cancel()
        }
        burstWorkItems.removeAll()
    }

    // MARK: - Probing & Classification

    func probeNow(reason: String = "manual") {
        if let overrideForTesting {
            applyActiveState(overrideForTesting, reason: reason)
            return
        }
        probeCount += 1
        let snapshots = snapshotProvider()
        let screens = screenSizesProvider()
        let active = Self.isMissionControlPresented(
            windows: snapshots,
            screenSizes: screens,
            bundleIdentifierForPID: { [weak self] pid in
                self?.resolvedBundleIdentifier(for: pid)
            }
        )
        applyActiveState(active, reason: reason)
    }

    private func resolvedBundleIdentifier(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        if let cached = bundleIDCache[pid] {
            return cached.isEmpty ? nil : cached
        }
        let resolved = bundleIdentifierProvider(pid)
        if bundleIDCache.count > 256 {
            bundleIDCache.removeAll(keepingCapacity: true)
        }
        bundleIDCache[pid] = resolved ?? ""
        return resolved
    }

    private func applyActiveState(_ next: Bool, reason: String) {
        guard isMissionControlActive != next else { return }
        isMissionControlActive = next
        Self.logger.info(
            "mission_control_active=\(next, privacy: .public) reason=\(reason, privacy: .public)"
        )
        notificationCenter.post(name: Self.didChangeNotification, object: self)
        // Adjust timer cadence (100ms while active for crisp exit, 250ms on desktop,
        // or stop completely if Mission Control exited onto an occluded Space).
        reevaluateMonitoring()
    }

    /// Pure locale-independent Mission Control / Exposé detector.
    ///
    /// Matches:
    /// 1. `com.apple.dock` (`Dock` / `程序坞` / etc.) onscreen full-screen Exposé
    ///    backdrop canvas at `(dockLevel - 2)..<dockLevel` (`18...19`), OR `>= 2`
    ///    overlapping full-screen `com.apple.dock` windows at `dockLevel...(dockLevel + 3)`
    ///    on the same display (since macOS 26/27 keeps a single permanent full-screen
    ///    `layer == dockLevel` Dock root container per display on normal desktop and
    ///    spawns an additional full-screen Exposé layer on top during Mission Control).
    /// 2. `com.apple.WindowManager` onscreen Mission Control top Spaces strip at
    ///    `layer` `14...16` spanning `>= 85%` of a screen's width along `y ~= 0`.
    ///
    /// Rejects:
    /// - Menu-bar Control Center (`com.apple.controlcenter`), Notification Center,
    ///   Spotlight, macOS 26/27 single normal-desktop `layer == 20` Dock container,
    ///   Stage Manager side strip, and desktop wallpaper.
    static func isMissionControlPresented(
        windows: [WindowSnapshot],
        screenSizes: [CGSize],
        bundleIdentifierForPID: (pid_t) -> String?
    ) -> Bool {
        let validScreens = screenSizes.filter { $0.width > 100 && $0.height > 100 }
        guard !validScreens.isEmpty else { return false }

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let exposeBackdropRange = (dockLevel - 2)..<dockLevel
        let dockOverlayRange = dockLevel...(dockLevel + 3)
        var fullScreenDockOverlayRects: [CGRect] = []

        for win in windows {
            guard win.bounds.width > 0, win.bounds.height > 0 else { continue }
            guard win.layer >= 14 && win.layer <= max(25, dockLevel + 3) else { continue }

            let bundleID = bundleIdentifierForPID(win.ownerPID)

            // 1. Dock Exposé full-screen backdrop/overlay (locale-independent via bundleIdentifier).
            if bundleID == "com.apple.dock" {
                let coversScreen = validScreens.contains { screen in
                    win.bounds.width >= screen.width * 0.85 &&
                        win.bounds.height >= screen.height * 0.85
                }
                if coversScreen {
                    if exposeBackdropRange.contains(win.layer) {
                        return true
                    }
                    if dockOverlayRange.contains(win.layer) {
                        let overlapsExisting = fullScreenDockOverlayRects.contains { prev in
                            let overlap = prev.intersection(win.bounds)
                            guard !overlap.isNull else { return false }
                            return overlap.width >= min(prev.width, win.bounds.width) * 0.8 &&
                                overlap.height >= min(prev.height, win.bounds.height) * 0.8
                        }
                        if overlapsExisting {
                            return true
                        }
                        fullScreenDockOverlayRects.append(win.bounds)
                    }
                }
            }

            // 2. macOS 26/27 WindowManager top Spaces bar (`layer` 14..16, full width, top edge).
            let isWindowManager = bundleID == "com.apple.WindowManager" ||
                (bundleID == nil && win.ownerName == "WindowManager")
            if isWindowManager && (14...16).contains(win.layer) {
                let spansTopStrip = abs(win.bounds.minY) <= 8 &&
                    win.bounds.height >= 70 &&
                    win.bounds.height <= 380 &&
                    validScreens.contains { screen in
                        win.bounds.width >= screen.width * 0.85 &&
                            win.bounds.height < screen.height * 0.6
                    }
                if spansTopStrip {
                    return true
                }
            }
        }

        return false
    }

    nonisolated private static func liveOnScreenSnapshots() -> [WindowSnapshot] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [WindowSnapshot] = []
        result.reserveCapacity(info.count)
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  layer >= 14 && layer <= 30 else {
                continue
            }
            let pid = (entry[kCGWindowOwnerPID as String] as? Int32) ?? 0
            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            var rect = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(boundsDict, &rect)
            }
            result.append(
                WindowSnapshot(
                    ownerPID: pid,
                    ownerName: owner,
                    layer: layer,
                    bounds: rect
                )
            )
        }
        return result
    }

    private static func liveScreenSizes() -> [CGSize] {
        let sizes = NSScreen.screens.map(\.frame.size)
        return sizes.isEmpty ? [CGSize(width: 1512, height: 982)] : sizes
    }
}

// MARK: - NSWindow Layer Auto-Flatten Guard

extension NSWindow {
    /// Selector-guarded wrapper around AppKit's `_setShouldAutoFlattenLayerTree:`.
    /// Disabling layer-tree auto-flattening on non-opaque blurred windows prevents
    /// AppKit from collapsing live `CABackdropLayer` subtrees into a static bitmap
    /// between CoreAnimation commits.
    func setAutoFlattenLayerTreeEnabled(_ enabled: Bool) {
        let selector = NSSelectorFromString("_setShouldAutoFlattenLayerTree:")
        guard responds(to: selector),
              let imp = method(for: selector) else {
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let function = unsafeBitCast(imp, to: Setter.self)
        function(self, selector, ObjCBool(enabled))
    }
}
