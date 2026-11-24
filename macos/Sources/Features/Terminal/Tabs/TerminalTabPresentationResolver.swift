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
            let session = controller.paneSessionContext(for: surface)
            let glyph: GhosttyTabIcon
            if let requested = paneActivity?.icon {
                glyph = requested.kind == .bundledAsset ? .asset(requested.name) : .systemSymbol(requested.name)
            } else {
                glyph = session?.workspace?.icon ?? .systemSymbol(session?.tabIconSystemName ?? "terminal")
            }
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
        let activity = controller.focusedAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        let descriptor = controller.agentResumeDescriptor(for: surface)
        let agent = activity.flatMap { SupportedAgent(rawValue: $0.source) } ?? descriptor?.agent
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
        let context = GhosttyTabIconContext(tabID: controller.tabSessionID, title: title, activity: activity,
                                           defaultIcon: session.workspace?.icon ?? .systemSymbol(session.tabIconSystemName))
        // Both tab renderers prefer the breadcrumb over the title, so a
        // conversation title moves the place it would have named to the subtitle.
        return .init(title: title, remoteBreadcrumb: showsPath ? session.remoteTabBreadcrumb : nil,
                     subtitle: conversationTitle == nil ? nil : subtitle,
                     shortcut: settings.showShortcutLabels ? controller.tabShortcutLabel(for: index) : nil,
                     icon: icons.icon(for: context) ?? .systemSymbol("terminal"), activity: activity,
                     selected: selected, hovered: false)
    }
}
