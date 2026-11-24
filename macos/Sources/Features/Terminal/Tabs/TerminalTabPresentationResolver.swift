import AppKit

/// Complete icon rendering input; the native tab and pane owners retain state.
struct TerminalTabIconPresentation {
    struct Part {
        let rect: CGRect
        let icon: GhosttyTabIcon
        let activity: TabActivity?
        let focused: Bool

        func color(theme: OMGNativeTheme) -> NSColor {
            if let activity, activity.state != .idle { return AgentLogoStyle.nativeColor(activity) }
            return focused ? AgentLogoStyle.selectedColor : theme.secondary
        }

        var isWorking: Bool { activity?.state == .working }
    }

    let parts: [Part]
    let paneCount: Int
}

@MainActor
enum TerminalTabPresentationResolver {
    static func paneIcon(
        for surface: Ghostty.SurfaceView,
        in controller: TerminalController
    ) -> GhosttyTabIcon {
        if let requested = controller.agentActivity(for: surface)?.icon ??
            controller.agentResumeDescriptor(for: surface)?.agent.icon {
            return requested.kind == .bundledAsset ? .asset(requested.name) : .systemSymbol(requested.name)
        }
        let session = controller.paneSessionContext(for: surface)
        return session?.workspace?.icon ?? .systemSymbol(session?.tabIconSystemName ?? "terminal")
    }

    static func paneSymbolName(
        for surface: Ghostty.SurfaceView,
        in controller: TerminalController
    ) -> String {
        switch paneIcon(for: surface, in: controller) {
        case .systemSymbol(let name), .asset(let name): name
        case .image: "terminal"
        }
    }

    private static func paneSummaryActivity(
        for surface: Ghostty.SurfaceView,
        in controller: TerminalController
    ) -> TabActivity? {
        if let activity = controller.agentActivity(for: surface) {
            return activity
        }
        guard let descriptor = controller.agentResumeDescriptor(for: surface) else {
            return nil
        }
        return .init(
            source: descriptor.agent.rawValue,
            state: .idle,
            label: descriptor.agent.displayName,
            message: nil,
            detail: nil,
            progress: nil,
            icon: descriptor.agent.icon
        )
    }

    static func iconPresentation(
        controller: TerminalController?, icon: GhosttyTabIcon, selected: Bool, activity: TabActivity?
    ) -> TerminalTabIconPresentation {
        guard let controller, controller.surfaceTree.isSplit else {
            return .init(parts: [.init(rect: .init(x: 0, y: 0, width: 1, height: 1),
                                       icon: icon, activity: activity, focused: selected)], paneCount: 1)
        }
        let parts = SplitTabIconLayout.layout(tree: controller.surfaceTree).map { slot in
            let id = controller.tabPaneFocusHistory.representative(
                in: slot.views.map(\.id), focused: controller.focusedSurface?.id
            )
            let surface = slot.views.first { $0.id == id } ?? slot.views[0]
            let paneActivity = controller.agentActivity(for: surface)
            let glyph = paneIcon(for: surface, in: controller)
            return TerminalTabIconPresentation.Part(
                rect: slot.rect, icon: glyph, activity: paneActivity,
                focused: SplitTabPane.isPaneFocused(selected: selected, surfaceID: surface.id,
                                                    focusedID: controller.focusedSurface?.id)
            )
        }
        return .init(parts: parts, paneCount: controller.surfaceTree.count)
    }

    static func resolve(_ controller: TerminalController, index: Int, selected: Bool,
                        activities: TabActivityStore?,
                        icons: AnyGhosttyTabIconProvider = .init(CompositeGhosttyTabIconProvider(overrides: []))) -> GhosttyTabPresentation? {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else { return nil }
        let settings = OhMyGhosttySettings.shared
        let session = controller.paneSessionContext(for: surface) ?? .init(workingDirectory: surface.pwd, terminalTitle: surface.title)
        let focusedActivity = controller.focusedAgentActivity()
        let activity = controller.preferredAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        let descriptor = controller.agentResumeDescriptor(for: surface)
        let titleActivity = focusedActivity ?? (controller.surfaceTree.isSplit ? nil : activity)
        let agent = titleActivity.flatMap { SupportedAgent(rawValue: $0.source) } ?? descriptor?.agent
        // A manual tab name wins over the conversation's own title.
        let conversationTitle = controller.titleOverride == nil ? controller.agentConversationTitle(for: surface) : nil
        let restoredTitle = agent == nil ? controller.restoredTitleFallback(for: surface, terminalTitle: surface.title) : nil
        let pathTitle = agent == nil ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
            : session.agentPathTitle(pathDisplay: settings.tabPathDisplay, resumeDescriptor: descriptor)
        let base = controller.titleOverride ?? conversationTitle ?? restoredTitle ?? pathTitle
        // Title normalisation strips what an Agent adds to a terminal title;
        // a conversation title is not one.
        let title = conversationTitle ?? agent?.normalizedTitle(base) ?? base
        let showsPath = controller.titleOverride == nil && conversationTitle == nil && restoredTitle == nil
        // Never empty, so every row with a conversation title has two lines.
        let place = session.remoteTabBreadcrumb?.title ?? pathTitle
        let subtitle = place.isEmpty ? agent?.displayName : place
        let resolvedBreadcrumb = showsPath ? session.remoteTabBreadcrumb : nil
        let resolvedSubtitle = conversationTitle == nil ? nil : subtitle
        let displayTitle = resolvedBreadcrumb?.title ?? title
        let headerTitle = (resolvedSubtitle.flatMap { $0.isEmpty ? nil : $0 }).map { "\(displayTitle)\n\($0)" } ?? displayTitle
        let context = GhosttyTabIconContext(
            tabID: controller.tabSessionID,
            title: title,
            activity: titleActivity,
            defaultIcon: paneIcon(for: surface, in: controller)
        )
        let splitAgentSummaries: [TabActivity] = controller.surfaceTree.isSplit
            ? controller.surfaceTree.compactMap { paneSummaryActivity(for: $0, in: controller) }
            : []
        let resolvedToolTip: String? = if splitAgentSummaries.count >= 2 {
            AgentLogoStyle.toolTip(title: headerTitle, activities: splitAgentSummaries)
        } else if splitAgentSummaries.count == 1, activity == nil {
            AgentLogoStyle.toolTip(title: headerTitle, activity: splitAgentSummaries[0])
        } else {
            nil
        }
        // Both tab renderers prefer the breadcrumb over the title, so a
        // conversation title moves the place it would have named to the subtitle.
        return .init(
            title: title,
            remoteBreadcrumb: resolvedBreadcrumb,
            subtitle: resolvedSubtitle,
            shortcut: settings.showShortcutLabels ? controller.tabShortcutLabel(for: index) : nil,
            icon: icons.icon(for: context) ?? .systemSymbol("terminal"),
            activity: activity,
            toolTip: resolvedToolTip,
            selected: selected,
            hovered: false
        )
    }
}
