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
        // A manual tab name or a conversation title is a name that is not the
        // path, so the place moves below it. `tabTitleHasSubtitle` is the same
        // rule without the formatting; keep the two in step.
        let isNamed = controller.titleOverride != nil || conversationTitle != nil
        let showsPath = !isNamed && restoredTitle == nil
        let subtitle = isNamed
            ? namedSubtitle(session: session, descriptor: descriptor, agent: agent, pathTitle: pathTitle) : nil
        let context = GhosttyTabIconContext(tabID: controller.tabSessionID, title: title, activity: activity,
                                           defaultIcon: session.workspace?.icon ?? .systemSymbol(session.tabIconSystemName))
        // Both tab renderers prefer the breadcrumb over the title, so a named
        // tab carries the place only in its subtitle.
        return .init(title: title, remoteBreadcrumb: showsPath ? session.remoteTabBreadcrumb : nil,
                     subtitle: subtitle,
                     shortcut: settings.showShortcutLabels ? controller.tabShortcutLabel(for: index) : nil,
                     icon: icons.icon(for: context) ?? .systemSymbol("terminal"), activity: activity,
                     selected: selected, hovered: false)
    }

    /// What a named tab shows below its name. Never empty, so every named tab
    /// has two lines: the place, else what the row showed before it had a
    /// name, else the Agent.
    static func namedSubtitle(session: PaneSessionContext, descriptor: AgentResumeDescriptor?,
                              agent: SupportedAgent?, pathTitle: String) -> String {
        if let location = place(session: session, descriptor: descriptor) { return location }
        let previous = session.remoteTabBreadcrumb?.title ?? pathTitle
        if !previous.isEmpty { return previous }
        return agent?.displayName ?? "Terminal"
    }

    /// Where a pane is: its working directory with the home folder shortened
    /// to `~`, after the host for an SSH pane. It does not follow
    /// `tabs.pathDisplay`, which shortens the title of a tab without a name.
    static func place(session: PaneSessionContext, descriptor: AgentResumeDescriptor?) -> String? {
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let restored = nonEmpty(descriptor?.workingDirectory)
        let remoteAgentDirectory = descriptor?.scope == .remote ? restored : nil
        switch session.state {
        case .sshReady(let ssh, let workingDirectory):
            let directory = nonEmpty(workingDirectory) ?? remoteAgentDirectory
            return directory.map { RemoteTabBreadcrumb(host: ssh.alias, directory: $0).title } ?? ssh.alias
        case .sshConnecting(let ssh):
            // The local directory belongs to the SSH launcher until the host
            // reports its own.
            return remoteAgentDirectory.map { RemoteTabBreadcrumb(host: ssh.alias, directory: $0).title } ?? ssh.alias
        case .local:
            guard descriptor?.scope == .remote else {
                return (nonEmpty(session.workingDirectory) ?? restored).map { abbreviatingHome($0) }
            }
            // A remote Agent whose connection is down: its host and directory.
            guard let host = descriptor?.sshReplay?.transferTarget else { return restored }
            return restored.map { RemoteTabBreadcrumb(host: host, directory: $0).title } ?? host
        }
    }

    private static let homeDirectory = NSHomeDirectory()

    /// `~` in place of the user's home folder, without touching the file
    /// system: a row asks on every refresh.
    static func abbreviatingHome(_ path: String, home: String? = nil) -> String {
        let home = home ?? homeDirectory
        guard home.count > 1, path.hasPrefix(home) else { return path }
        let rest = path.dropFirst(home.count)
        guard rest.isEmpty || rest.hasPrefix("/") else { return path }
        return "~" + rest
    }
}
