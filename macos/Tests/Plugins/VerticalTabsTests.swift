import AppKit
import Foundation
import Testing
@testable import Ghostty

struct VerticalTabsTests {
    @Test func derivedGroupsRejectCrossGroupDrops() {
        let projectA = UUID()
        let projectB = UUID()

        #expect(VerticalTabDropPolicy.allows(source: projectA, in: [projectA]))
        #expect(!VerticalTabDropPolicy.allows(source: projectB, in: [projectA]))
        #expect(!VerticalTabDropPolicy.allows(source: nil, in: [projectA]))
        #expect(VerticalTabDropPolicy.insertionIndex(destinationIndex: 2, after: false) == 2)
        #expect(VerticalTabDropPolicy.insertionIndex(destinationIndex: 2, after: true) == 3)
    }

    @Test func stableSessionIDIsInjectedIntoNewPTYConfiguration() {
        let sessionID = UUID()
        var base = Ghostty.SurfaceConfiguration()
        base.environmentVariables["EXISTING"] = "value"

        let configured = TerminalController.injectingSessionID(sessionID, into: base)

        #expect(configured.environmentVariables["OH_MY_GHOSTTY_SESSION"] == sessionID.uuidString)
        #expect(configured.environmentVariables["EXISTING"] == "value")
    }

    @Test func visualStatesIncreaseFromNormalToHoverToActive() {
        let normal = GhosttyTabStyle.backgroundOpacity(selected: false, hovered: false)
        let hover = GhosttyTabStyle.backgroundOpacity(selected: false, hovered: true)
        let active = GhosttyTabStyle.backgroundOpacity(selected: true, hovered: false)
        let activeAndHover = GhosttyTabStyle.backgroundOpacity(selected: true, hovered: true)

        #expect(normal < hover)
        #expect(hover < active)
        #expect(activeAndHover == active)
    }

    @Test @MainActor func nativeDragPersistsOnlyOnMouseUp() throws {
        var updates: [(CGFloat, Bool)] = []
        let view = VerticalTabResizeInteraction.DragView(
            currentWidth: { 240 },
            resize: { updates.append(($0, $1)) }
        )
        let down = try #require(mouseEvent(type: .leftMouseDown, x: 100))
        let dragged = try #require(mouseEvent(type: .leftMouseDragged, x: 160))
        let up = try #require(mouseEvent(type: .leftMouseUp, x: 160))

        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)

