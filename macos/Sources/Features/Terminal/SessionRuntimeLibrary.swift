import AppKit
import Combine
import Foundation
import GhosttyKit

struct SessionRuntimeLibraryStrings: Equatable, Sendable {
    private let settings: SettingsStrings

    init(language: OhMyGhosttyLanguage) {
        settings = SettingsStrings(language: language)
    }

    func t(_ english: String, _ chinese: String) -> String {
        settings.t(english, chinese)
    }

    var windowTitle: String { t("Session Library", "会话库") }
    var endpointsHeader: String { t("ENDPOINTS", "连接目标") }
    var sessionsTitle: String { t("Sessions", "会话") }
    var refresh: String { t("Refresh", "刷新") }
    var cancel: String { t("Cancel", "取消") }
    var openExisting: String { t("Open Existing", "打开现有会话") }
    var endSession: String { t("End Session…", "结束会话…") }
    var thisMac: String { t("This Mac", "本机") }
    var running: String { t("Running", "运行中") }
    var starting: String { t("Starting", "启动中") }
    var sessionColumn: String { t("Session", "会话 ID") }
    var agentColumn: String { "Agent" }
    var conversationColumn: String { t("Conversation", "对话 ID") }
    var statusColumn: String { t("Status", "状态") }
    var workingDirectoryColumn: String { t("Working Directory", "工作目录") }
    var pidColumn: String { "PID" }
    var updatedColumn: String { t("Updated", "更新时间") }
    var openErrorTitle: String { t("Session Could Not Be Opened", "无法打开会话") }
    var endConfirmationTitle: String { t("End this session?", "结束此会话？") }
    var endConfirmationAction: String { t("End Session", "结束会话") }
    var cancelAction: String { t("Cancel", "取消") }
    var okAction: String { t("OK", "好") }
    var endErrorTitle: String { t("Could Not End Session", "无法结束会话") }
    var enqueueCloseError: String { t("Could not queue the close request.", "无法将关闭请求加入队列。") }

    func emptyCatalog(_ hasEndpoints: Bool) -> String {
        hasEndpoints
            ? t("Select an endpoint to view its sessions.", "选择一个连接目标以查看会话。")
            : t("Start a local or SSH session to add its endpoint here.",
                "先启动本地或 SSH 会话，之后会在这里显示连接目标。")
    }

    var refreshHint: String { t("Select Refresh to query this endpoint.", "选择“刷新”查询此连接目标。") }
    var connecting: String { t("Connecting and loading sessions…", "正在连接并加载会话…") }
    var noSessions: String { t("No retained sessions were found on this endpoint.", "此连接目标没有可恢复的会话。") }
    var loadFailure: String { t("Could not load sessions.", "无法加载会话。") }

    func sessionCount(_ count: Int) -> String {
        t("\(count) retained session\(count == 1 ? "" : "s")", "\(count) 个会话")
    }

    func endReason(_ value: String) -> String {
        guard settings.isChinese else { return value.replacingOccurrences(of: "_", with: " ") }
        return switch value {
        case "process_exited": "进程已退出"
        case "explicit_close": "已关闭"
        case "detached_timeout": "保留期限已到"
        case "deadline": "已到期"
        case "agent_completed": "Agent 已完成"
        case "lost": "会话已丢失"
        default: value
        }
    }

    func localizedError(_ message: String) -> String {
        let prefixes: [(String, String)] = [
            ("Could not read the saved session endpoints:", "无法读取已保存的连接目标："),
            ("Could not save the session endpoint:", "无法保存连接目标："),
            ("The session runtime helper exited with code ", "会话运行时辅助进程退出，代码为 ")
        ]
        for (english, chinese) in prefixes where message.hasPrefix(english) {
            let suffix = String(message.dropFirst(english.count))
            return t(english, chinese) + suffix
        }
        switch message {
        case "Session query timed out.":
            return t("Session query timed out.", "查询会话超时。")
        case "The endpoint returned too much session data.":
            return t("The endpoint returned too much session data.", "连接目标返回的会话数据过多。")
        case "The endpoint returned invalid session data.":
            return t("The endpoint returned invalid session data.", "连接目标返回了无效的会话数据。")
        case "Could not load sessions.":
            return t("Could not load sessions.", "无法加载会话。")
        case "This session has already ended and cannot be attached.":
            return t("This session has already ended and cannot be attached.", "此会话已结束，无法重新附加。")
        case "Could not attach the existing session in a native terminal tab.":
            return t("Could not attach the existing session in a native terminal tab.",
                     "无法在原生终端标签中附加现有会话。")
        default:
            return settings.isChinese ? "详细信息：\(message)" : message
        }
    }

