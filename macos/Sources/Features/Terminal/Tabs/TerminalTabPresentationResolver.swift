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

    /// Where a presentation is shown, which decides how much it can say.
    enum Style {
        /// Tab chrome with one line: horizontal tabs, window titles, and the
        /// Tabs view of the sidebar.
        case chrome
        /// A row of the inbox: a session row, named, with the place below it.
        case inbox
    }

    static func resolve(_ controller: TerminalController, index: Int, selected: Bool,
                        activities: TabActivityStore?,
                        icons: AnyGhosttyTabIconProvider = .init(CompositeGhosttyTabIconProvider(overrides: [])),
                        style: Style = .chrome) -> GhosttyTabPresentation? {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else { return nil }
        let settings = OhMyGhosttySettings.shared
        let session = controller.paneSessionContext(for: surface) ?? .init(workingDirectory: surface.pwd, terminalTitle: surface.title)
        let focusedActivity = controller.focusedAgentActivity()
        let activity = controller.preferredAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        let descriptor = controller.agentResumeDescriptor(for: surface)
        let titleActivity = focusedActivity ?? (controller.surfaceTree.isSplit ? nil : activity)
        let agent = titleActivity.flatMap { SupportedAgent(rawValue: $0.source) } ?? descriptor?.agent
        let restoredTitle = agent == nil ? controller.restoredTitleFallback(for: surface, terminalTitle: surface.title) : nil
        let pathTitle = agent == nil ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
            : session.agentPathTitle(pathDisplay: settings.tabPathDisplay, resumeDescriptor: descriptor)
        let location = place(session: session, descriptor: descriptor)
        let localPane: Bool = if case .local = session.state { true } else { false }
        let remotePane: Bool = switch session.state {
        case .sshReady, .sshConnecting: true
        case .local: descriptor?.scope == .remote
        }
        // The Tabs view and tab chrome keep their own naming: the user's name,
        // else the place. Only an inbox row is a session row: it carries the
        // session's name, with the place below it. `tabTitleHasSubtitle`
        // mirrors this rule for the sidebar without building a presentation.
        var name: String? = controller.titleOverride
        if style == .inbox, name == nil {
            let titles = settings.agentSessionTitleMode != .off
            let conversation = titles ? controller.agentConversationTitle(for: surface) : nil
            let terminal = conversation == nil && titles
                ? agent.flatMap { sessionName(fromTerminalTitle: surface.title, agent: $0, directory: location) }
                : nil
            // With session titles off, an Agent tab keeps its place title.
            name = titles ? (conversation ?? terminal ?? agent?.displayName) : nil
        }
        let title = name ?? restoredTitle
            ?? (style == .inbox && localPane ? location : nil)
            ?? (agent?.normalizedTitle(pathTitle) ?? pathTitle)
        // Only a sidebar row in the inbox has a second line for the place.
        let subtitle = name == nil || style != .inbox ? nil
            : namedSubtitle(location: location, session: session, agent: agent, pathTitle: pathTitle)
        // Both tab renderers prefer the breadcrumb over the title, so a named
        // tab carries the place only in its subtitle.
        let breadcrumb = controller.titleOverride == nil && restoredTitle == nil && name == nil
            && !(style == .inbox && localPane) ? session.remoteTabBreadcrumb : nil
        let displayTitle = breadcrumb?.title ?? title
        let headerTitle = subtitle.flatMap { $0.isEmpty ? nil : $0 }.map { "\(displayTitle)\n\($0)" } ?? displayTitle
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
        return .init(
            title: title,
            remoteBreadcrumb: breadcrumb,
            subtitle: subtitle,
            subtitleIsRemote: subtitle != nil && remotePane,
            shortcut: settings.showShortcutLabels ? controller.tabShortcutLabel(for: index) : nil,
            icon: icons.icon(for: context) ?? .systemSymbol("terminal"),
            activity: activity,
            toolTip: resolvedToolTip,
            selected: selected,
            hovered: false
        )
    }

    /// The name an Agent gave its session through the terminal title, such as
    /// Claude Code's topic or a Codex thread name, without the decoration
    /// around it.
    ///
    /// A terminal title is also what the shell leaves behind: the command
    /// line that started the Agent. So a title only counts when it carries
    /// the decoration that Agent is known to add; anything else is nil.
    static func sessionName(fromTerminalTitle raw: String, agent: SupportedAgent, directory: String?) -> String? {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: Substring
        switch agent {
        case .claude:
            // "<spinner or status glyph> <topic>". A path or an option also
            // starts with a symbol, but not one that stands alone.
            guard let glyph = title.first, !glyph.isLetter, !glyph.isNumber, !"/~.-_$".contains(glyph),
                  title.dropFirst().first == " " else { return nil }
            name = title.dropFirst(2)
        case .codex:
            // "<thread name> | <project folder>".
            guard let separator = title.range(of: " | ", options: .backwards) else { return nil }
            name = title[..<separator.lowerBound]
        case .pi, .omp:
            // "π - <session name>"; `normalizedTitle` knows the prefixes.
            let stripped = agent.normalizedTitle(title)
            guard stripped != title else { return nil }
            name = Substring(stripped)
        default:
            return nil
        }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = directory.map { ($0 as NSString).lastPathComponent }
        guard cleaned.count >= 2, cleaned.lowercased() != agent.displayName.lowercased(),
              cleaned != folder, cleaned != directory else { return nil }
        return AgentConversationTitleStore.displayTitle(
            cleaned, columns: AgentConversationTitleStore.maximumTitleColumns)
    }

    /// What a named tab shows below its name. Never empty, so every named tab
    /// has two lines: the place, else what the row showed before it had a
    /// name, else the Agent.
    static func namedSubtitle(location: String?, session: PaneSessionContext,
                              agent: SupportedAgent?, pathTitle: String) -> String {
        if let location { return location }
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
