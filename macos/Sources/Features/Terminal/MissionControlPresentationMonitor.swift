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
///   combines immediate event-driven probes (space/occlusion notifications and
///   in-app swipe / Mission Control / Control+Arrow shortcuts) with a low-duty
///   coalesced watchdog timer (`120ms` + `20ms` leeway, `< 0.03%` CPU) so Hot
///   Corners, Dock gestures, and `Mission Control.app` are caught with zero
///   global pointer or scroll event-tap IPC. Off-Space and occluded windows
///   pre-emptively switch to opaque theme backing with zero timers active.
@MainActor
final class MissionControlPresentationMonitor: ObservableObject {
    static let shared = MissionControlPresentationMonitor()

    static let didChangeNotification = Notification.Name(
        "com.jischeng.omg.missionControlPresentationDidChange"
    )

    static let windowSpaceOrStateDidSettleNotification = Notification.Name(
        "com.jischeng.omg.missionControlWindowSpaceDidSettle"
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
    private var eligibleOwnersByWindow: [ObjectIdentifier: Set<AnyHashable>] = [:]
    private var observedWindowTokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var localEventMonitor: Any?
    private var timer: DispatchSourceTimer?
    private var timerIntervalMilliseconds: Int = 0
    private var burstWorkItems: [DispatchWorkItem] = []
    private var spaceSettleWorkItems: [DispatchWorkItem] = []
    private var displaysAwake: Bool = true
    private var bundleIDCache: [pid_t: String] = [:]

    private let snapshotProvider: () -> [WindowSnapshot]
    private let screenBoundsProvider: () -> [CGRect]
    private let bundleIdentifierProvider: (pid_t) -> String?
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let enableEventMonitors: Bool

    init(
        snapshotProvider: @escaping () -> [WindowSnapshot] = MissionControlPresentationMonitor.liveOnScreenSnapshots,
        screenBoundsProvider: @escaping () -> [CGRect] = MissionControlPresentationMonitor.liveQuartzScreenBounds,
        bundleIdentifierProvider: @escaping (pid_t) -> String? = { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        enableEventMonitors: Bool = true
    ) {
        self.snapshotProvider = snapshotProvider
        self.screenBoundsProvider = screenBoundsProvider
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
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        for item in spaceSettleWorkItems {
            item.cancel()
        }
        timer?.cancel()
    }

    // MARK: - Window Eligibility Registration

    /// Registers or unregisters `window` according to whether `owner` desires
    /// non-opaque / behind-window blur or liquid-glass backing in normal desktop mode.
    ///
    /// Callers must pass the configuration-level desire for non-opaque backing
    /// (excluding `isMissionControlActive` itself) so the window stays registered
    /// while Mission Control temporarily forces it opaque.
    func updateWindowEligibility(
        _ window: NSWindow,
        wantsBehindWindowBlur: Bool,
        owner: AnyHashable = "window"
    ) {
        let key = ObjectIdentifier(window)
        if wantsBehindWindowBlur {
            var owners = eligibleOwnersByWindow[key] ?? []
            owners.insert(owner)
            eligibleOwnersByWindow[key] = owners
            if !eligibleWindows.contains(window) {
                eligibleWindows.add(window)
                observeWindowLifecycle(window)
            }
        } else if var owners = eligibleOwnersByWindow[key] {
            owners.remove(owner)
            if owners.isEmpty {
                removeWindow(window)
            } else {
                eligibleOwnersByWindow[key] = owners
            }
        } else {
            removeWindow(window)
        }
        reevaluateMonitoring()
    }

    func unregisterWindow(_ window: NSWindow, owner: AnyHashable? = nil) {
        if let owner {
            updateWindowEligibility(window, wantsBehindWindowBlur: false, owner: owner)
            return
        }
        removeWindow(window)
        reevaluateMonitoring()
    }

    private func removeWindow(_ window: NSWindow) {
        eligibleWindows.remove(window)
        let key = ObjectIdentifier(window)
        eligibleOwnersByWindow.removeValue(forKey: key)
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
                    let wasMonitoring = self.isMonitoring
                    self.reevaluateMonitoring()
                    if self.isMonitoring {
                        if wasMonitoring {
                            self.probeNow(reason: "active-space-changed")
                        }
                        self.scheduleBurstProbes(reason: "active-space-changed")
                    }
                    if !self.eligibleWindows.allObjects.isEmpty {
                        self.scheduleSpaceSettleReconciliation()
                    }
                    self.objectWillChange.send()
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
        let wasMonitoring = isMonitoring
        reevaluateMonitoring()
        if isMonitoring {
            if wasMonitoring {
                probeNow(reason: "window-lifecycle")
            }
            scheduleBurstProbes(reason: "window-lifecycle")
        }
        if !eligibleWindows.allObjects.isEmpty {
            objectWillChange.send()
        }
    }

    private func pruneDeallocatedWindowTokens() {
        let liveKeys = Set(eligibleWindows.allObjects.map(ObjectIdentifier.init))
        for key in Array(eligibleOwnersByWindow.keys) where !liveKeys.contains(key) {
            eligibleOwnersByWindow.removeValue(forKey: key)
        }
        for (key, tokens) in observedWindowTokens where !liveKeys.contains(key) {
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
            observedWindowTokens.removeValue(forKey: key)
        }
    }

    private func scheduleSpaceSettleReconciliation() {
        cancelSpaceSettleReconciliation()
        for delayMs in [120, 320] {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasMonitoring = self.isMonitoring
                    self.reevaluateMonitoring()
                    if self.isMonitoring && wasMonitoring {
                        self.probeNow(reason: "space-settled")
                    }
                    self.objectWillChange.send()
                    self.notificationCenter.post(
                        name: Self.windowSpaceOrStateDidSettleNotification,
                        object: self
                    )
                }
            }
            spaceSettleWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
        }
    }