        #expect(updates.count == 2)
        #expect(updates[0].0 == 300)
        #expect(updates[0].1 == false)
        #expect(updates[1].0 == 300)
        #expect(updates[1].1 == true)
    }

    @Test @MainActor func resizePersistsOnlyTheFinalWidth() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        settings.defaultSidebarWidth = 240
        settings.rememberSidebarWidth = true
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: true,
            sidebarWidth: 240,
            settings: settings
        )
        for width in stride(from: CGFloat(200), through: 350, by: 1) {
            state.updateSidebarWidth(width, availableWidth: 1_000, persist: false)
        }
        #expect(settings.defaultSidebarWidth == 240)
        #expect(state.committedSidebarWidth == 240)
        state.updateSidebarWidth(317, availableWidth: 1_000, persist: true)
        #expect(settings.defaultSidebarWidth == 317)
        #expect(state.committedSidebarWidth == 317)
    }

    @Test @MainActor func resizeUpdatesAreCoalescedToDisplayRate() async throws {
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true, sidebarWidth: 240)
        for step in 0..<300 {
            state.updateSidebarWidth(
                CGFloat(180 + (step % 171)),
                availableWidth: 1_000,
                persist: false
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(state.sidebarWidth == 308)
        #expect(state.appliedResizeCount <= 2)
    }

    @Test @MainActor func persistedWidthIsClampedAndRestored() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        settings.defaultSidebarWidth = 100
        #expect(settings.defaultSidebarWidth == Double(VerticalTabSidebarMetrics.minimumWidth))
        settings.defaultSidebarWidth = 1_000
        #expect(settings.defaultSidebarWidth == Double(VerticalTabSidebarMetrics.maximumWidth))
        settings.defaultSidebarWidth = 333

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.defaultSidebarWidth == 333)
    }

    @Test @MainActor func organizationModesPersistAtWindowLayoutLevel() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true, settings: settings)
        state.setGroupingMode(.project)
        state.setOrderingMode(.recentlyUsed)
        state.toggleGroup("project:test")

        let restoredSettings = OhMyGhosttySettings(fileURL: url)
        let restored = VerticalTabWindowLayoutState(
            isSidebarVisible: true,
            settings: restoredSettings
        )
        #expect(restored.groupingMode == .project)
        #expect(restored.orderingMode == .recentlyUsed)
        #expect(restored.collapsedGroupIDs.isEmpty)
    }

    @Test func tabMetadataProviderCanContributeProjectIdentity() {
        struct MockMetadataProvider: GhosttyTabMetadataProviding {
            func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
                .init(
                    project: .init(
                        id: "project:mock",
                        title: "Mock Project",
                        icon: .systemSymbol("folder.fill")
                    ),
                    agent: nil,
                    workspace: nil,
                    customGroup: nil
                )
            }
        }
        let provider = AnyGhosttyTabMetadataProvider(MockMetadataProvider())
        let metadata = provider.metadata(for: .init(
            tabID: UUID(),
            title: "Terminal",
            workingDirectory: "/tmp"
        ))

        #expect(metadata?.project?.id == "project:mock")
        #expect(metadata?.project?.title == "Mock Project")
    }

    @Test func activityIconOverridesTheTerminalFallback() {
        let activity = TabActivity(
            source: "mock",
            state: .working,
            label: nil,
            message: nil,
            detail: nil,
            progress: nil,
            icon: .init(kind: .systemSymbol, name: "bolt.fill")
        )
        let context = GhosttyTabIconContext(
            tabID: UUID(),
            title: "agent",
            activity: activity
        )
        guard case .systemSymbol(let name) = DefaultGhosttyTabIconProvider().icon(for: context) else {
            Issue.record("Expected activity system symbol")
            return
        }
        #expect(name == "bolt.fill")
    }

    @Test func customIconProviderOverridesTheDefaultIcon() {
        struct MockIconProvider: GhosttyTabIconProviding {
            func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
                context.title == "agent" ? .systemSymbol("bolt.fill") : nil
            }
        }

        let provider = CompositeGhosttyTabIconProvider(overrides: [
            AnyGhosttyTabIconProvider(MockIconProvider()),
        ])
        let context = GhosttyTabIconContext(
            tabID: UUID(),
            title: "agent",
            activity: nil
        )
        guard case .systemSymbol(let name) = provider.icon(for: context) else {
            Issue.record("Expected custom system symbol")
            return
        }
        #expect(name == "bolt.fill")
    }

    @MainActor
    private func temporarySettings() -> (OhMyGhosttySettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        return (OhMyGhosttySettings(fileURL: url), url)
    }

    private func mouseEvent(type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: 0),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    @Test func explicitTitleWins() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: "quant-research",
            terminalTitle: "shell",
            workingDirectory: "/code/project",
            isGitRoot: { _ in false }
        ) == "quant-research")
    }

    @Test func gitRootWinsOverWorkingDirectoryBasename() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: nil,
            terminalTitle: "shell",
            workingDirectory: "/code/oh-my-ghostty/macos/Sources",
            isGitRoot: { $0 == "/code/oh-my-ghostty" }
        ) == "oh-my-ghostty")
    }

    @Test func workingDirectoryBasenameWinsOverTerminalTitle() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: nil,
            terminalTitle: "zsh",
            workingDirectory: "/code/project-a",
            isGitRoot: { _ in false }
        ) == "project-a")
    }

    @Test func terminalPathUsesBasenameAsFallback() {
        #expect(VerticalTabTitleResolver.resolve(
            explicitTitle: " ",
            terminalTitle: "/code/project-b",
            workingDirectory: nil,
            isGitRoot: { _ in false }
        ) == "project-b")
    }
}