    func endpointName(_ endpoint: SessionRuntimeCatalogEndpoint) -> String {
        endpoint.descriptor.isLocal ? thisMac : endpoint.descriptor.displayEndpoint
    }
}

@MainActor
enum SessionRuntimeLibrary {
    private static var windowController: SessionRuntimeLibraryWindowController?

    static func show() {
        show(from: TerminalController.preferredParent?.window)
    }

    static func show(from parent: NSWindow?) {
        let controller = windowController ?? SessionRuntimeLibraryWindowController()
        windowController = controller
        controller.showWindow(nil)
        if let window = controller.window {
            window.title = SessionRuntimeLibraryStrings(language: OhMyGhosttySettings.shared.language).windowTitle
            if !window.isVisible {
                if let parent, parent.isVisible {
                    window.setFrameOrigin(NSPoint(
                        x: parent.frame.midX - window.frame.width / 2,
                        y: parent.frame.midY - window.frame.height / 2
                    ))
                } else {
                    window.center()
                }
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.model.refreshIfSelected()
    }

    @discardableResult
    static func focusExisting(
        paneID: UUID,
        in controllers: [TerminalController]? = nil
    ) -> Bool {
        let candidates = controllersIncludingParked(controllers ?? TerminalController.all)
        guard let owner = candidates.first(where: { controller in
            controller.isAvailableForWorkspace &&
                controller.surfaceTree.contains(where: { $0.id == paneID || $0.runtimeInlineSession?.pane == paneID })
        }), let surface = owner.surfaceTree.first(where: { $0.id == paneID || $0.runtimeInlineSession?.pane == paneID }) else {
            return false
        }

        let coordinator = owner.workspaceCoordinator
        if owner.workspacePresentationIsParked {
            if let current = coordinator.liveControllers.first(where: {
                $0.windowSessionID == owner.windowSessionID && !$0.workspacePresentationIsParked
            }) {
                coordinator.requestWorkspaceSwitch(to: owner.workspaceID, from: current) { outcome in
                    guard outcome == .committed else { return }
                    _ = SessionRuntimeLibrary.focusExisting(paneID: paneID, in: [owner])
                }
                return true
            }
            owner.window?.makeKeyAndOrderFront(nil)
            coordinator.didActivate(owner)
            if owner.workspacePresentationIsParked {
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                owner.focusedSurface = surface
                Ghostty.moveFocus(to: surface)
                return true
            }
        }
        if coordinator.hasNonNativeFullscreen(in: owner.windowSessionID) {
            _ = coordinator.selectNonNativeTab(owner)
        } else if let window = owner.window,
                  window.tabGroup?.selectedWindow !== window {
            if owner.tabLayout == .vertical {
                owner.selectVerticalTab(owner)
            } else {
                window.tabGroup?.selectedWindow = window
                owner.markTabActivated()
                window.makeKeyAndOrderFront(nil)
            }
        }
        owner.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        owner.focusedSurface = surface
        Ghostty.moveFocus(to: surface)
        return true
    }

    private static func controllersIncludingParked(_ controllers: [TerminalController]) -> [TerminalController] {
        var seen = Set<ObjectIdentifier>()
        let parked = Array(TerminalWorkspaceCoordinator.shared.parked.values) +
            controllers.flatMap { Array($0.workspaceCoordinator.parked.values) }
        return (controllers + Array(parked))
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    static func openPaneIDs(in controllers: [TerminalController]? = nil) -> Set<UUID> {
        let candidates = controllersIncludingParked(controllers ?? TerminalController.all)
        var result = Set<UUID>()
        for controller in candidates where controller.isAvailableForWorkspace {
            for surface in controller.surfaceTree {
                result.insert(surface.id)
                if let inlinePane = surface.runtimeInlineSession?.pane {
                    result.insert(inlinePane)
                }
            }
        }
        return result
    }

    @discardableResult
    static func openExisting(
        _ session: SessionRuntimeCatalogSession,
        descriptor: SessionRuntimeDescriptor,
        from parent: NSWindow? = nil,
        controllers: [TerminalController]? = nil
    ) throws -> TerminalController? {
        let parentWindow = parent ?? TerminalController.preferredParent?.window
        guard session.isAttachable, let paneID = session.paneID else {
            throw NSError(
                domain: "OMGSessionRuntime",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "This session has already ended and cannot be attached."]
            )
        }
        if focusExisting(paneID: paneID, in: controllers) { return nil }
        let inlineOwner = SessionRuntimeHandoff.shared.inlineOwner(for: paneID)
        let attachedDescriptor = inlineOwner?.localDescriptor ?? descriptor
        let attachedPane = inlineOwner?.localPane ?? paneID

        guard let delegate = NSApp.delegate as? AppDelegate,
              let nativeApp = delegate.ghostty.app else {
            throw CocoaError(.featureUnsupported)
        }
        var config = Ghostty.SurfaceConfiguration()
        try attachedDescriptor.configureAttachExisting(&config)
        config.workingDirectory = inlineOwner?.localDescriptor?.launchWorkingDirectory
            ?? session.workingDirectory ?? descriptor.launchWorkingDirectory
        let surface = Ghostty.SurfaceView(nativeApp, baseConfig: config, uuid: attachedPane)
        let tree = SplitTree<Ghostty.SurfaceView>(view: surface)
        if let controller = TerminalController.newTab(
            delegate.ghostty,
            from: parentWindow,
            withSurfaceTree: tree
        ) {
            return controller
        }
        if parentWindow == nil {
            return TerminalController.newWindow(delegate.ghostty, tree: tree)
        }
        throw NSError(
            domain: "OMGSessionRuntime",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Could not attach the existing session in a native terminal tab."]
        )
    }
}

@MainActor
private final class SessionRuntimeLibraryWindowController: NSWindowController, NSWindowDelegate {
    let model = SessionRuntimeLibraryModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = SessionRuntimeLibraryStrings(language: OhMyGhosttySettings.shared.language).windowTitle
        window.minSize = NSSize(width: 780, height: 440)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = SessionRuntimeLibraryViewController(model: model)
        window.isReleasedWhenClosed = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        model.cancelRefresh()
    }
}

@MainActor
private final class SessionRuntimeLibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: SessionRuntimeLibraryModel
    private let split = NSSplitView()
    private let endpointTable = NSTableView()
    private let sessionTable = NSTableView()
    private let endpointScroll = NSScrollView()
    private let sessionScroll = NSScrollView()
    private let endpointHeader = NSTextField(labelWithString: "ENDPOINTS")
    private let titleLabel = NSTextField(labelWithString: "Sessions")
    private let selectedEndpointLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Existing", target: nil, action: nil)
    private let endButton = NSButton(title: "End Session…", target: nil, action: nil)
    private var observers: Set<AnyCancellable> = []
    private var selectingEndpoint = false
    private var strings: SessionRuntimeLibraryStrings {
        SessionRuntimeLibraryStrings(language: OhMyGhosttySettings.shared.language)
    }

