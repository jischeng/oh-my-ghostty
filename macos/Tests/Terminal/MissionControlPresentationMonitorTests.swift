import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct MissionControlPresentationMonitorTests {
    @Test
    func classifierMatchesLocalizedDockExposeAndSpacesStripWhileIgnoringControlCenter() {
        let screens = [CGSize(width: 1920, height: 1080), CGSize(width: 1512, height: 982)]
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        let bundleMap: [pid_t: String] = [
            401: "com.apple.dock",
            523: "com.apple.WindowManager",
            525: "com.apple.controlcenter",
            999: "com.jischeng.omg",
        ]

        // 1. Normal macOS 26/27 desktop (including Tahoe's single permanent full-screen
        //    layer == dockLevel Dock container per display + Stage Manager side strip) -> false
        let normalDesktop: [MissionControlPresentationMonitor.WindowSnapshot] = [
            .init(ownerPID: 401, ownerName: "程序坞", layer: dockLevel, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel, bounds: CGRect(x: 1920, y: 0, width: 1512, height: 982)),
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 14, bounds: CGRect(x: 0, y: 30, width: 190, height: 900)),
            .init(ownerPID: 999, ownerName: "OMG", layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 800)),
        ]
        #expect(!MissionControlPresentationMonitor.isMissionControlPresented(
            windows: normalDesktop,
            screenSizes: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 2. Menu-bar Control Center open (even with large overlay) -> false
        let controlCenterOpen: [MissionControlPresentationMonitor.WindowSnapshot] = normalDesktop + [
            .init(ownerPID: 525, ownerName: "控制中心", layer: 22, bounds: CGRect(x: 1260, y: 0, width: 656, height: 964)),
            .init(ownerPID: 525, ownerName: "Control Center", layer: 25, bounds: CGRect(x: 1540, y: 0, width: 157, height: 30)),
        ]
        #expect(!MissionControlPresentationMonitor.isMissionControlPresented(
            windows: controlCenterOpen,
            screenSizes: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 3a. Chinese macOS localized Dock ("程序坞") Exposé backdrop at dockLevel - 2 (layer 18) -> true
        let chineseDockExposeBackdrop: [MissionControlPresentationMonitor.WindowSnapshot] = normalDesktop + [
            .init(ownerPID: 401, ownerName: "程序坞", layer: dockLevel - 2, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: chineseDockExposeBackdrop,
            screenSizes: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 3b. Stacked second full-screen Dock overlay at dockLevel on same display -> true
        let stackedDockOverlay: [MissionControlPresentationMonitor.WindowSnapshot] = normalDesktop + [
            .init(ownerPID: 401, ownerName: "程序坞", layer: dockLevel, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: stackedDockOverlay,
            screenSizes: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 4. macOS 26/27 WindowManager top Spaces strip -> true
        let windowManagerSpacesStrip: [MissionControlPresentationMonitor.WindowSnapshot] = [
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 14, bounds: CGRect(x: 0, y: 0, width: 1920, height: 202)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: windowManagerSpacesStrip,
            screenSizes: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))
    }

    @Test
    func monitorStaysDormantWithZeroProbesWhenOpaqueClosedOrAsleepAndReleasesWeakWindows() async throws {
        var snapshots: [MissionControlPresentationMonitor.WindowSnapshot] = []
        let center = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let monitor = MissionControlPresentationMonitor(
            snapshotProvider: { snapshots },
            screenSizesProvider: { [CGSize(width: 1512, height: 982)] },
            bundleIdentifierProvider: { $0 == 401 ? "com.apple.dock" : nil },
            notificationCenter: center,
            workspaceNotificationCenter: workspaceCenter,
            enableEventMonitors: false
        )

        #expect(!monitor.isMonitoring)
        #expect(monitor.probeCount == 0)

        // Opaque window registration never starts monitoring or timers.
        let opaqueWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        opaqueWindow.isReleasedWhenClosed = false
        defer { opaqueWindow.close() }

        monitor.updateWindowEligibility(opaqueWindow, wantsBehindWindowBlur: false)
        try await Task.sleep(for: .milliseconds(320))
        #expect(!monitor.isMonitoring)
        #expect(monitor.probeCount == 0)

        // Deallocation / close of an eligible window leaves zero retained window references and stops monitoring.
        weak var weakEligible: NSWindow?
        do {
            let blurred = NSWindow(
                contentRect: NSRect(x: 40, y: 40, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            blurred.isReleasedWhenClosed = false
            weakEligible = blurred
            blurred.orderFront(nil)
            monitor.updateWindowEligibility(blurred, wantsBehindWindowBlur: true)

            if blurred.occlusionState.contains(.visible) {
                #expect(monitor.isMonitoring)
                // Simulate Mission Control entry and exit via snapshots.
                let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
                snapshots = [
                    .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                    .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel - 2, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                ]
                monitor.probeNow(reason: "test-enter")
                #expect(monitor.isMissionControlActive)

                // Screen sleep pauses monitoring cleanly.
                workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
                #expect(!monitor.isMonitoring)
                #expect(!monitor.isMissionControlActive)

                workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
                snapshots = []
                monitor.probeNow(reason: "test-exit")
                #expect(!monitor.isMissionControlActive)
            }

            center.post(name: NSWindow.willCloseNotification, object: blurred)
            blurred.close()
        }

        let probesAfterClose = monitor.probeCount
        try await Task.sleep(for: .milliseconds(320))
        #expect(!monitor.isMonitoring)
        #expect(monitor.probeCount == probesAfterClose)
        #expect(weakEligible == nil)
    }

    @Test
    func missionControlTransitionForcesOpaqueWindowDetachesBlurPausesBreathAndUnmountsHiddenQuickInputBlur() async throws {
        let monitor = MissionControlPresentationMonitor.shared
        defer { monitor.overrideForTesting = nil }
        monitor.overrideForTesting = false

        // 1. Hidden Quick Input composer surface mounts zero NSVisualEffectViews;
        //    presented Quick Input mounts within-window blur on desktop, drops it in
        //    Mission Control, and restores it on exit.
        func countVisualEffectViews(in root: NSView) -> Int {
            let own = (root is NSVisualEffectView) ? 1 : 0
            return own + root.subviews.reduce(0) { $0 + countVisualEffectViews(in: $1) }
        }

        let hiddenHost = NSHostingView(
            rootView: QuickInputGlassSurface(
                cornerRadius: 12,
                themeColor: .black,
                tintOpacity: 0.7,
                colorScheme: .dark,
                isBackdropActive: false
            ).frame(width: 300, height: 120)
        )
        let activeHost = NSHostingView(
            rootView: QuickInputGlassSurface(
                cornerRadius: 12,
                themeColor: .black,
                tintOpacity: 0.7,
                colorScheme: .dark,
                isBackdropActive: true
            ).frame(width: 300, height: 120)
        )

        let window = VerticalTabsTerminalWindow(
            contentRect: NSRect(x: 80, y: 80, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        hiddenHost.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        activeHost.frame = NSRect(x: 0, y: 140, width: 300, height: 120)

        let iconView = NativeTabIconView(frame: NSRect(x: 320, y: 20, width: 26, height: 24))
        stack.addSubview(hiddenHost)
        stack.addSubview(activeHost)
        stack.addSubview(iconView)
        window.contentView = stack
        window.orderFront(nil)
        defer {
            monitor.unregisterWindow(window)
            window.contentView = nil
            window.close()
        }

        stack.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        #expect(countVisualEffectViews(in: hiddenHost) == 0)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(countVisualEffectViews(in: activeHost) == 1)
        }

        let mockConfig = MockConfig(
            backgroundBlur: .radius(20),
            backgroundColor: Color(.sRGB, red: 0.16, green: 0.17, blue: 0.20),
            backgroundOpacity: 0.85
        )
        let surfaceCfg = Ghostty.SurfaceView.DerivedConfig(mockConfig)

        window.syncAppearance(surfaceCfg)
        #expect(!window.isOpaque)
        #expect((window.backgroundColor?.alphaComponent ?? 0) > 0)
        #expect((window.backgroundColor?.alphaComponent ?? 1) < 0.01)

        let workingActivity = TabActivity(
            source: "test",
            state: .working,
            label: "Claude",
            message: nil,
            detail: nil,
            progress: nil,
            icon: .init(kind: .systemSymbol, name: "sparkles")
        )
        iconView.configure(
            controller: nil,
            icon: .systemSymbol("sparkles"),
            selected: true,
            activity: workingActivity
        )
        let couldAnimateBefore = window.occlusionState.contains(.visible) &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if couldAnimateBefore {
            #expect(iconView.isBreathingAnimationRunning)
        }

        // Enter Mission Control: window turns opaque with solid dark backing,
        // Quick Input within-window blur detaches, and breathing animation pauses.
        monitor.overrideForTesting = true
        window.syncAppearance(surfaceCfg)
        try await Task.sleep(for: .milliseconds(60))
        stack.layoutSubtreeIfNeeded()

        #expect(window.isOpaque)
        #expect(abs((window.backgroundColor?.alphaComponent ?? 0) - 1.0) < 0.001)
        #expect(countVisualEffectViews(in: activeHost) == 0)
        #expect(!iconView.isBreathingAnimationRunning)

        // Exit Mission Control: non-opaque backing, within-window blur, and breath all resume.
        monitor.overrideForTesting = false
        window.syncAppearance(surfaceCfg)
        try await Task.sleep(for: .milliseconds(60))
        stack.layoutSubtreeIfNeeded()

        #expect(!window.isOpaque)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(countVisualEffectViews(in: activeHost) == 1)
        }
        if couldAnimateBefore {
            #expect(iconView.isBreathingAnimationRunning)
        }
    }
}
