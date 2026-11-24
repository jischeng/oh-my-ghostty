import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SplitTabPresentationTests {
    @Test func nativeSelectionUpdatesTheIconWithoutRewritingCellText() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let cell = NativeTabCell()
        var title = "Original title"
        cell.configure(tab: .init(controller: controller, actualIndex: 1), title: nil, presentation: { _ in
            .init(title: title, remoteBreadcrumb: nil, shortcut: "1", icon: .systemSymbol("terminal"),
                  activity: nil, selected: false, hovered: false)
        }, canClose: true, selected: false, select: {}, close: {})
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let label = try #require(descendants(cell).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Original title" })
        let icon = try #require(descendants(cell).compactMap { $0 as? NativeTabIconView }.first)
        let mark = try #require(icon.subviews.compactMap { $0 as? NSImageView }.first)
        title = "Pending title"
        cell.updateSelection(true)
        #expect(label.stringValue == "Original title")
        #expect(mark.contentTintColor == AgentLogoStyle.selectedColor)
        controller.titleOverride = "Trigger the normal data refresh"
        try await Task.sleep(for: .milliseconds(50))
        #expect(label.stringValue == "Pending title")
    }

    @Test func iconPresentationReplacesFocusAndActivityAsOneSnapshot() {
        let theme = OMGNativeTheme(background: .black, foreground: .white)
        let working = TabActivity(source: "codex", state: .working, label: nil, message: nil,
                                  detail: nil, progress: nil, icon: nil)
        let completed = TabActivity(source: "codex", state: .done, label: nil, message: nil,
                                    detail: nil, progress: nil, icon: nil)
        let active = TerminalTabPresentationResolver.iconPresentation(
            controller: nil, icon: .systemSymbol("terminal"), selected: true, activity: working
        )
        let background = TerminalTabPresentationResolver.iconPresentation(
            controller: nil, icon: .systemSymbol("cloud"), selected: false, activity: completed
        )
        let idle = TerminalTabPresentationResolver.iconPresentation(
            controller: nil, icon: .systemSymbol("cloud"), selected: false, activity: nil
        )
        #expect(active.parts[0].focused && active.parts[0].isWorking)
        #expect(!background.parts[0].focused && !background.parts[0].isWorking)
        #expect(background.parts[0].color(theme: theme) == AgentLogoStyle.nativeColor(completed))
        #expect(idle.parts[0].color(theme: theme) == theme.secondary)
        #expect(idle.parts[0].activity == nil)
        // A later snapshot never mutates or revives an earlier working state.
        #expect(active.parts[0].activity == working)
    }

    @Test func splitIconSnapshotsUsePaneFocusAndNeverTabWideActivity() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let first = try #require(controller.surfaceTree.first)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let second = try #require(controller.newSplit(at: first, direction: .right, baseConfig: config))
        let working = TabActivity(source: "codex", state: .working, label: nil, message: nil,
                                  detail: nil, progress: nil, icon: nil)
        controller.focusedSurface = first
        let before = TerminalTabPresentationResolver.iconPresentation(
            controller: controller, icon: .systemSymbol("terminal"), selected: true, activity: working
        )
        controller.focusedSurface = second
        let after = TerminalTabPresentationResolver.iconPresentation(
            controller: controller, icon: .systemSymbol("terminal"), selected: true, activity: working
        )
        let inactive = TerminalTabPresentationResolver.iconPresentation(
            controller: controller, icon: .systemSymbol("terminal"), selected: false, activity: working
        )
        #expect(before.parts.map(\.focused) == [true, false])
        #expect(after.parts.map(\.focused) == [false, true])
        #expect(inactive.parts.allSatisfy { !$0.focused && !$0.isWorking })
        #expect(before.parts.allSatisfy { $0.activity == nil })
    }

    @Test func nativeAgentColorsAndBadgesPreserveSemanticStatusStyles() throws {
        func activity(_ state: TabActivityState,
                      phase: TabActivityPhase? = nil,
                      _ attention: TabAttentionKind? = nil) -> TabActivity {
            .init(source: "codex", state: state, phase: phase, attentionKind: attention,
                  label: nil, message: nil, detail: nil, progress: nil, icon: nil)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                #expect(AgentLogoStyle.selectedColor.usingColorSpace(.sRGB) ==
                    NSColor(TerminalWorkspace.initial.tint).usingColorSpace(.sRGB))
            }
        }
        let working = activity(.working)
        let background = activity(.working, phase: .background)
        #expect(AgentLogoStyle.nativeColor(working) == AgentLogoStyle.selectedColor)
        #expect(AgentLogoStyle.nativeColor(background) == .systemPurple)
        #expect(AgentStatusBadge.resolve(working) == nil)
        #expect(AgentStatusBadge.resolve(background) == nil)
        #expect(AgentLogoStyle.localizedStatus(working) == WorkspaceL10n.text("Working", "工作中"))
        #expect(AgentLogoStyle.localizedStatus(background) == WorkspaceL10n.text("Working in background", "后台运行中"))
        #expect(AgentLogoStyle.toolTip(title: "Repo", activity: nil) == "Repo")
        #expect(AgentLogoStyle.toolTip(title: "Repo", activity: background) ==
            "Repo\ncodex · \(WorkspaceL10n.text("Working in background", "后台运行中"))")
        let done = try #require(AgentStatusBadge.resolve(activity(.done)))
        #expect(done.symbol == "checkmark.circle.fill" && done.color == .systemGreen)
        let question = try #require(AgentStatusBadge.resolve(activity(.needsAttention, .question)))
        #expect(question.symbol == "questionmark.circle.fill" && question.color == .systemOrange)
        let permission = try #require(AgentStatusBadge.resolve(activity(.needsAttention, .permission)))
        #expect(permission.symbol == "hand.raised.fill" && permission.color == .systemOrange)
        let genericAttention = try #require(AgentStatusBadge.resolve(activity(.needsAttention)))
        #expect(genericAttention.symbol == "exclamationmark.circle.fill" && genericAttention.color == .systemOrange)
        let failed = try #require(AgentStatusBadge.resolve(activity(.error)))
        #expect(failed.symbol == "xmark.circle.fill" && failed.color == .systemRed)
    }

    private func pane(_ state: TabActivityState = .idle, focused: Bool = false) -> SplitTabPane {
        .init(id: UUID(), icon: .systemSymbol("terminal"),
              activity: .init(source: "pi", state: state, label: nil, message: nil,
                              detail: nil, progress: nil, icon: nil),
              title: "Terminal", focused: focused)
    }

    @Test func switchingTabsClearsPaneFocusTintWithoutDiscardingFocusHistory() {
        let remembered = UUID(), other = UUID()
        #expect(SplitTabPane.isPaneFocused(selected: true, surfaceID: remembered, focusedID: remembered))
        #expect(!SplitTabPane.isPaneFocused(selected: true, surfaceID: other, focusedID: remembered))
        let inactive = SplitTabPane.isPaneFocused(selected: false, surfaceID: remembered, focusedID: remembered)
        #expect(!inactive)
        #expect(AgentLogoStyle.tintStrength(state: .idle, focused: inactive) == 0)
        #expect(AgentLogoStyle.tintStrength(state: nil, focused: inactive) == 0)
        #expect(SplitTabPane.isPaneFocused(selected: true, surfaceID: remembered, focusedID: remembered))
    }

    @Test func regionRetainsLastFocusWhenFocusMovesElsewhere() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = TabPaneFocusHistory()
        history.record(a, liveIDs: [a, b, c])
        history.record(b, liveIDs: [a, b, c])
        history.record(c, liveIDs: [a, b, c])
        #expect(history.representative(in: [a, b], focused: c) == b)
        #expect(history.representative(in: [a, b], focused: a) == a)
        history.record(nil, liveIDs: [a, c])
        #expect(history.representative(in: [a], focused: c) == a)
        #expect(history.representative(in: [], focused: c) == nil)
    }

    @Test func enlargedCompositionFitsFootprint() {
        #expect(TabIconMetrics.composition == 22)
        #expect(TabIconMetrics.composition < TabIconMetrics.footprint)
        for density in OhMyGhosttyTabRowDensity.allCases {
            #expect(TabIconMetrics.footprint <= density.rowHeight)
        }
        for preferred in [CGFloat(12), 16, 20] {
            #expect(TabIconMetrics.singleLogo(preferred) < TabIconMetrics.composition)
            #expect(TabIconMetrics.singleLogo(preferred) < TabIconMetrics.footprint)
        }
        #expect(TabIconMetrics.singleLogo(16) == 18)
    }

    @Test func previewDividersRespectNestedRatiosAndBounds() {
        let a = MockView(), b = MockView(), c = MockView()
        let tree = SplitTree<MockView>(root: .split(.init(
            direction: .horizontal, ratio: 0.4, left: .leaf(view: a),
            right: .split(.init(direction: .vertical, ratio: 0.25,
                                left: .leaf(view: b), right: .leaf(view: c)))
        )), zoomed: nil)
        let dividers = TabSplitPreviewLayout.dividers(tree: tree, size: CGSize(width: 200, height: 120))
        #expect(dividers == [
            .init(start: CGPoint(x: 80, y: 0), end: CGPoint(x: 80, y: 120)),
            .init(start: CGPoint(x: 80, y: 30), end: CGPoint(x: 200, y: 30))
        ])
        #expect(TabSplitPreviewLayout.dividers(tree: SplitTree<MockView>(), size: .zero).isEmpty)
        #expect(TabSplitPreviewLayout.dividers(tree: SplitTree(view: a), size: CGSize(width: 200, height: 120)).isEmpty)
    }

    @Test func workingBreathHasVisibleRangeAndHonorsReducedMotion() {
        let low = AgentLogoStyle.breath(at: 0.9, reduceMotion: false)
        let high = AgentLogoStyle.breath(at: 0, reduceMotion: false)
        #expect(abs(low) < 0.001)
        #expect(abs(high - 1) < 0.001)
        #expect(AgentLogoStyle.logoOpacity(breath: high) - AgentLogoStyle.logoOpacity(breath: low) > 0.4)
        #expect(AgentLogoStyle.breath(at: 0, reduceMotion: true) == 1)
        #expect(AgentLogoStyle.breath(at: 0.9, reduceMotion: true) == 1)
        #expect(abs(AgentLogoStyle.breath(at: 1.8, reduceMotion: false) - 1) < 0.001)
    }

    @Test func breathRunsOnlyForVisibleWorkingLogos() {
        #expect(AgentLogoStyle.animates(state: .working, visible: true, reduceMotion: false))
        #expect(!AgentLogoStyle.animates(state: .working, visible: false, reduceMotion: false))
        #expect(!AgentLogoStyle.animates(state: .working, visible: true, reduceMotion: true))
        for state: TabActivityState? in [nil, .idle, .done, .needsAttention, .error] {
            #expect(!AgentLogoStyle.animates(state: state, visible: true, reduceMotion: false))
        }
    }

    @Test func nativeBreathAnimatesOnlyLayerOpacityAndStopsAtFullBrightness() throws {
        // Keep the unattached fixture's transaction open; committing an
        // orphan layer lets CoreAnimation discard its pending animations.
        CATransaction.begin()
        defer { CATransaction.commit() }
        let layer = CALayer()
        AgentLogoLayerBreath.setRunning(true, on: layer)
        let animation = try #require(layer.animation(forKey: AgentLogoLayerBreath.key) as? CABasicAnimation)
        #expect(animation.keyPath == "opacity")
        #expect(animation.fromValue as? Double == 1)
        #expect(animation.toValue as? Double == 0.30)
        #expect(animation.duration == 0.9)
        #expect(animation.autoreverses)
        #expect(animation.repeatCount.isInfinite)
        #expect(layer.opacity == 1)
        // Mark the installed animation to detect accidental restarts on an
        // unrelated activity/focus update.
        let marked = try #require(animation.copy() as? CABasicAnimation)
        marked.beginTime = 123
        layer.add(marked, forKey: AgentLogoLayerBreath.key)
        AgentLogoLayerBreath.setRunning(true, on: layer)
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key)?.beginTime == 123)
        AgentLogoLayerBreath.setRunning(false, on: layer)
        #expect(layer.animationKeys()?.isEmpty ?? true)
        #expect(layer.opacity == 1)
    }

    @Test func nativeLogoHasStableSizeAndDoesNotAnimateWithoutVisibleWindow() throws {
        let host = AgentLogoAnimationHost()
        host.setContent(AnyView(Color.red.frame(width: 18, height: 18)), working: true)
        #expect(host.hostingView.fittingSize == CGSize(width: 18, height: 18))
        let layer = try #require(host.layer)
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key) == nil)
        #expect(host.hitTest(.zero) == nil)
        AgentLogoLayerBreath.setRunning(true, on: layer)
        host.setContent(AnyView(Color.green.frame(width: 18, height: 18)), working: false)
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key) == nil)
        #expect(layer.opacity == 1)
        AgentLogoLayerBreath.setRunning(true, on: layer)
        host.stop()
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key) == nil)
    }

    private func snapshot<V: View>(_ content: V) throws -> NSBitmapImageRep {
        // ImageRenderer cannot render the AppKit container. Exercise the real
        // NSHostingView/subview path instead of silently omitting the logos.
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    @Test func focusAndWorkUseSameTintStrengthWhileDoneRemainsVisible() {
        #expect(AgentLogoStyle.tintStrength(state: .idle, focused: true) ==
                AgentLogoStyle.tintStrength(state: .working, focused: true))
        #expect(AgentLogoStyle.tintStrength(state: .idle, focused: false) == 0)
        #expect(AgentLogoStyle.tintStrength(state: .done, focused: true) ==
                AgentLogoStyle.tintStrength(state: .done, focused: false))
        #expect(AgentLogoStyle.tintStrength(state: .done, focused: true) >= 0.7)
        #expect(AgentLogoStyle.logoOpacity(breath: 0) == 0.30)
        #expect(AgentLogoStyle.logoOpacity(breath: 1) == 1)
    }

    @Test func renderAgentTintSamples() throws {
        let agents: [SupportedAgent] = [.codex, .pi, .antigravity]
        let states: [TabActivityState] = [.idle, .working, .needsAttention, .error, .done]
        let content = VStack(spacing: 16) {
            ForEach(agents, id: \.rawValue) { agent in
                HStack(spacing: 18) {
                    ForEach(states.indices, id: \.self) { index in
                        let sample = SplitTabPane(id: UUID(), icon: .asset(agent.assetName),
                                                  activity: pane(states[index]).activity,
                                                  title: agent.displayName, focused: false)
                        PaneLogoMark(pane: sample, size: 22)
                    }
                }
            }
        }.padding(20)
            .background(Color(red: 0.14, green: 0.14, blue: 0.19))
            .environment(\.colorScheme, .dark)
        let bitmap = try snapshot(content)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omg-agent-tint-preview.png"))
    }

    @Test func renderActualSizeComposition() throws {
        let positions: [[CGPoint]] = [
            [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.75, y: 0.75)],
            [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
             CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]
        ]
        let preview = HStack(spacing: 16) {
            ForEach(positions.indices, id: \.self) { layout in
                ZStack {
                    ForEach(positions[layout].indices, id: \.self) { index in
                        PaneLogoMark(pane: pane(index == positions[layout].count - 1 ? .working : .idle), size: TabIconMetrics.pane)
                            .position(x: positions[layout][index].x * TabIconMetrics.composition,
                                      y: positions[layout][index].y * TabIconMetrics.composition)
                    }
                }
                .frame(width: TabIconMetrics.composition, height: TabIconMetrics.composition)
                .frame(width: TabIconMetrics.footprint, height: TabIconMetrics.footprint)
            }
        }
        let bitmap = try snapshot(preview.padding(16).background(Color(nsColor: .windowBackgroundColor)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omg-pane-icons-preview.png"))
    }

    @Test func splitTabPresentationResolvesLeftAgyAndRightClaudeAcrossStatesAndResumeFallback() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let left = try #require(controller.surfaceTree.first)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let right = try #require(controller.newSplit(at: left, direction: .right, baseConfig: config))
        controller.focusedSurface = left

        // Left pane hosts live Antigravity (`idle`); right pane initially has only a
        // persisted Claude resume descriptor (`agentActivity == nil`).
        left.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=idle:app=antigravity"
        )
        controller.adoptAgentResumeDescriptor(
            .init(
                agent: .claude,
                conversationID: AgentConversationID("conv-claude-split"),
                scope: .local,
                workingDirectory: "/tmp"
            ),
            for: right
        )
        #expect(controller.agentActivity(for: left)?.source == "antigravity")
        #expect(controller.agentActivity(for: right) == nil)

        // Split icon composition must show BOTH `AgentAntigravity` (left, focused) and
        // `AgentClaude` (right, idle fallback from resume descriptor) instead of `"terminal"`.
        let theme = OMGNativeTheme(background: .black, foreground: .white)
        let fallbackIcons = TerminalTabPresentationResolver.iconPresentation(
            controller: controller,
            icon: .asset(SupportedAgent.antigravity.glyphAssetName),
            selected: true,
            activity: controller.preferredAgentActivity()
        )
        #expect(fallbackIcons.parts.count == 2)
        #expect(fallbackIcons.parts[0].icon == .asset(SupportedAgent.antigravity.glyphAssetName))
        #expect(fallbackIcons.parts[0].focused)
        #expect(fallbackIcons.parts[1].icon == .asset(SupportedAgent.claude.glyphAssetName))
        #expect(!fallbackIcons.parts[1].focused)
        #expect(fallbackIcons.parts[1].color(theme: theme) == theme.secondary)

        // Split hover menu must also resolve per-pane agent icons rather than hardcoded `"terminal"`.
        let menuEntries = NativeTabIconView.previewMenuEntries(for: controller)
        #expect(menuEntries.count == 3)
        if case let .action(_, symbolLeft, _, checkedLeft, _) = menuEntries[1],
           case let .action(titleRight, symbolRight, _, checkedRight, _) = menuEntries[2] {
            #expect(symbolLeft == SupportedAgent.antigravity.glyphAssetName)
            #expect(checkedLeft)
            #expect(symbolRight == SupportedAgent.claude.glyphAssetName)
            #expect(!checkedRight)
            #expect(titleRight == SupportedAgent.claude.displayName)
        } else {
            Issue.record("Expected two pane action entries in split preview menu")
        }

        // Initial multi-pane tooltip includes both Antigravity and Claude Code.
        let idlePresentation = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil)
        )
        #expect(idlePresentation.activity?.source == "antigravity")
        #expect(idlePresentation.activity?.state == .idle)
        #expect(idlePresentation.toolTip?.contains("Antigravity") == true)
        #expect(idlePresentation.toolTip?.contains("Claude Code") == true)

        // Unfocused right `claude` transitions across working -> needsAttention -> error -> done
        // while left `agy` remains focused and `idle`.
        let transitions: [(String, TabActivityState, String?)] = [
            ("state=working:app=claude-code", .working, nil),
            ("state=blocked:kind=question:app=claude-code", .needsAttention, "questionmark.circle.fill"),
            ("state=error:app=claude-code", .error, "xmark.circle.fill"),
            ("state=done:app=claude-code", .done, "checkmark.circle.fill"),
        ]
        for (payload, expectedState, expectedBadgeSymbol) in transitions {
            right.contextSignal = .init(action: .start, id: "omg-program-status", metadata: payload)
            let resolved = try #require(
                TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil)
            )
            #expect(resolved.activity?.source == "claude")
            #expect(resolved.activity?.state == expectedState)
            #expect(AgentStatusBadge.resolve(resolved.activity)?.symbol == expectedBadgeSymbol)
            #expect(resolved.toolTip?.contains("Antigravity · \(WorkspaceL10n.text("Idle", "空闲"))") == true)
            #expect(resolved.toolTip?.contains("Claude Code · \(AgentLogoStyle.localizedStatus(try #require(resolved.activity)))") == true)
            // Tab Inbox must also place the split tab in `.continue` via `preferredAgentActivity()`.
            let inboxItem = TabInboxModel.item(for: controller)
            #expect(inboxItem.state == expectedState)
            #expect(TabInboxModel.isContinue(inboxItem.state))
        }

        // Conversation titles integrate with both split panes (tab row title/subtitle/tooltip + hover menu).
        let savedTitleMode = OhMyGhosttySettings.shared.agentSessionTitleMode
        OhMyGhosttySettings.shared.agentSessionTitleMode = .native
        defer { OhMyGhosttySettings.shared.agentSessionTitleMode = savedTitleMode }
        let agyConv = try #require(AgentConversationID("conv-agy-split"))
        let claudeConv = try #require(AgentConversationID("conv-claude-split"))
        controller.adoptAgentResumeDescriptor(
            .init(agent: .antigravity, conversationID: agyConv, scope: .local, workingDirectory: "/tmp/repo"),
            for: left
        )
        AgentConversationTitleStore.shared.set(
            "Coordinate status fix", source: .native, agent: .antigravity, conversationID: agyConv
        )
        AgentConversationTitleStore.shared.set(
            "Audit Claude hooks", source: .native, agent: .claude, conversationID: claudeConv
        )
        let titledPresentation = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil)
        )
        #expect(titledPresentation.title == "Coordinate status fix")
        #expect(titledPresentation.showsSubtitle)
        #expect(titledPresentation.toolTip?.contains("Coordinate status fix") == true)
        #expect(titledPresentation.toolTip?.contains("Claude Code") == true)
        let titledMenu = NativeTabIconView.previewMenuEntries(for: controller)
        if case let .action(leftMenuTitle, _, _, _, _) = titledMenu[1],
           case let .action(rightMenuTitle, _, _, _, _) = titledMenu[2] {
            #expect(leftMenuTitle == "Coordinate status fix")
            #expect(rightMenuTitle == "Audit Claude hooks")
        } else {
            Issue.record("Expected conversation titles in split preview menu")
        }

        // Cross-workspace header attention indicator must also surface unfocused split `error`/`needsAttention`
        // from `controller.agentActivities` even when `TabActivityStore` is empty.
        right.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=error:app=claude-code")
        let otherWorkspace = try #require(fixture.store.create(name: "Other", symbol: "briefcase", color: "blue"))
        let otherTab = try fixture.tab(workspace: otherWorkspace)
        let headerState = TerminalWorkspaceHeaderState.resolve(controller: otherTab, activities: TabActivityStore())
        #expect(headerState.needsAttention)
    }

    @Test func nativeActionPopoverRendersLeadingIconAndTrailingCheckmarkWhenChecked() throws {
        func optionButtons(in view: NSView) -> [NativeActionControl] {
            (view as? NativeActionControl).map { [$0] } ?? view.subviews.flatMap { optionButtons(in: $0) }
        }

        let entries: [NativeMenuEntry] = [
            .action("Antigravity", symbol: SupportedAgent.antigravity.glyphAssetName, checked: true) {},
            .action("Claude Code", symbol: SupportedAgent.claude.glyphAssetName, checked: false) {},
            .action("Plain Checked", symbol: nil, checked: true) {},
            .action("Explicit Checkmark", symbol: "checkmark", checked: true) {},
        ]
        let popover = NativeActionPopoverController(entries: entries)
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: popover.preferredContentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = popover
        defer {
            window.contentViewController = nil
            window.close()
        }
        popover.view.layoutSubtreeIfNeeded()

        let buttons = optionButtons(in: popover.view)
        #expect(buttons.count == 4)

        // 0: Checked with custom icon -> keeps leading agent icon AND renders trailing checkmark!
        #expect(buttons[0].image != nil)
        #expect(buttons[0].trailingSymbol == "checkmark")
        #expect(buttons[0].trailingImage != nil)
        #expect(buttons[0].glyphRect.width > 0)
        #expect(buttons[0].trailingGlyphRect.width > 0)
        #expect(buttons[0].glyphRect.maxX < buttons[0].trailingGlyphRect.minX)

        // 1: Unchecked with custom icon -> leading agent icon only, no trailing checkmark.
        #expect(buttons[1].image != nil)
        #expect(buttons[1].trailingSymbol == nil)
        #expect(buttons[1].trailingImage == nil)

        // 2: Checked without custom symbol -> leading checkmark only, no duplicate trailing checkmark.
        #expect(buttons[2].image != nil)
        #expect(buttons[2].trailingSymbol == nil)
        #expect(buttons[2].trailingImage == nil)

        // 3: Checked with symbol == "checkmark" -> leading checkmark only, no duplicate trailing checkmark.
        #expect(buttons[3].image != nil)
        #expect(buttons[3].trailingSymbol == nil)
        #expect(buttons[3].trailingImage == nil)

        // Trailing checkmark reserves extra horizontal intrinsic width compared to unchecked same-text control.
        let uncheckedSameText = NativeActionControl()
        uncheckedSameText.configure(
            title: "Antigravity",
            symbol: SupportedAgent.antigravity.glyphAssetName,
            help: nil,
            enabled: true,
            style: .plain,
            identifier: nil
        )
        #expect(buttons[0].intrinsicContentSize.width > uncheckedSameText.intrinsicContentSize.width)
    }
}