    init(model: SessionRuntimeLibraryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        view = root

        configureEndpointTable()
        configureSessionTable()
        configureControls()

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(makeEndpointPane())
        split.addArrangedSubview(makeSessionPane())
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setPosition(230, ofDividerAt: 0)
        bindModel()
        refreshViews()
    }

    private func configureEndpointTable() {
        endpointHeader.stringValue = strings.endpointsHeader
        endpointTable.headerView = nil
        endpointTable.rowHeight = 42
        endpointTable.allowsEmptySelection = true
        endpointTable.allowsMultipleSelection = false
        endpointTable.dataSource = self
        endpointTable.delegate = self
        endpointTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("endpoint")))
    }

    private func configureSessionTable() {
        sessionTable.rowHeight = 30
        sessionTable.allowsEmptySelection = true
        sessionTable.allowsMultipleSelection = false
        sessionTable.doubleAction = #selector(openSelectedSession)
        sessionTable.target = self
        sessionTable.dataSource = self
        sessionTable.delegate = self
        for (identifier, title, width) in [
            ("session", strings.sessionColumn, CGFloat(110)),
            ("agent", strings.agentColumn, CGFloat(100)),
            ("conversation", strings.conversationColumn, CGFloat(190)),
            ("status", strings.statusColumn, CGFloat(130)),
            ("cwd", strings.workingDirectoryColumn, CGFloat(330)),
            ("pid", strings.pidColumn, CGFloat(70)),
            ("updated", strings.updatedColumn, CGFloat(140))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            sessionTable.addTableColumn(column)
        }
        sessionTable.usesAlternatingRowBackgroundColors = true
    }

    private func configureControls() {
        titleLabel.stringValue = strings.sessionsTitle
        endpointHeader.font = .systemFont(ofSize: 11, weight: .bold)
        endpointHeader.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        selectedEndpointLabel.font = .systemFont(ofSize: 12)
        selectedEndpointLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshOrCancel)
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSelectedSession)
        endButton.bezelStyle = .rounded
        endButton.target = self
        endButton.action = #selector(endSelectedSession)
    }

    private func makeEndpointPane() -> NSView {
        let pane = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        endpointScroll.documentView = endpointTable
        endpointScroll.hasVerticalScroller = true
        endpointScroll.drawsBackground = false
        endpointScroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(endpointHeader)
        stack.addArrangedSubview(endpointScroll)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -14),
            endpointScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            endpointScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        return pane
    }

    private func makeSessionPane() -> NSView {
        let pane = NSView()
        let titleRow = NSStackView(views: [titleLabel, selectedEndpointLabel, NSView(), refreshButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 12
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        sessionScroll.documentView = sessionTable
        sessionScroll.hasVerticalScroller = true
        sessionScroll.hasHorizontalScroller = true
        sessionScroll.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [NSView(), endButton, openButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(titleRow)
        pane.addSubview(statusLabel)
        pane.addSubview(errorLabel)
        pane.addSubview(sessionScroll)
        pane.addSubview(actionRow)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            titleRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            titleRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 15),
            statusLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            errorLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 3),
            sessionScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            sessionScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            sessionScroll.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 10),
            actionRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            actionRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            actionRow.topAnchor.constraint(equalTo: sessionScroll.bottomAnchor, constant: 12),
            actionRow.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16)
        ])
        return pane
    }

    private func bindModel() {
        model.$endpoints.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$sessions.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$loadState.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$selectedEndpointID.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$selectedSessionID.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$persistenceError.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        OhMyGhosttySettings.shared.$language.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
    }

    private func refreshViews() {
        guard isViewLoaded else { return }
        endpointTable.reloadData()
        endpointHeader.stringValue = strings.endpointsHeader
        titleLabel.stringValue = strings.sessionsTitle
        for (identifier, title) in [
            ("session", strings.sessionColumn),
            ("agent", strings.agentColumn),
            ("conversation", strings.conversationColumn),
            ("status", strings.statusColumn),
            ("cwd", strings.workingDirectoryColumn),
            ("pid", strings.pidColumn),
            ("updated", strings.updatedColumn)
        ] {
            sessionTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.title = title
        }
        sessionTable.reloadData()
        selectingEndpoint = true
        if let id = model.selectedEndpointID,
           let row = model.endpoints.firstIndex(where: { $0.id == id }) {
            endpointTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            endpointTable.deselectAll(nil)
        }
        selectingEndpoint = false

        selectedEndpointLabel.stringValue = model.selectedEndpoint.map(strings.endpointName) ?? ""
        refreshButton.title = model.isLoading ? strings.cancel : strings.refresh
        openButton.title = strings.openExisting
        endButton.title = strings.endSession
        let selectedSession = model.sessions.first { $0.id == model.selectedSessionID }
        let canActOnSession: Bool
        if case .loaded = model.loadState { canActOnSession = true } else { canActOnSession = false }
        openButton.isEnabled = canActOnSession && selectedSession?.isAttachable == true
        endButton.isEnabled = canActOnSession && selectedSession?.ended == nil && selectedSession != nil

        switch model.loadState {
        case .idle:
            if model.selectedEndpoint == nil {
                statusLabel.stringValue = strings.emptyCatalog(model.endpoints.isEmpty)
            } else {
                statusLabel.stringValue = strings.refreshHint
            }
        case .loading:
            statusLabel.stringValue = strings.connecting
        case .loaded:
            statusLabel.stringValue = model.sessions.isEmpty
                ? strings.noSessions
                : strings.sessionCount(model.sessions.count)
        case .failed(let message):
            statusLabel.stringValue = strings.loadFailure
            errorLabel.stringValue = strings.localizedError(message)
        }
        if case .failed = model.loadState {} else {
            errorLabel.stringValue = model.persistenceError.map(strings.localizedError) ?? ""
        }
        view.window?.title = strings.windowTitle
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === endpointTable ? model.endpoints.count : model.sessions.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        if tableView === endpointTable {
            guard model.endpoints.indices.contains(row) else { return nil }
            let endpoint = model.endpoints[row]
            return strings.endpointName(endpoint)
        }
        guard model.sessions.indices.contains(row) else { return nil }
        let session = model.sessions[row]
        switch identifier {
        case "session": return session.id.prefix(8).description
        case "agent": return session.agentLabel ?? "—"
        case "conversation": return session.resume?.conversationID ?? "—"
        case "status": return session.statusLabel(using: strings)
        case "cwd": return session.workingDirectory ?? "—"
        case "pid": return session.pid.map(String.init) ?? "—"
        case "updated": return Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(session.updatedAt)))
        default: return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === endpointTable, !selectingEndpoint {
            let row = endpointTable.selectedRow
            model.selectedEndpointID = model.endpoints.indices.contains(row) ? model.endpoints[row].id : nil
        } else if table === sessionTable {
            let row = sessionTable.selectedRow
            model.selectSession(model.sessions.indices.contains(row) ? model.sessions[row] : nil)
        }
    }

    @objc private func refreshOrCancel() {
        if model.isLoading { model.cancelRefresh() } else { model.refresh() }
    }

    @objc private func openSelectedSession() {
        guard let endpoint = model.selectedEndpoint,
              let session = model.sessions.first(where: { $0.id == model.selectedSessionID }) else { return }
        do {
            _ = try SessionRuntimeLibrary.openExisting(
                session,
                descriptor: endpoint.descriptor,
                from: TerminalController.preferredParent?.window
            )
        } catch {
            showError(strings.openErrorTitle, message: strings.localizedError(error.localizedDescription))
        }
    }

    @objc private func endSelectedSession() {
        guard let endpoint = model.selectedEndpoint,
              let session = model.sessions.first(where: { $0.id == model.selectedSessionID }),
              session.ended == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.endConfirmationTitle
        let endpointName = strings.endpointName(endpoint)
        alert.informativeText = strings.t(
            "This ends session \(session.id) on \(endpointName). If the endpoint is disconnected, the request will wait until it reconnects.",
            "这会结束 \(endpointName) 上的会话 \(session.id)。如果连接断开，请求会在连接恢复后发送。"
        )
        alert.addButton(withTitle: strings.endConfirmationAction)
        alert.addButton(withTitle: strings.cancelAction)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.end(session)
        } catch {
            showError(strings.endErrorTitle, message: "\(strings.enqueueCloseError) \(error.localizedDescription)")
        }
    }

    private func showError(_ title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: strings.okAction)
        alert.beginSheetModal(for: window)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