    private func cancelSpaceSettleReconciliation() {
        for item in spaceSettleWorkItems {
            item.cancel()
        }
        spaceSettleWorkItems.removeAll()
    }

    // MARK: - Monitoring State Machine

    /// Returns `true` when non-opaque / behind-window blur/glass should be replaced by solid
    /// renderer-matched opaque theme backing:
    /// - Whenever Mission Control / Exposé is actively presenting (`isMissionControlActive`).
    /// - Whenever `window` is miniaturized, showing native Tab Overview (`isOverviewVisible`),
    ///   or off the active Space (`!window.isOnActiveSpace`), unless an explicit testing
    ///   override is active. Off-Space windows appear inside Mission Control's top Spaces bar
    ///   thumbnails without receiving `.visible` occlusion updates; keeping them pre-opaque
    ///   eliminates thumbnail washout and flicker while requiring zero timers off-Space.
    func shouldSuppressBehindWindowBlur(for window: NSWindow?) -> Bool {
        if isMissionControlActive {
            return true
        }
        guard overrideForTesting == nil, let window else {
            return false
        }
        if window.isMiniaturized {
            return true
        }
        guard window.isVisible else {
            return false
        }
        if window.tabGroup?.isOverviewVisible == true {
            return true
        }
        return !window.isOnActiveSpace
    }

    /// Synchronously reconciles monitoring and probes Mission Control state before
    /// `window` recomputes its appearance on occlusion or Space transitions so an
    /// occluded or off-Space window revealed by Exposé never flashes non-opaque.
    func refreshBeforeWindowAppearanceSync(for window: NSWindow?) {
        let wasMonitoring = isMonitoring
        reevaluateMonitoring()
        if wasMonitoring,
           isMonitoring,
           overrideForTesting == nil,
           let window,
           window.isVisible,
           !window.isMiniaturized,
           window.isOnActiveSpace {
            probeNow(reason: "window-visibility-sync")
        }
    }

    /// True when at least one eligible blurred desktop window lives on the current
    /// active Space (including windows temporarily covered behind another app on the
    /// same Space, which Exposé spreads into thumbnails when Mission Control opens).
    var hasActiveSpaceEligibleBlurredWindow: Bool {
        for window in eligibleWindows.allObjects {
            guard window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  window.isOnActiveSpace else {
                continue
            }
            return true
        }
        return false
    }

    var hasVisibleEligibleBlurredWindow: Bool {
        for window in eligibleWindows.allObjects {
            guard window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  window.isOnActiveSpace,
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

        // Monitor whenever an eligible blurred window is on the active Space (even if
        // covered behind another app on that Space so Exposé spread is caught), while
        // running zero timers when working in Fullscreen Spaces or other Spaces.
        let shouldMonitor = displaysAwake && (
            hasActiveSpaceEligibleBlurredWindow || (isMissionControlActive && hasAnyRegisteredWindow)
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
        let desiredInterval: Int
        if isMissionControlActive {
            desiredInterval = 80
        } else if hasVisibleEligibleBlurredWindow {
            desiredInterval = 120
        } else {
            desiredInterval = 250
        }
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
        guard isMonitoring || timer != nil || localEventMonitor != nil else {
            return
        }
        isMonitoring = false
        cancelBurstProbes()
        timer?.cancel()
        timer = nil
        timerIntervalMilliseconds = 0
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
        let leewayMilliseconds: Int
        if intervalMilliseconds <= 80 {
            leewayMilliseconds = 15
        } else if intervalMilliseconds <= 120 {
            leewayMilliseconds = 20
        } else {
            leewayMilliseconds = 60
        }
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
        guard localEventMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.swipe, .keyDown]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if Self.shouldTriggerImmediateProbe(for: event) {
                self?.scheduleBurstProbes(reason: "local-input")
            }
            return event
        }
    }

