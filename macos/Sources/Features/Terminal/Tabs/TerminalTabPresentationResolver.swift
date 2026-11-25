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
        in controller: TerminalController,
        style: Style = .inbox
    ) -> GhosttyTabIcon {
        if let requested = controller.agentActivity(for: surface)?.icon {
            return requested.kind == .bundledAsset ? .asset(requested.name) : .systemSymbol(requested.name)
        }
        if style == .inbox,
           let descriptor = controller.agentResumeDescriptor(for: surface),
           descriptor.conversationID != nil {
            let requested = descriptor.agent.icon
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
        guard let descriptor = controller.agentResumeDescriptor(for: surface),
              descriptor.conversationID != nil else {
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
        /// A row of the inbox: a session row, named when a real session or
        /// user title exists, with its place below it.
        case inbox
    }

    static func resolve(_ controller: TerminalController, index: Int, selected: Bool,
                        activities: TabActivityStore?,
                        icons: AnyGhosttyTabIconProvider = .init(CompositeGhosttyTabIconProvider(overrides: [])),
                        style: Style = .chrome) -> GhosttyTabPresentation? {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else { return nil }
        let settings = OhMyGhosttySettings.shared
        let session = controller.paneSessionContext(for: surface)
            ?? .init(workingDirectory: surface.pwd, terminalTitle: surface.title)
        let focusedActivity = controller.focusedAgentActivity()
        let activity = controller.preferredAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        let descriptor = controller.agentResumeDescriptor(for: surface)
        let titleActivity = focusedActivity ?? (controller.surfaceTree.isSplit ? nil : activity)
        let userTabTitle = nonEmptyTrimmed(controller.titleOverride)
        let userSurfaceTitle = surface.hasUserSetTitle ? nonEmptyTrimmed(surface.title) : nil
        let explicitUserTitle = userTabTitle ?? userSurfaceTitle

        let title: String
        let subtitle: String?
        let subtitleIsRemote: Bool
        let breadcrumb: RemoteTabBreadcrumb?
        let defaultIcon = paneIcon(for: surface, in: controller, style: style)

        switch style {
        case .chrome:
            let chromeAgent = titleActivity.flatMap { SupportedAgent(rawValue: $0.source) } ?? descriptor?.agent
            let restoredTitle = chromeAgent == nil
                ? controller.restoredTitleFallback(for: surface, terminalTitle: surface.title)
                : nil
            let pathTitle = chromeAgent == nil
                ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
                : session.agentPathTitle(pathDisplay: settings.tabPathDisplay, resumeDescriptor: descriptor)
            let base = explicitUserTitle ?? restoredTitle ?? pathTitle
            title = explicitUserTitle != nil ? base : (chromeAgent?.normalizedTitle(base) ?? base)
            subtitle = nil
            subtitleIsRemote = false
            breadcrumb = explicitUserTitle == nil && restoredTitle == nil ? session.remoteTabBreadcrumb : nil

        case .inbox:
            let resumedAgent = descriptor?.conversationID != nil ? descriptor?.agent : nil
            let agent = titleActivity.flatMap { SupportedAgent(rawValue: $0.source) } ?? resumedAgent
            let restoredTitle = agent == nil
                ? controller.restoredTitleFallback(for: surface, terminalTitle: surface.title)
                : nil
            let pathTitle = agent == nil
                ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
                : session.agentPathTitle(pathDisplay: settings.tabPathDisplay, resumeDescriptor: descriptor)
            let location = place(session: session, descriptor: descriptor)
            let localPane: Bool = if case .local = session.state { true } else { false }
            let remotePane: Bool = switch session.state {
            case .sshReady, .sshConnecting: true
            case .local: descriptor?.scope == .remote
            }

            var name: String? = explicitUserTitle
            if name == nil, settings.agentSessionTitleMode != .off {
                let conversation = controller.agentConversationTitle(for: surface)
                let terminal = conversation == nil
                    ? agent.flatMap {
                        sessionName(
                            fromTerminalTitle: surface.title,
                            agent: $0,
                            directory: location,
                            rawDirectory: session.workingDirectory ?? descriptor?.workingDirectory
                        )
                    }
                    : nil
                name = conversation ?? terminal
            }

            title = name ?? restoredTitle
                ?? (localPane && !remotePane ? location : nil)
                ?? (agent?.normalizedTitle(pathTitle) ?? pathTitle)
            subtitle = name == nil
                ? nil
                : namedSubtitle(location: location, session: session, agent: agent, pathTitle: pathTitle)
            subtitleIsRemote = subtitle != nil && remotePane
            breadcrumb = name == nil && restoredTitle == nil && !(localPane && !remotePane)
                ? session.remoteTabBreadcrumb
                : nil
        }

        let displayTitle = breadcrumb?.title ?? title
        let headerTitle = subtitle.flatMap { $0.isEmpty ? nil : $0 }.map { "\(displayTitle)\n\($0)" } ?? displayTitle
        let context = GhosttyTabIconContext(
            tabID: controller.tabSessionID,
            title: title,
            activity: titleActivity,
            defaultIcon: defaultIcon
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
            subtitleIsRemote: subtitleIsRemote,
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
    static func sessionName(
        fromTerminalTitle raw: String,
        agent: SupportedAgent,
        directory: String?,
        rawDirectory: String? = nil
    ) -> String? {
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
        guard cleaned.count >= 2, cleaned.lowercased() != agent.displayName.lowercased() else { return nil }
        var excluded: Set<String> = ["~"]
        if let directory, !directory.isEmpty {
            excluded.insert(directory)
            excluded.insert((directory as NSString).lastPathComponent)
            if directory == "~" {
                let homeFolder = (homeDirectory as NSString).lastPathComponent
                if !homeFolder.isEmpty { excluded.insert(homeFolder) }
            }
        }
        if let rawDirectory, !rawDirectory.isEmpty {
            excluded.insert(rawDirectory)
            excluded.insert(WorkspacePathPresentation.folderName(rawDirectory))
            excluded.insert(abbreviatingHome(rawDirectory))
            excluded.insert(abbreviatingRemoteHome(rawDirectory))
        }
        guard !excluded.contains(cleaned) else { return nil }
        return AgentConversationTitleStore.displayTitle(
            cleaned, columns: AgentConversationTitleStore.maximumTitleColumns)
    }

    /// What a named tab shows below its name: the place, else what the row
    /// showed before it had a name, else the Agent.
    static func namedSubtitle(location: String?, session: PaneSessionContext,
                              agent: SupportedAgent?, pathTitle: String) -> String {
        if let location { return location }
        let previous = session.remoteTabBreadcrumb?.title ?? pathTitle
        if !previous.isEmpty { return previous }
        return agent?.displayName ?? "Terminal"
    }

    /// Where a pane is: its working directory with the home folder shortened
    /// to `~`, after the host for an SSH pane.
    static func place(session: PaneSessionContext, descriptor: AgentResumeDescriptor?) -> String? {
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let restored = nonEmpty(descriptor?.workingDirectory)
        let remoteAgentDirectory = descriptor?.scope == .remote ? restored : nil
        switch session.state {
        case .sshReady(let ssh, let workingDirectory):
            let directory = nonEmpty(workingDirectory) ?? remoteAgentDirectory
            let user = remoteUser(from: ssh.transferTarget)
            return directory.map {
                RemoteTabBreadcrumb(host: ssh.alias, directory: abbreviatingRemoteHome($0, user: user)).title
            } ?? ssh.alias
        case .sshConnecting(let ssh):
            // The local directory belongs to the SSH launcher until the host
            // reports its own.
            let user = remoteUser(from: ssh.transferTarget)
            return remoteAgentDirectory.map {
                RemoteTabBreadcrumb(host: ssh.alias, directory: abbreviatingRemoteHome($0, user: user)).title
            } ?? ssh.alias
        case .local:
            guard descriptor?.scope == .remote else {
                return (nonEmpty(session.workingDirectory) ?? restored).map { abbreviatingHome($0) }
            }
            // A remote Agent whose connection is down: its host and directory.
            guard let host = descriptor?.sshReplay?.transferTarget else {
                return restored.map { abbreviatingRemoteHome($0) }
            }
            let user = remoteUser(from: host)
            return restored.map {
                RemoteTabBreadcrumb(host: host, directory: abbreviatingRemoteHome($0, user: user)).title
            } ?? host
        }
    }

    private static let homeDirectory = NSHomeDirectory()

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func remoteUser(from transferTarget: String?) -> String? {
        guard let target = transferTarget,
              let atIndex = target.firstIndex(of: "@") else { return nil }
        let candidate = String(target[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains("/"),
              candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return candidate
    }

    /// `~` in place of the user's home folder, without touching the file
    /// system: a row asks on every refresh.
    static func abbreviatingHome(_ path: String, home: String? = nil) -> String {
        let home = home ?? homeDirectory
        guard home.count > 1, path.hasPrefix(home) else { return path }
        let rest = path.dropFirst(home.count)
        guard rest.isEmpty || rest.hasPrefix("/") else { return path }
        return "~" + rest
    }

    /// `~` in place of a remote Unix home folder (`/home/<user>`, `/Users/<user>`,
    /// or `/root`), while preserving non-home paths such as `/opt`, `/var`, `/etc`,
    /// `/tmp`, and `/srv`.
    static func abbreviatingRemoteHome(_ path: String, user: String? = nil) -> String {
        if let user = nonEmptyTrimmed(user) {
            let prefixes = user == "root"
                ? ["/root", "/home/\(user)", "/Users/\(user)"]
                : ["/home/\(user)", "/Users/\(user)"]
            for prefix in prefixes {
                if path == prefix { return "~" }
                if path.hasPrefix(prefix + "/") {
                    return "~" + path.dropFirst(prefix.count)
                }
            }
            return path
        }
        if path == "/root" { return "~" }
        if path.hasPrefix("/root/") {
            return "~" + path.dropFirst("/root".count)
        }
        for rootPrefix in ["/home/", "/Users/"] where path.hasPrefix(rootPrefix) {
            let remainder = path.dropFirst(rootPrefix.count)
            guard !remainder.isEmpty else { return path }
            if let slash = remainder.firstIndex(of: "/") {
                let segment = remainder[..<slash]
                guard !segment.isEmpty else { return path }
                return "~" + remainder[slash...]
            } else {
                return "~"
            }
        }
        return path
    }
}
