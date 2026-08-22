import AppKit
import SwiftUI
import Testing
@testable import Ghostty
@testable import GhosttyKit

@MainActor
struct VerticalTabsIntegrationTests {
    private let hoverScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-hover.png"
    private let hiddenScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-hidden.png"
    private let lightScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-light.png"
    private let groupsScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-groups.png"
    private let horizontalScreenshotPath = "/tmp/oh-my-ghostty-horizontal-tabs.png"
    private let transparencyVerticalScreenshotPath =
        "/tmp/oh-my-ghostty-transparency-vertical.png"
    private let transparencyHorizontalScreenshotPath =
        "/tmp/oh-my-ghostty-transparency-horizontal.png"
    private let settingsScreenshotPath = "/tmp/oh-my-ghostty-settings-tabs.png"
    private let appearanceSettingsScreenshotPath =
        "/tmp/oh-my-ghostty-settings-appearance.png"
    private let appearanceSettingsLightScreenshotPath =
        "/tmp/oh-my-ghostty-settings-appearance-light.png"
    private let reorderScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-reordered.png"
    private let inspectorScreenshotPath = "/tmp/oh-my-ghostty-inspector-files.png"

    @Test func appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces() async throws {
        let inspectorPresentation = InspectorPresentationStore.shared
        let previousInspectorPresentation = inspectorPresentation.snapshot
        inspectorPresentation.replace(with: .init())
        defer {
            inspectorPresentation.replace(with: previousInspectorPresentation)
        }

        let settingsURL = OhMyGhosttySettings.fileURL
        let previousSettings = try? Data(contentsOf: settingsURL)
        defer {
            if let previousSettings {
                try? previousSettings.write(to: settingsURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: settingsURL)
            }
            OhMyGhosttySettings.shared.reloadFromDisk()
        }
        let settings = OhMyGhosttySettings.shared
        settings.tabLayout = .vertical
        settings.defaultSidebarWidth = 240
        settings.sidebarVisible = true
        settings.groupingMode = .none
        settings.orderingMode = .manual
        settings.showShortcutLabels = true
        settings.rememberSidebarWidth = true
        settings.resetAppearance()

        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        let configURL = URL(fileURLWithPath: "/tmp/Ghostty/testing_config.ghostty")
        let previousConfig = try? Data(contentsOf: configURL)
        defer {
            if let previousConfig {
                try? previousConfig.write(to: configURL)
            } else {
                try? FileManager.default.removeItem(at: configURL)
            }
            appDelegate.ghostty.reloadConfig()
        }
        try await applyConfig(
            "macos-tab-layout = vertical\nbackground = #282c34\nforeground = #f0f0f0\n",
            at: configURL,
            app: appDelegate.ghostty
        )

        let titles = [
            "project-a",
            "project-b",
            "project-c",
            "quant-research",
            "maka-agent",
            "infra-tools",
            "research-notes",
            "oh-my-ghostty",
        ]
        var controllers: [TerminalController] = []

        let first = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration(title: titles[0])
        )
        first.titleOverride = titles[0]
        controllers.append(first)
        _ = try #require(first.window)