struct SessionRuntimeBackgroundItem: Equatable, Identifiable, Sendable {
    let id: String
    let session: SessionRuntimeCatalogSession
    let descriptor: SessionRuntimeDescriptor
    let workspaceID: String?
    let agent: String?
    let title: String
    let workingDirectory: String?
    let isMobileCreated: Bool
}

@MainActor
final class SessionRuntimeBackgroundStore: ObservableObject {
    static let shared = SessionRuntimeBackgroundStore()

    @Published private(set) var items: [SessionRuntimeBackgroundItem] = []
    var isEnabledInTests = false
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var suppressedSessionIDs: Set<String> = []
    private var observers: Set<AnyCancellable> = []

    private struct MobileSessionMeta: Decodable, Sendable {
        let generation: String
        let workspace: String
        let agent: String
        let project: String?
    }

    private init() {
        guard !OMGApplicationEnvironment.isRunningTests else { return }
        startMonitoring()
    }

    func startMonitoringIfNeeded() {
        guard !OMGApplicationEnvironment.isRunningTests || isEnabledInTests else { return }
        guard timer == nil else { return }
        startMonitoring()
    }

    private func startMonitoring() {
        SessionRuntimeCatalog.shared.$endpoints
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func markOpened(paneID: UUID) {
        let raw = paneID.uuidString.lowercased()
        suppressedSessionIDs.insert(raw)
        items.removeAll { $0.session.id.lowercased() == raw }
    }

    func close(_ item: SessionRuntimeBackgroundItem) {
        let raw = item.session.id.lowercased()
        suppressedSessionIDs.insert(raw)
        items.removeAll { $0.id == item.id || $0.session.id.lowercased() == raw }
        if let paneID = item.session.paneID {
            try? SessionRuntimeCloseQueue.shared.enqueue([
                SessionRuntimeCloseRequest(pane: paneID, descriptor: item.descriptor)
            ])
        }
    }

    func refresh() {
        guard !OMGApplicationEnvironment.isRunningTests || isEnabledInTests else { return }
        var descriptors: [SessionRuntimeDescriptor] = []
        var seenIdentities = Set<String>()
        if let local = try? SessionRuntimeConnections.localDescriptor(policy: SessionRuntimePolicy()) {
            seenIdentities.insert(local.identity)
            descriptors.append(local)
        }
        for endpoint in SessionRuntimeCatalog.shared.endpoints where endpoint.descriptor.isLocal {
            if seenIdentities.insert(endpoint.descriptor.identity).inserted {
                descriptors.append(endpoint.descriptor)
            }
        }
        guard !descriptors.isEmpty else {
            if !items.isEmpty { items = [] }
            return
        }
        let supportURL = OMGApplicationEnvironment.applicationSupportURL()
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let currentRevision = (try? String(
            contentsOf: SessionRuntimeConnections.resources.appendingPathComponent("revision"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSnapshotRevision = (try? String(
            contentsOf: SessionRuntimeConnections.resources.appendingPathComponent("snapshot-revision"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) { [descriptors, supportURL, homePath, currentRevision, currentSnapshotRevision] in
            let mobileFile = supportURL.appendingPathComponent("mobile-sessions.json")
            let mobileMap: [String: MobileSessionMeta] = (try? Data(contentsOf: mobileFile))
                .flatMap { try? JSONDecoder().decode([String: MobileSessionMeta].self, from: $0) } ?? [:]
            var discovered: [(SessionRuntimeCatalogSession, SessionRuntimeDescriptor, MobileSessionMeta?)] = []
            var seenSessions = Set<String>()
            let decoder = JSONDecoder()

            for descriptor in descriptors {
                if Task.isCancelled { return }
                if let currentSnapshotRevision, descriptor.revision != currentRevision {
                    let snapURL = supportURL
                        .appendingPathComponent("session-runtime/versions")
                        .appendingPathComponent(descriptor.revision)
                        .appendingPathComponent("snapshot-revision")
                    let cachedSnap = (try? String(contentsOf: snapURL, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if cachedSnap != currentSnapshotRevision {
                        continue
                    }
                }
                let root = SessionRuntimeConnections.localStateDirectory(
                    for: descriptor,
                    applicationSupportRoot: supportURL
                )
                let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: sessionsDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for entry in entries where entry.pathExtension == "json" {
                    let stem = entry.deletingPathExtension().lastPathComponent
                    let closedMarker = sessionsDir.appendingPathComponent("\(stem).closed")
                    if FileManager.default.fileExists(atPath: closedMarker.path) { continue }
                    guard let data = try? Data(contentsOf: entry),
                          data.count <= 65_536,
                          let session = try? decoder.decode(SessionRuntimeCatalogSession.self, from: data),
                          session.ended == nil,
                          session.isAttachable,
                          let pid = session.pid, pid > 0,
                          kill(pid_t(pid), 0) == 0 else { continue }
                    let key = "\(session.id.lowercased()):\(session.generation)"
                    guard seenSessions.insert(key).inserted else { continue }
                    let meta = mobileMap[session.id].flatMap { $0.generation == session.generation ? $0 : nil }
                    discovered.append((session, descriptor, meta))
                }
            }

            guard !Task.isCancelled else { return }
            let snapshot = discovered
            await MainActor.run { [weak self] in
                guard let self else { return }
                let openPanes = SessionRuntimeLibrary.openPaneIDs()
                let liveRawIDs = Set(snapshot.map { $0.0.id.lowercased() })
                self.suppressedSessionIDs.formIntersection(liveRawIDs)
                for pane in openPanes {
                    self.suppressedSessionIDs.remove(pane.uuidString.lowercased())
                }
                var next: [SessionRuntimeBackgroundItem] = []
                for (session, descriptor, meta) in snapshot {
                    guard let paneID = session.paneID else { continue }
                    let raw = session.id.lowercased()
                    if openPanes.contains(paneID) || self.suppressedSessionIDs.contains(raw) {
                        continue
                    }
                    let agent = meta?.agent ?? session.resume?.agent
                    let cwd = session.workingDirectory
                    let dirLabel: String = {
                        guard let cwd, !cwd.isEmpty else { return String(session.id.prefix(8)) }
                        if cwd == homePath { return "~" }
                        let last = URL(fileURLWithPath: cwd).lastPathComponent
                        return last.isEmpty ? cwd : last
                    }()
                    let agentPrefix: String? = switch agent {
                    case "claude": "Claude Code"
                    case "codex": "Codex"
                    case "pi": "Pi"
                    default: nil
                    }
                    let title = if let agentPrefix {
                        "\(agentPrefix) · \(dirLabel)"
                    } else {
                        dirLabel
                    }
                    next.append(SessionRuntimeBackgroundItem(
                        id: "\(descriptor.identity)/\(session.id)/\(session.generation)",
                        session: session,
                        descriptor: descriptor,
                        workspaceID: meta?.workspace,
                        agent: agent,
                        title: title,
                        workingDirectory: cwd,
                        isMobileCreated: meta != nil
                    ))
                }
                next.sort { lhs, rhs in
                    if lhs.isMobileCreated != rhs.isMobileCreated {
                        return lhs.isMobileCreated && !rhs.isMobileCreated
                    }
                    if lhs.session.updatedAt != rhs.session.updatedAt {
                        return lhs.session.updatedAt > rhs.session.updatedAt
                    }
                    return lhs.session.id < rhs.session.id
                }
                if self.items != next {
                    self.items = next
                }
            }
        }
    }

    func items(for controller: TerminalController) -> [SessionRuntimeBackgroundItem] {
        let knownWorkspaces = Set(controller.workspaceCoordinator.store.workspaces.map { $0.id.uuidString.lowercased() })
        let currentWorkspaceID = controller.workspaceID.uuidString.lowercased()
        return items.filter { item in
            guard let ws = item.workspaceID?.lowercased(), knownWorkspaces.contains(ws) else { return true }
            return ws == currentWorkspaceID
        }
    }
}

@MainActor
final class SessionRuntimeBackgroundHeaderButton: NativeActionControl {
    private let symbolView = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private var currentCount = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .recessed
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        symbolView.imageScaling = .scaleProportionallyDown
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countLabel.alignment = .center
        let row = NSStackView(views: [symbolView, countLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            symbolView.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        countLabel.isHidden = true
        setAccessibilityIdentifier("tabs.background.sessions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    func update(count: Int, isPresented: Bool) {
        setPresentationActive(isPresented)
        guard count != currentCount else { return }
        currentCount = count
        let symbol = count > 0 ? "tray.full" : "tray"
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) }
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        countLabel.isHidden = count == 0
        let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
        let tip = count > 0
            ? strings.t("Background Sessions (\(count))", "后台会话 (\(count))")
            : strings.t("Background Sessions", "后台会话")
        toolTip = tip
        setAccessibilityLabel(tip)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func applyTheme(_ theme: OMGNativeTheme) {
        super.applyTheme(theme)
        symbolView.contentTintColor = currentCount > 0 ? theme.foreground : theme.secondary
        countLabel.textColor = theme.foreground
    }

    var preferredWidth: CGFloat {
        guard currentCount > 0 else { return 26 }
        let textWidth = ceil((countLabel.stringValue as NSString).size(
            withAttributes: [.font: countLabel.font ?? .systemFont(ofSize: 11)]
        ).width)
        return 12 + 14 + 3 + max(8, textWidth)
    }
}

@MainActor
final class SessionRuntimeBackgroundPopoverController: NSViewController {
    private weak var controller: TerminalController?
    private let onDismiss: () -> Void
    private let root = OMGNativeSurfaceView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let libraryButton = NativeActionControl()
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var scrollHeightConstraint: NSLayoutConstraint?
    private var subscriptions = Set<AnyCancellable>()
    var onPreferredSizeChange: ((NSSize) -> Void)?

    init(controller: TerminalController, onDismiss: @escaping () -> Void) {
        self.controller = controller
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bindTheme(to window: NSWindow?) {
        _ = view
        root.bindTheme(to: window)
    }

    override func loadView() {
        root.wantsLayer = true
        root.setAccessibilityIdentifier("background.sessions.popover")

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
        libraryButton.title = strings.t("Library…", "会话库…")
        libraryButton.controlStyle = .bordered
        libraryButton.controlSize = .small
        libraryButton.target = self
        libraryButton.action = #selector(openLibrary)

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(libraryButton)

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            listStack.widthAnchor.constraint(equalTo: document.widthAnchor),
        ])

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 120)
        scrollHeightConstraint = heightConstraint
        heightConstraint.isActive = true

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let mainStack = NSStackView(views: [header, scroll, emptyLabel])
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 300),
        ])

        root.onThemeChange = { [weak self] theme in
            self?.titleLabel.textColor = theme.foreground
            self?.emptyLabel.textColor = theme.secondary
        }
        view = root

        SessionRuntimeBackgroundStore.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        OhMyGhosttySettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        SessionRuntimeBackgroundStore.shared.refresh()
        render()
    }

    @objc private func openLibrary() {
        let window = controller?.window
        onDismiss()
        SessionRuntimeLibrary.show(from: window)
    }

    func fittingSize() -> NSSize {
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    private func render() {
        let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
        libraryButton.title = strings.t("Library…", "会话库…")
        let items = controller.map { SessionRuntimeBackgroundStore.shared.items(for: $0) }
            ?? SessionRuntimeBackgroundStore.shared.items
        titleLabel.stringValue = items.isEmpty
            ? strings.t("Background Sessions", "后台会话")
            : strings.t("Background Sessions (\(items.count))", "后台会话 (\(items.count))")
        emptyLabel.stringValue = strings.t("No background sessions running", "当前没有后台运行的会话")

        for subview in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        if items.isEmpty {
            scroll.isHidden = true
            emptyLabel.isHidden = false
            onPreferredSizeChange?(NSSize(width: 300, height: 112))
            return
        }

        emptyLabel.isHidden = true
        scroll.isHidden = false
        for item in items {
            let row = BackgroundSessionRowView(
                item: item,
                onOpen: { [weak self] in
                    guard let self else { return }
                    let window = self.controller?.window
                    self.onDismiss()
                    if let paneID = item.session.paneID {
                        SessionRuntimeBackgroundStore.shared.markOpened(paneID: paneID)
                    }
                    _ = try? SessionRuntimeLibrary.openExisting(
                        item.session,
                        descriptor: item.descriptor,
                        from: window
                    )
                    SessionRuntimeBackgroundStore.shared.refresh()
                },
                onClose: {
                    SessionRuntimeBackgroundStore.shared.close(item)
                }
            )
            listStack.addArrangedSubview(row)
        }
        let rowHeight: CGFloat = 42
        let totalHeight = CGFloat(items.count) * rowHeight + CGFloat(max(0, items.count - 1)) * 4
        let clampedScrollHeight = min(280, max(rowHeight, totalHeight))
        scrollHeightConstraint?.constant = clampedScrollHeight
        onPreferredSizeChange?(NSSize(width: 300, height: 12 + 26 + 8 + clampedScrollHeight + 12))
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class BackgroundSessionRowView: NSView {
    private let item: SessionRuntimeBackgroundItem
    private let onOpen: () -> Void
    private let onClose: () -> Void
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeButton = NativeActionControl()
    private var trackingArea: NSTrackingArea?
    private var hovered = false {
        didSet {
            guard oldValue != hovered else { return }
            updateAppearance()
        }
    }

    init(item: SessionRuntimeBackgroundItem, onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.item = item
        self.onOpen = onOpen
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let symbol = (item.agent != nil && item.agent != "terminal") ? "sparkles" : "terminal"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) }
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.stringValue = item.workingDirectory ?? String(item.session.id.prefix(8))
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        badgeLabel.stringValue = "Mobile"
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.isHidden = !item.isMobileCreated

        closeButton.configure(
            title: "",
            symbol: "xmark",
            help: SettingsStrings(language: OhMyGhosttySettings.shared.language).t("End Session", "结束会话"),
            enabled: true,
            style: .plain,
            identifier: "background.session.close.\(item.session.id)"
        )
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        let row = NSStackView(views: [iconView, textStack, NSView(), badgeLabel, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        let point = closeButton.convert(event.locationInWindow, from: nil)
        if closeButton.bounds.contains(point) {
            super.mouseDown(with: event)
            return
        }
        onOpen()
    }

    @objc private func closeTapped() {
        onClose()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    private func updateAppearance() {
        let theme = OMGNativeTheme.resolve(for: self)
        layer?.backgroundColor = (hovered ? theme.hoverFill : .clear).cgColor
        iconView.contentTintColor = theme.foreground
        titleLabel.textColor = theme.foreground
        subtitleLabel.textColor = theme.secondary
        badgeLabel.textColor = theme.secondary
    }
}
