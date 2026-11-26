import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct MissionControlPresentationMonitorTests {
    @Test
    func classifierMatchesLocalizedDockExposeAndStackedDualMonitorSpacesStripWhileIgnoringControlCenter() {
        // Primary 1920x1080 at AppKit (0, 0) -> Quartz (0, 0, 1920, 1080);
        // Upper stacked 1920x1080 at AppKit (0, 1080) -> Quartz (0, -1080, 1920, 1080);
        // Right side 1512x982 at AppKit (1920, 0) -> Quartz (1920, 98, 1512, 982).
        let screens = MissionControlPresentationMonitor.quartzScreenBounds(fromAppKitFrames: [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1512, height: 982),
        ])
        #expect(screens[1] == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
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
            .init(ownerPID: 401, ownerName: "程序坞", layer: dockLevel, bounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080)),
            .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel, bounds: CGRect(x: 1920, y: 98, width: 1512, height: 982)),
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 14, bounds: CGRect(x: 0, y: 30, width: 190, height: 900)),
            .init(ownerPID: 999, ownerName: "OMG", layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 800)),
        ]
        #expect(!MissionControlPresentationMonitor.isMissionControlPresented(
            windows: normalDesktop,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 2. Menu-bar Control Center open (even with large overlay) -> false
        let controlCenterOpen: [MissionControlPresentationMonitor.WindowSnapshot] = normalDesktop + [
            .init(ownerPID: 525, ownerName: "控制中心", layer: 22, bounds: CGRect(x: 1260, y: 0, width: 656, height: 964)),
            .init(ownerPID: 525, ownerName: "Control Center", layer: 25, bounds: CGRect(x: 1540, y: 0, width: 157, height: 30)),
        ]
        #expect(!MissionControlPresentationMonitor.isMissionControlPresented(
            windows: controlCenterOpen,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 3a. Chinese macOS localized Dock ("程序坞") Exposé backdrop at dockLevel - 2 (layer 18) -> true
        let chineseDockExposeBackdrop: [MissionControlPresentationMonitor.WindowSnapshot] = normalDesktop + [
            .init(ownerPID: 401, ownerName: "程序坞", layer: dockLevel - 2, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: chineseDockExposeBackdrop,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 3b. Stacked second full-screen Dock overlay at dockLevel on same display -> true
        let stackedDockOverlay: [MissionControlPresentationMonitor.WindowSnapshot] = normalDesktop + [
            .init(ownerPID: 401, ownerName: "程序坞", layer: dockLevel, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: stackedDockOverlay,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 4a. macOS 26/27 WindowManager top Spaces strip on primary display (y: 0) -> true
        let primarySpacesStrip: [MissionControlPresentationMonitor.WindowSnapshot] = [
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 14, bounds: CGRect(x: 0, y: 0, width: 1920, height: 202)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: primarySpacesStrip,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 4b. WindowManager top Spaces strip on stacked upper secondary display (Quartz y: -1080) -> true
        let upperDisplaySpacesStrip: [MissionControlPresentationMonitor.WindowSnapshot] = [
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 14, bounds: CGRect(x: 0, y: -1080, width: 1920, height: 202)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: upperDisplaySpacesStrip,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))

        // 4c. macOS 27 WindowManager layer 17 collapsed pill Spaces bar (height 44pt) -> true,
        //     while 30pt menu-bar strip -> false.
        let collapsedMacOS27Strip: [MissionControlPresentationMonitor.WindowSnapshot] = [
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 17, bounds: CGRect(x: 0, y: 0, width: 1920, height: 44)),
        ]
        #expect(MissionControlPresentationMonitor.isMissionControlPresented(
            windows: collapsedMacOS27Strip,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))
        let thinMenuBarStrip: [MissionControlPresentationMonitor.WindowSnapshot] = [
            .init(ownerPID: 523, ownerName: "WindowManager", layer: 17, bounds: CGRect(x: 0, y: 0, width: 1920, height: 30)),
        ]
        #expect(!MissionControlPresentationMonitor.isMissionControlPresented(
            windows: thinMenuBarStrip,
            screenBounds: screens,
            bundleIdentifierForPID: { bundleMap[$0] }
        ))
    }

    @Test
    func eventFilterIgnoresMouseMovesScrollsAndControlReadlineKeysWhileMatchingMissionControlShortcuts() throws {
        func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: flags,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: keyCode
                )
            )
        }

        // Terminal readline / shell Control keys must NEVER trigger probes.
        #expect(!MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 8, flags: .control)))  // Ctrl+C
        #expect(!MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 0, flags: .control)))  // Ctrl+A
        #expect(!MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 14, flags: .control))) // Ctrl+E
        #expect(!MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 126, flags: [])))      // Plain Up arrow

        // Pointer movement and systemDefined / gesture / scroll events must NEVER trigger probes.
        let mouseMoved = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
        #expect(!MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: mouseMoved))

        let systemDefined = try #require(
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            )
        )
        #expect(!MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: systemDefined))

        // Mission Control dedicated keys (160, 131) and Control+Arrow (123...126) DO trigger probes.
        #expect(MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 160, flags: [])))
        #expect(MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 131, flags: [])))
        #expect(MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 126, flags: .control))) // Ctrl+Up
        #expect(MissionControlPresentationMonitor.shouldTriggerImmediateProbe(for: try keyDown(keyCode: 123, flags: .control))) // Ctrl+Left
    }

    @Test
    func monitorStaysDormantWithZeroProbesWhenOpaqueClosedOrAsleepAndReleasesWeakWindows() async throws {
        var snapshots: [MissionControlPresentationMonitor.WindowSnapshot] = []
        let center = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let monitor = MissionControlPresentationMonitor(
            snapshotProvider: { snapshots },
            screenBoundsProvider: { [CGRect(x: 0, y: 0, width: 1512, height: 982)] },
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
        let spinner = NativeProgressIndicator(frame: NSRect(x: 360, y: 20, width: 16, height: 16))
        spinner.style = .spinning
        stack.addSubview(hiddenHost)
        stack.addSubview(activeHost)
        stack.addSubview(iconView)
        stack.addSubview(spinner)
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
        spinner.setAnimating(true)
        if couldAnimateBefore {
            #expect(iconView.isBreathingAnimationRunning)
        }
        if window.occlusionState.contains(.visible) {
            #expect(spinner.animationIsRunning)
        }

        // Enter Mission Control: window turns opaque with solid dark backing,
        // Quick Input within-window blur detaches, and breathing + spinner animations pause.
        monitor.overrideForTesting = true
        window.syncAppearance(surfaceCfg)
        try await Task.sleep(for: .milliseconds(60))
        stack.layoutSubtreeIfNeeded()

        #expect(window.isOpaque)
        #expect(abs((window.backgroundColor?.alphaComponent ?? 0) - 1.0) < 0.001)
        #expect(countVisualEffectViews(in: activeHost) == 0)
        #expect(!iconView.isBreathingAnimationRunning)
        #expect(!spinner.animationIsRunning)

        // Exit Mission Control: non-opaque backing, within-window blur, and breath + spinner resume.
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
        if window.occlusionState.contains(.visible) {
            #expect(spinner.animationIsRunning)
        }
    }

    @Test
    func auxiliaryNativeSurfaceSoleWindowNeverOscillatesDuringMissionControlAndSupportsGlassAtUnitOpacity() throws {
        var snapshots: [MissionControlPresentationMonitor.WindowSnapshot] = []
        let center = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let monitor = MissionControlPresentationMonitor(
            snapshotProvider: { snapshots },
            screenBoundsProvider: { [CGRect(x: 0, y: 0, width: 1512, height: 982)] },
            bundleIdentifierProvider: { $0 == 401 ? "com.apple.dock" : nil },
            notificationCenter: center,
            workspaceNotificationCenter: workspaceCenter,
            enableEventMonitors: false
        )

        var transitionCount = 0
        let token = center.addObserver(
            forName: MissionControlPresentationMonitor.didChangeNotification,
            object: monitor,
            queue: nil
        ) { _ in
            transitionCount += 1
        }
        defer { center.removeObserver(token) }

        let blurFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let glassFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: blurFile)
            try? FileManager.default.removeItem(at: glassFile)
        }
        try "background = 1e2030\nforeground = c8d3f5\nbackground-opacity = 0.70\nbackground-blur = 20\n"
            .write(to: blurFile, atomically: true, encoding: .utf8)
        try "background = 1e2030\nforeground = c8d3f5\nbackground-opacity = 1.0\nbackground-blur = macos-glass-regular\n"
            .write(to: glassFile, atomically: true, encoding: .utf8)

        let blurConfig = Ghostty.Config(at: blurFile.path)
        let glassConfig = Ghostty.Config(at: glassFile.path)

        let glassTheme = OMGNativeTheme.resolve(for: nil, config: glassConfig, missionControlMonitor: monitor)
        #expect(glassTheme.wantsBehindWindowBlur)

        let surface = OMGNativeSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 340, height: 200),
            missionControlMonitor: monitor,
            notificationCenter: center
        )
        let controller = NSViewController()
        controller.view = surface
        let auxWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 340, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        auxWindow.isReleasedWhenClosed = false
        auxWindow.contentViewController = controller
        auxWindow.orderFront(nil)
        surface.bindTheme(to: nil, config: blurConfig)
        defer {
            center.post(name: NSWindow.willCloseNotification, object: auxWindow)
            auxWindow.contentViewController = nil
            auxWindow.close()
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        #expect(!auxWindow.isOpaque)
        #expect(surface.theme.wantsBehindWindowBlur)

        // Enter Mission Control with `auxWindow` as the SOLE registered window in `monitor`.
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        snapshots = [
            .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel - 2, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]
        monitor.probeNow(reason: "mc-tick-1")
        #expect(monitor.isMissionControlActive)
        #expect(auxWindow.isOpaque)
        #expect(surface.theme.wantsBehindWindowBlur)
        #expect(transitionCount == 1)

        // Subsequent watchdog ticks while Mission Control stays open must NOT oscillate.
        monitor.probeNow(reason: "mc-tick-2")
        monitor.probeNow(reason: "mc-tick-3")
        #expect(monitor.isMissionControlActive)
        #expect(auxWindow.isOpaque)
        #expect(transitionCount == 1)

        // Exiting Mission Control restores non-opaque blur cleanly.
        snapshots = []
        monitor.probeNow(reason: "mc-exit")
        #expect(!monitor.isMissionControlActive)
        #expect(!auxWindow.isOpaque)
        #expect(transitionCount == 2)

        // Verify `macos-glass-regular` at `opacity == 1.0` also configures non-opaque aux window on macOS 26+.
        if #available(macOS 26.0, *) {
            surface.bindTheme(to: nil, config: glassConfig)
            #expect(!auxWindow.isOpaque)
        }
    }

    @Test
    func coveredActiveSpaceWindowStaysMonitoredAndProbesSynchronouslyWhenRevealedInMissionControl() {
        var snapshots: [MissionControlPresentationMonitor.WindowSnapshot] = []
        let center = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let monitor = MissionControlPresentationMonitor(
            snapshotProvider: { snapshots },
            screenBoundsProvider: { [CGRect(x: 0, y: 0, width: 1512, height: 982)] },
            bundleIdentifierProvider: { $0 == 401 ? "com.apple.dock" : nil },
            notificationCenter: center,
            workspaceNotificationCenter: workspaceCenter,
            enableEventMonitors: false
        )

        let targetWindow = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 280, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        targetWindow.isReleasedWhenClosed = false
        let coveringWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        coveringWindow.isOpaque = true
        coveringWindow.backgroundColor = .black
        coveringWindow.isReleasedWhenClosed = false
        defer {
            monitor.unregisterWindow(targetWindow)
            targetWindow.close()
            coveringWindow.close()
        }

        targetWindow.orderFront(nil)
        coveringWindow.orderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))

        monitor.updateWindowEligibility(targetWindow, wantsBehindWindowBlur: true)
        if targetWindow.isOnActiveSpace {
            #expect(monitor.isMonitoring)
            #expect(!monitor.shouldSuppressBehindWindowBlur(for: targetWindow))
        }

        // Simulate Exposé spreading `coveringWindow` away while Mission Control is open:
        // `refreshBeforeWindowAppearanceSync` must synchronously detect Mission Control
        // so `shouldSuppressBehindWindowBlur` flips to `true` with zero intermediate frames.
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        snapshots = [
            .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            .init(ownerPID: 401, ownerName: "Dock", layer: dockLevel - 2, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]
        coveringWindow.orderOut(nil)
        targetWindow.orderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        monitor.refreshBeforeWindowAppearanceSync(for: targetWindow)
        if targetWindow.isOnActiveSpace {
            #expect(monitor.isMissionControlActive)
            #expect(monitor.shouldSuppressBehindWindowBlur(for: targetWindow))
        }
    }
}