    nonisolated static func shouldTriggerImmediateProbe(for event: NSEvent) -> Bool {
        switch event.type {
        case .swipe:
            return true
        case .keyDown:
            // Mission Control / Exposé keys (160, 131) or Control+Arrow shortcuts (123...126).
            let code = event.keyCode
            if code == 160 || code == 131 { return true }
            return event.modifierFlags.contains(.control) && (123...126).contains(code)
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
        let screens = screenBoundsProvider()
        let active = Self.isMissionControlPresented(
            windows: snapshots,
            screenBounds: screens,
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

    /// Pure locale-independent Mission Control / Exposé detector using Quartz
    /// global display coordinates (`origin` at top-left of primary screen).
    ///
    /// Matches:
    /// 1. `com.apple.dock` (`Dock` / `程序坞` / etc.) onscreen full-screen Exposé
    ///    backdrop canvas at `(dockLevel - 2)..<dockLevel` (`18...19`), OR `>= 2`
    ///    overlapping full-screen `com.apple.dock` windows at `dockLevel...(dockLevel + 3)`
    ///    on the same display (since macOS 26/27 keeps a single permanent full-screen
    ///    `layer == dockLevel` Dock root container per display on normal desktop and
    ///    spawns an additional full-screen Exposé layer on top during Mission Control).
    /// 2. `com.apple.WindowManager` onscreen Mission Control top Spaces strip at
    ///    `layer` `14..<dockLevel` (`14...19`, including macOS 27's `layer == 17`)
    ///    spanning `>= 85%` of any screen's width along that display's Quartz top edge
    ///    (`win.bounds.minY ~= screen.minY`), in either collapsed pill or expanded
    ///    thumbnail bar height (`36...380pt`).
    ///
    /// Rejects:
    /// - Menu-bar Control Center (`com.apple.controlcenter`), Notification Center,
    ///   Spotlight, macOS 26/27 single normal-desktop `layer == 20` Dock container,
    ///   Stage Manager side strip, and desktop wallpaper.
    static func isMissionControlPresented(
        windows: [WindowSnapshot],
        screenBounds: [CGRect],
        bundleIdentifierForPID: (pid_t) -> String?
    ) -> Bool {
        let validScreens = screenBounds.filter { $0.width > 100 && $0.height > 100 }
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
                    let overlap = screen.intersection(win.bounds)
                    guard !overlap.isNull else { return false }
                    return overlap.width >= screen.width * 0.85 &&
                        overlap.height >= screen.height * 0.85
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

            // 2. macOS 26/27 WindowManager top Spaces bar (`layer` 14..<dockLevel, full width, display top edge).
            let isWindowManager = bundleID == "com.apple.WindowManager" ||
                (bundleID == nil && win.ownerName == "WindowManager")
            if isWindowManager && (14..<max(18, dockLevel)).contains(win.layer) {
                let spansTopStrip = win.bounds.height >= 36 &&
                    win.bounds.height <= 380 &&
                    validScreens.contains { screen in
                        let overlap = screen.intersection(win.bounds)
                        guard !overlap.isNull else { return false }
                        return win.bounds.minY >= screen.minY - 240 &&
                            win.bounds.minY <= screen.minY + 48 &&
                            overlap.width >= screen.width * 0.85 &&
                            win.bounds.width >= screen.width * 0.85 &&
                            overlap.height >= 36 &&
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

    /// Converts AppKit `NSScreen.screens` frames (bottom-left origin on primary screen)
    /// into Quartz global coordinates (top-left origin on primary screen, matching
    /// `kCGWindowBounds`), supporting stacked vertical and side-by-side multi-monitor setups.
    static func quartzScreenBounds(fromAppKitFrames frames: [CGRect]) -> [CGRect] {
        guard let primaryHeight = frames.first?.height, primaryHeight > 0 else {
            return [CGRect(x: 0, y: 0, width: 1512, height: 982)]
        }
        return frames.map { frame in
            CGRect(
                x: frame.minX,
                y: primaryHeight - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }

    private static func liveQuartzScreenBounds() -> [CGRect] {
        quartzScreenBounds(fromAppKitFrames: NSScreen.screens.map(\.frame))
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