        for title in titles.dropFirst() {
            let parent = try #require(controllers.last?.window)
            let controller = try #require(TerminalController.newTab(
                appDelegate.ghostty,
                from: parent,
                withBaseConfig: configuration(title: title)
            ))
            controller.titleOverride = title
            controllers.append(controller)
        }

        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }

        try await settle(controllers)

        let eighth = controllers[7]
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        settings.defaultSidebarWidth = 300
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { abs($0.sidebarWidth - 300) < 0.001 })
        settings.sidebarVisible = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        settings.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        eighth.setSidebarVisible(false)
        settings.tabIconSize = 17
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        eighth.setSidebarVisible(true)
        try await Task.sleep(for: .milliseconds(300))

        eighth.setTabGroupingMode(.none)
        eighth.setTabOrderingMode(.manual)
        let tabGroup = try #require(eighth.window?.tabGroup)
        #expect(tabGroup.windows.count == 8)
        #expect(eighth.tabControllers.count == 8)
        #expect(controllers.allSatisfy { controller in
            (controller.window as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true
        })
        #expect(controllers.compactMap {
            ($0.window as? VerticalTabsTerminalWindow)?.nativeTabBarRejectionCount
        }.reduce(0, +) > 0)
        let alignedWindow = try #require(eighth.window as? VerticalTabsTerminalWindow)
        alignedWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        let controlsCenterY = try #require(alignedWindow.titlebarControlsCenterY)
        let inspectorCenterY = try #require(alignedWindow.inspectorControlsCenterY)
        let trafficLightsCenterY = try #require(alignedWindow.trafficLightsCenterY)
        #expect(abs(controlsCenterY - trafficLightsCenterY) < 0.5)
        #expect(abs(inspectorCenterY - trafficLightsCenterY) < 0.5)
        #expect(alignedWindow.inspectorToggleIsInstalled)

        let surfaceIDs = controllers.map { $0.surfaceTree.first?.id }
        #expect(Set(controllers.map(\.tabSessionID)).count == controllers.count)
        let mockStatus = MockAgentStatusAdapter(store: appDelegate.tabActivities)
        #expect(mockStatus.report(
            sessionID: controllers[0].tabSessionID,
            state: .working,
            message: "Running tests"
        ) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[0].tabSessionID
        )?.state == .working)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[1].tabSessionID
        ) == nil)
        #expect(mockStatus.report(sessionID: controllers[0].tabSessionID, state: .done) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[0].tabSessionID
        )?.state == .done)
        #expect(mockStatus.report(
            sessionID: controllers[0].tabSessionID,
            state: .needsAttention
        ) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[0].tabSessionID
        )?.state == .needsAttention)
        #expect(mockStatus.report(sessionID: controllers[0].tabSessionID, state: .idle) == nil)

        let initialSurfaceSizes = controllers.map(surfaceSize)
        #expect(initialSurfaceSizes.allSatisfy { $0 != nil })
        #expect(!appDelegate.inspectorRegistry.isEmpty)
        let inspectorMenuItem = try #require(menuItem(
            withAction: #selector(AppDelegate.toggleInspector(_:)),
            in: NSApp.mainMenu
        ))
        #expect(inspectorMenuItem.keyEquivalent == "i")
        #expect(inspectorMenuItem.keyEquivalentModifierMask.contains([.command, .shift]))
        #expect(NSApp.sendAction(
            inspectorMenuItem.action!,
            to: inspectorMenuItem.target,
            from: inspectorMenuItem
        ))
        try await Task.sleep(for: .milliseconds(250))
        #expect(eighth.tabLayoutState.isInspectorVisible)
        #expect(eighth.tabLayoutState.selectedInspectorPaneID ==
            BuiltInFilesInspectorProvider.paneID)
        eighth.updateInspectorWidth(380, persist: true)
        #expect(eighth.tabLayoutState.inspectorWidth == 380)
        #expect(inspectorPresentation.snapshot.width == 380)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try capture(window: try #require(eighth.window), path: inspectorScreenshotPath)
        eighth.toggleInspectorPane()
        for _ in 0..<20 where
            eighth.tabLayoutState.isInspectorVisible ||
                controllers.map(surfaceSize) != initialSurfaceSizes {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!eighth.tabLayoutState.isInspectorVisible)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        #expect(controllers.map(surfaceSize) == initialSurfaceSizes)
        let expectedFrameSize = try #require(eighth.window).frame.size
        let switchOrder = [0, 4, 1, 7, 2, 5]
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 {
            for index in switchOrder {
                let target = controllers[index]
                eighth.selectVerticalTab(target)
                #expect(tabGroup.selectedWindow === target.window)
                #expect(target.window?.frame.size == expectedFrameSize)
                #expect((target.window as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
            }
        }
        let switchDuration = start.duration(to: clock.now)
        print("Vertical tabs: 60 switches in \(switchDuration)")
        #expect(switchDuration < .seconds(2))
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        #expect(controllers.map(surfaceSize) == initialSurfaceSizes)

        let firstSurface = try #require(controllers[0].focusedSurface?.surfaceModel)
        for index in 1...8 {
            let configured = appDelegate.ghostty.config.keyboardShortcut(for: "goto_tab:\(index)")
            #expect(controllers[index - 1].tabShortcutLabel(for: index) == configured.map { "\($0)" })
            #expect(controllers[index - 1].tabShortcutLabel(for: index)?.contains("⌘") == true)
        }
        #expect(eighth.tabShortcutLabel(for: 10) == nil)

        eighth.selectVerticalTab(controllers[2])
        eighth.setSidebarVisible(true)
        #expect(eighth.reorderTab(controllers[3], toInsertionIndex: 1))
        #expect(tabGroup.windows.compactMap(\.windowController).map(ObjectIdentifier.init) == [
            controllers[0], controllers[3], controllers[1], controllers[2],
            controllers[4], controllers[5], controllers[6], controllers[7],
        ].map(ObjectIdentifier.init))
        #expect(tabGroup.selectedWindow === controllers[2].window)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try await Task.sleep(for: .milliseconds(100))
        try capture(window: try #require(controllers[2].window), path: reorderScreenshotPath)
        #expect(firstSurface.perform(action: "goto_tab:2"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(tabGroup.selectedWindow === controllers[3].window)
        #expect(firstSurface.perform(action: "goto_tab:3"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(tabGroup.selectedWindow === controllers[1].window)

        eighth.selectVerticalTab(controllers[2])
        #expect(eighth.reorderTab(controllers[2], toInsertionIndex: 0))
        #expect(tabGroup.selectedWindow === controllers[2].window)
        #expect(tabGroup.windows.first === controllers[2].window)
        #expect(controllers[2].tabShortcutLabel(for: 1)?.contains("1") == true)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        for candidate in tabGroup.windows.compactMap({
            $0.windowController as? TerminalController
        }) {
            let restorable = TerminalRestorableState(from: candidate)
            #expect(restorable.tabSessionID == candidate.tabSessionID)
            #expect(restorable.tabCreatedAt == candidate.tabCreatedAt)
        }

        eighth.setTabOrderingMode(.created)
        #expect(tabGroup.windows.compactMap(\.windowController).map(ObjectIdentifier.init) ==
            controllers.map(ObjectIdentifier.init))
        eighth.beginManualTabDrag()
        #expect(eighth.tabLayoutState.orderingMode == .manual)

        for index in [1, 5, 2, 8, 3, 6] {
            #expect(firstSurface.perform(action: "goto_tab:\(index)"))
            try await Task.sleep(for: .milliseconds(40))
            #expect(tabGroup.selectedWindow === controllers[index - 1].window)
            #expect((tabGroup.selectedWindow as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
        }

        let organizer = GhosttyTabOrganizationModel()
        let ungrouped = organizer.groups(
            tabs: eighth.tabControllers,
            grouping: .none,
            ordering: .manual
        )
        #expect(ungrouped.count == 1)
        #expect(ungrouped[0].tabs.map(\.actualIndex) == Array(1...8))

        eighth.setTabOrderingMode(.created)
        eighth.setTabGroupingMode(.project)
        let projectGroups = organizer.groups(
            tabs: eighth.tabControllers,
            grouping: .project,
            ordering: .manual
        )
        #expect(projectGroups.count == 3)
        #expect(projectGroups.map { $0.tabs.count } == [2, 3, 3])
        let collapsedGroup = projectGroups[0]
        let activeGroup = projectGroups[2]
        eighth.tabLayoutState.toggleGroup(collapsedGroup.id)
        eighth.tabLayoutState.toggleGroup(activeGroup.id)
        #expect(eighth.tabLayoutState.collapsedGroupIDs.contains(collapsedGroup.id))
        #expect(eighth.tabLayoutState.collapsedGroupIDs.contains(activeGroup.id))
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)

        let dateGroups = organizer.groups(
            tabs: controllers,
            grouping: .date,
            ordering: .created
        )
        #expect(dateGroups.count == 1)
        #expect(dateGroups[0].title == "Today")

        eighth.setTabOrderingMode(.recentlyUsed)
        eighth.selectVerticalTab(controllers[2])
        controllers[2].markTabActivated()
        let recent = organizer.groups(
            tabs: eighth.tabControllers,
            grouping: .none,
            ordering: .manual
        )
        #expect(recent[0].tabs.first?.controller === controllers[2])
        #expect(recent[0].tabs.first?.actualIndex == 1)
        #expect(controllers[2].tabShortcutLabel(for: 1)?.contains("1") == true)

        let restoredOrganization = VerticalTabWindowLayoutState(isSidebarVisible: true)
        #expect(restoredOrganization.groupingMode == .project)
        #expect(restoredOrganization.orderingMode == .recentlyUsed)

        settings.groupingMode = .date
        settings.orderingMode = .manual
        try await Task.sleep(for: .milliseconds(50))
        #expect(eighth.tabLayoutState.groupingMode == .date)
        #expect(eighth.tabLayoutState.orderingMode == .manual)
        settings.groupingMode = .project
        settings.orderingMode = .recentlyUsed
        try await Task.sleep(for: .milliseconds(50))
        #expect(eighth.tabLayoutState.groupingMode == .project)
        #expect(eighth.tabLayoutState.orderingMode == .recentlyUsed)

        eighth.selectVerticalTab(eighth)
        eighth.setSidebarVisible(true)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        let contentViewID = ObjectIdentifier(try #require(eighth.window?.contentView))
        let surfaceObjectIDs = controllers.compactMap { controller in
            controller.surfaceTree.first.map(ObjectIdentifier.init)
        }

        eighth.updateSidebarWidth(100, persist: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controllers.allSatisfy {
            $0.sidebarWidth == VerticalTabSidebarMetrics.minimumWidth
        })
        eighth.updateSidebarWidth(1_000, persist: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controllers.allSatisfy {
            $0.sidebarWidth <= VerticalTabSidebarMetrics.maximumWidth
        })

        let resizeCount = eighth.tabLayoutState.appliedResizeCount
        for step in 0..<300 {
            eighth.updateSidebarWidth(CGFloat(180 + (step % 171)), persist: false)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(eighth.tabLayoutState.appliedResizeCount - resizeCount <= 5)

        let hiddenSurfaceSizes = controllers.dropLast().map(surfaceSize)
        var startWidth = eighth.sidebarWidth
        for targetWidth in [CGFloat(220), 350, 180, 300] {
            for tick in 1...150 {
                let progress = CGFloat(tick) / 150
                eighth.updateSidebarWidth(
                    startWidth + (targetWidth - startWidth) * progress,
                    persist: false
                )
                try await Task.sleep(for: .milliseconds(8))
            }
            try await Task.sleep(for: .milliseconds(30))
            try capture(
                window: try #require(eighth.window),
                path: "/tmp/oh-my-ghostty-resize-\(Int(targetWidth)).png"
            )
            startWidth = targetWidth
        }
        #expect(controllers.dropLast().map(surfaceSize) == hiddenSurfaceSizes)

        eighth.updateSidebarWidth(340, persist: true)
        #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        #expect(VerticalTabSidebarMetrics.persistedWidth == 340)
        #expect(ObjectIdentifier(try #require(eighth.window?.contentView)) == contentViewID)
        #expect(controllers.compactMap { $0.surfaceTree.first.map(ObjectIdentifier.init) } == surfaceObjectIDs)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try await Task.sleep(for: .milliseconds(300))
        let resizedSurfaceSizes = controllers.map(surfaceSize)
        for index in switchOrder {
            eighth.selectVerticalTab(controllers[index])
            #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        }
        #expect(controllers.map(surfaceSize) == resizedSurfaceSizes)

        eighth.setSidebarVisible(true)
        eighth.toggleSidebar(nil)
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        eighth.toggleSidebar(nil)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })

        let restoredController = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration(title: "restored-width")
        )
        #expect(restoredController.tabLayout == .vertical)
        #expect(restoredController.sidebarWidth == 340)
        #expect(mockStatus.report(
            sessionID: restoredController.tabSessionID,
            state: .working
        ) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: restoredController.tabSessionID
        )?.state == .working)
        restoredController.windowWillClose(.init(
            name: NSWindow.willCloseNotification,
            object: restoredController.window
        ))
        #expect(appDelegate.tabActivities.activity(
            for: restoredController.tabSessionID
        ) == nil)
        restoredController.window?.delegate = nil
        restoredController.window?.close()

        eighth.setTabGroupingMode(.project)
        eighth.setTabOrderingMode(.created)
        #expect(mockStatus.report(
            sessionID: eighth.tabSessionID,
            state: .working,
            message: "Mock agent is working"
        ) == nil)
        try await Task.sleep(for: .milliseconds(300))
        try capture(window: try #require(eighth.window), path: groupsScreenshotPath)
        #expect(mockStatus.report(sessionID: eighth.tabSessionID, state: .idle) == nil)

        eighth.setTabGroupingMode(.none)
        eighth.setTabOrderingMode(.manual)
        eighth.setVerticalTabHovered(controllers[2], hovered: true)
        try await Task.sleep(for: .milliseconds(1_200))
        try capture(window: try #require(eighth.window), path: hoverScreenshotPath)

        eighth.setSidebarVisible(false)
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        #expect((eighth.window as? VerticalTabsTerminalWindow)?.sidebarToggleIsInstalled == true)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try await Task.sleep(for: .milliseconds(1_200))
        try capture(window: try #require(eighth.window), path: hiddenScreenshotPath)

        eighth.setSidebarVisible(true)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        try await Task.sleep(for: .milliseconds(1_200))

        try await applyConfig(
            "macos-tab-layout = vertical\nbackground = #f3f3f3\nforeground = #202020\n",
            at: configURL,
            app: appDelegate.ghostty
        )
        for _ in 0..<20 where !NSColor(eighth.terminalBackgroundColor).isLightColor {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(NSColor(eighth.terminalBackgroundColor).isLightColor)
        try capture(window: try #require(eighth.window), path: lightScreenshotPath)

        try await applyConfig(
            """
            macos-tab-layout = vertical
            macos-titlebar-style = transparent
            background = #161821
            foreground = #c6d0f5
            background-opacity = 0.58
            background-blur = 20
            """,
            at: configURL,
            app: appDelegate.ghostty
        )
        for _ in 0..<20 where abs(eighth.terminalBackgroundOpacity - 0.58) > 0.001 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(abs(eighth.terminalBackgroundOpacity - 0.58) < 0.001)
        try capture(
            window: try #require(eighth.window),
            path: transparencyVerticalScreenshotPath
        )
        let verticalAlpha = try screenshotAlpha(
            at: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.75, y: 0.5)],
            path: transparencyVerticalScreenshotPath
        )
        #expect(verticalAlpha.allSatisfy { abs($0 - 0.58) < 0.01 })

        let appearanceSurface = try #require(eighth.focusedSurface)
        let initialCellSize = appearanceSurface.cellSize

        settings.fontSizeOverride = 19
        settings.backgroundOpacityOverride = 0.42
        settings.windowThemeOverride = .dark
        for _ in 0..<30 where
            abs(eighth.terminalBackgroundOpacity - 0.42) > 0.001 ||
                appearanceSurface.cellSize == initialCellSize ||
                eighth.window?.effectiveAppearance.isDark != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(abs(eighth.terminalBackgroundOpacity - 0.42) < 0.001)
        #expect(appearanceSurface.cellSize != initialCellSize)
        #expect(eighth.window?.effectiveAppearance.isDark == true)

        settings.windowThemeOverride = .light
        for _ in 0..<20 where eighth.window?.effectiveAppearance.isDark != false {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(eighth.window?.effectiveAppearance.isDark == false)

        settings.windowThemeOverride = .system
        for _ in 0..<20 where eighth.window?.appearance != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(eighth.window?.appearance == nil)

        settings.fontSizeOverride = nil
        settings.backgroundOpacityOverride = nil
        settings.windowThemeOverride = nil
        try await Task.sleep(for: .milliseconds(300))

        eighth.newVerticalTab()
        try await Task.sleep(for: .milliseconds(300))
        eighth.refreshTabState()
        let ninth = try #require(eighth.tabControllers.last)
        controllers.append(ninth)
        #expect(tabGroup.windows.count == 9)
        #expect(ninth.sidebarWidth == 340)
        #expect((ninth.window as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
        eighth.closeVerticalTab(ninth)
        try await Task.sleep(for: .milliseconds(200))
        #expect(tabGroup.windows.count == 8)

        eighth.closeVerticalTab(controllers[1])
        try await Task.sleep(for: .milliseconds(200))
        #expect(tabGroup.windows.count == 7)

        settings.tabLayout = .horizontal
        try await applyConfig(
            """
            macos-tab-layout = horizontal
            macos-titlebar-style = transparent
            background = #161821
            foreground = #c6d0f5
            background-opacity = 0.58
            background-blur = 20
            """,
            at: configURL,
            app: appDelegate.ghostty
        )
        let horizontalFirst = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration(title: "horizontal-a")
        )
        horizontalFirst.titleOverride = "horizontal-a"
        let horizontalWindow = try #require(horizontalFirst.window)
        let horizontalSecond = try #require(TerminalController.newTab(
            appDelegate.ghostty,
            from: horizontalWindow,
            withBaseConfig: configuration(title: "horizontal-b")
        ))
        horizontalSecond.titleOverride = "horizontal-b"
        let horizontalThird = try #require(TerminalController.newTab(
            appDelegate.ghostty,
            from: horizontalSecond.window,
            withBaseConfig: configuration(title: "horizontal-c")
        ))
        horizontalThird.titleOverride = "horizontal-c"
        let horizontalControllers = [horizontalFirst, horizontalSecond, horizontalThird]
        defer {
            for controller in horizontalControllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        try await settle(horizontalControllers)
        let nativeWindow = try #require(horizontalThird.window as? TerminalWindow)
        #expect(horizontalThird.tabLayout == .horizontal)
        #expect(!(nativeWindow is VerticalTabsTerminalWindow))
        #expect(horizontalThird.window?.tabGroup?.windows.count == 3)
        #expect(nativeWindow.tabBarView != nil || nativeWindow.titlebarAccessoryViewControllers.contains {
            nativeWindow.isTabBar($0)
        })
        #expect(nativeWindow.inspectorToggleIsInstalled)
        horizontalThird.toggleInspectorPane()
        try await Task.sleep(for: .milliseconds(200))
        #expect(horizontalControllers.allSatisfy { $0.tabLayoutState.isInspectorVisible })
        #expect(horizontalThird.tabLayoutState.inspectorWidth == 380)
        #expect(nativeWindow.tabBarView != nil || nativeWindow.titlebarAccessoryViewControllers.contains {
            nativeWindow.isTabBar($0)
        })
        horizontalThird.toggleInspectorPane()
        try capture(window: nativeWindow, path: horizontalScreenshotPath)
        try capture(window: nativeWindow, path: transparencyHorizontalScreenshotPath)
        let horizontalAlpha = try screenshotAlpha(
            at: [CGPoint(x: 0.5, y: 0.5)],
            path: transparencyHorizontalScreenshotPath
        )
        #expect(horizontalAlpha.allSatisfy { abs($0 - 0.58) < 0.01 })

        settings.tabLayout = .vertical
        settings.groupingMode = .project
        settings.orderingMode = .manual
        let settingsItem = try #require(menuItem(withKeyEquivalent: ",", in: NSApp.mainMenu))
        #expect(settingsItem.action == #selector(AppDelegate.openSettings(_:)))
        #expect(NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
        try await Task.sleep(for: .milliseconds(300))
        let settingsWindow = try #require(NSApp.windows.first { $0.title == "Settings" })
        #expect(settingsWindow.isVisible)
        try capture(window: settingsWindow, path: settingsScreenshotPath)
        settingsWindow.close()

        let appearanceSettingsController = OhMyGhosttySettingsWindowController(
            settings: settings,
            initialSelection: .appearance
        )
        let appearanceSettingsWindow = try #require(appearanceSettingsController.window)
        appearanceSettingsWindow.setContentSize(NSSize(width: 820, height: 640))
        appearanceSettingsWindow.makeKeyAndOrderFront(nil)

        settings.windowThemeOverride = .light
        try await Task.sleep(for: .milliseconds(300))
        #expect(appearanceSettingsWindow.effectiveAppearance.isDark == false)
        try capture(
            window: appearanceSettingsWindow,
            path: appearanceSettingsLightScreenshotPath
        )

        settings.windowThemeOverride = .dark
        try await Task.sleep(for: .milliseconds(300))
        #expect(appearanceSettingsWindow.effectiveAppearance.isDark)
        try capture(
            window: appearanceSettingsWindow,
            path: appearanceSettingsScreenshotPath
        )

        settings.windowThemeOverride = .system
        try await Task.sleep(for: .milliseconds(100))
        #expect(appearanceSettingsWindow.appearance == nil)
        settings.windowThemeOverride = nil
        appearanceSettingsWindow.close()
    }

    private func menuItem(withAction action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action { return item }
            if let nested = menuItem(withAction: action, in: item.submenu) {
                return nested
            }
        }
        return nil
    }

    private func menuItem(withKeyEquivalent key: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent == key { return item }
            if let nested = menuItem(withKeyEquivalent: key, in: item.submenu) {
                return nested
            }
        }
        return nil
    }

    private func applyConfig(
        _ text: String,
        at url: URL,
        app: Ghostty.App
    ) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        app.reloadConfig()
        try await Task.sleep(for: .milliseconds(200))
    }

    private func surfaceSize(_ controller: TerminalController) -> String? {
        guard let size = controller.focusedSurface?.surfaceSize else { return nil }
        return "\(size.columns)x\(size.rows)"
    }

    private func configuration(title: String) -> Ghostty.SurfaceConfiguration {
        let project = switch title {
        case "project-a", "project-b": "project-a"
        case "project-c", "quant-research", "maka-agent": "oh-my-ghostty"
        case "infra-tools", "research-notes", "oh-my-ghostty": "quant-research-platform"
        default: "horizontal-tabs"
        }
        let projectDirectory = "/tmp/oh-my-ghostty-tabs/projects/\(project)"
        let directory = if title == "project-a" || title == "project-b" {
            "\(projectDirectory)/shared"
        } else {
            "\(projectDirectory)/\(title)"
        }
        try? FileManager.default.createDirectory(
            atPath: "\(projectDirectory)/.git",
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            atPath: "\(directory)/Sources",
            withIntermediateDirectories: true
        )
        try? "demo".write(
            toFile: "\(directory)/README.md",
            atomically: true,
            encoding: .utf8
        )
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = directory
        configuration.environmentVariables["TAB_MARKER"] = title
        return configuration
    }

    private func settle(_ controllers: [TerminalController]) async throws {
        try await Task.sleep(for: .milliseconds(500))
        for controller in controllers {
            controller.refreshTabState()
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func screenshotAlpha(at points: [CGPoint], path: String) throws -> [CGFloat] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try #require(NSBitmapImageRep(data: data))
        return try points.map { point in
            let x = Int(CGFloat(image.pixelsWide - 1) * point.x)
            let y = Int(CGFloat(image.pixelsHigh - 1) * point.y)
            return try #require(image.colorAt(x: x, y: y)?.alphaComponent)
        }
    }

    private func capture(window: NSWindow, path: String) throws {
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
