import SwiftUI
import TermioShared
import UIKit

/// Matches desktop AgentLogoStyle's timing and monochrome silhouettes.
struct OMGAgentMark: View {
    let agent: String
    let status: SessionStatus
    var remoteHost: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: status != .working || reduceMotion)) { clock in
            let phase = clock.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8
            let opacity = status == .working && !reduceMotion ? 0.30 + 0.70 * (1 + cos(phase)) / 2 : 1
            Group {
                if UIImage(named: "OMGAgent-\(agent)") != nil {
                    Image("OMGAgent-\(agent)").renderingMode(.template).resizable().scaledToFit()
                } else {
                    Image(systemName: MobileSessionIcon.fallbackSystemSymbol(agent: agent, remoteHost: remoteHost))
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(color)
            .opacity(opacity)
        }
    }

    private var color: Color {
        switch status {
        case .idle: .primary
        case .working: .accentColor
        case .done: .green
        case .needsAttention: .orange
        }
    }
}

/// The Agent tab: project-grouped agent sessions styled with the same theme
/// backdrop, scrolling large title, rounded `ListCard` rows, and bottom-right
/// glass `+` FAB as the Projects and Terminals tabs.
final class OMGAgentListViewController: UIViewController {
    private let store: RosterStore
    private var projects: [MockProject] = []
    private var expandedProjects: Set<String> = []
    private let newAgentButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let emptyState = ListEmptyStateView()
    private var observers: [NSObjectProtocol] = []
    private var themeObserver: NSObjectProtocol?

    init(store: RosterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.sizeScrollingHeaderToFit()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeObserver = installThemeBackdrop()
        configureNewAgentButton()
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        configureFab()
        for name in [RosterStore.didChange, WorkspaceScope.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        projects = store.scopedProjects.filter { $0.kind != "terminals" }.map {
            var project = $0
            project.sessions = project.sessions.filter { $0.agent.id != "terminal" }
            return project
        }.filter { !$0.sessions.isEmpty || $0.kind != "chats" }
        let canStart = store.deviceEndpoint != nil && !targetProjectsForNewSession.isEmpty
        newAgentButton.isHidden = !canStart
        tableView.reloadData()
        updateEmptyState(canStart: canStart)
    }

    // MARK: - Top bar & FAB

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = localized("Agent")
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label

        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [pageTitle, spacer])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return bar
    }

    private func configureFab() {
        newAgentButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newAgentButton)
        NSLayoutConstraint.activate([
            newAgentButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            newAgentButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            newAgentButton.widthAnchor.constraint(equalToConstant: 52),
            newAgentButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func configureNewAgentButton() {
        newAgentButton.applyGlassIcon(.add, boxSize: 24)
        newAgentButton.accessibilityLabel = localized("New Chat")
        newAgentButton.accessibilityIdentifier = "agents.new"
        newAgentButton.showsMenuAsPrimaryAction = true
        newAgentButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenuItems() ?? [])
            },
        ])
    }

    private var targetProjectsForNewSession: [MockProject] {
        let active = projects.filter { $0.rosterID != nil }
        if !active.isEmpty { return active }
        return store.scopedProjects.filter { $0.kind != "terminals" && $0.rosterID != nil }
    }

    private func composeMenuItems() -> [UIMenuElement] {
        let targets = targetProjectsForNewSession
        guard !targets.isEmpty else { return [] }
        if targets.count == 1 {
            return store.newSessionActions(in: targets[0])
        }
        return targets.compactMap { project in
            let actions = store.newSessionActions(in: project)
            guard !actions.isEmpty else { return nil }
            let title = project.kind == "chats" ? localized("Agent") : project.name
            return UIMenu(
                title: title,
                image: UIImage(systemName: "folder"),
                children: actions
            )
        }
    }

    // MARK: - Table & Empty State

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "agentProjectRow")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "agentSessionRow")
        tableView.setScrollingHeader(topBar, horizontalInset: 16, top: 8, bottom: 16)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureEmptyState(below topBar: UIView) {
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func updateEmptyState(canStart: Bool) {
        let hasSessions = projects.contains { !$0.sessions.isEmpty }
        emptyState.isHidden = !projects.isEmpty || hasSessions
        guard !emptyState.isHidden else { return }
        emptyState.configure(
            icon: .bubbleChat,
            title: localized("No chats yet"),
            message: canStart
                ? localized("Tap ＋ to start an agent session, or start one on your Mac.")
                : localized("Open a project or start an agent session on your Mac and it appears here."),
            actionTitle: nil,
            busy: false
        )
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension OMGAgentListViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        projects.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let project = projects[section]
        let isExpanded = expandedProjects.contains(project.stableKey)
        return isExpanded ? 1 + project.sessions.count : 1
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        0
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        nil
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        10
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let project = projects[indexPath.section]
        let isExpanded = expandedProjects.contains(project.stableKey)
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "agentProjectRow", for: indexPath)
            cell.selectionStyle = .none
            cell.backgroundColor = ThemeChrome.background
            cell.clipsToBounds = true
            cell.transform = .identity
            cell.layer.zPosition = 10
            configureProjectHeaderCell(cell, project: project, isExpanded: isExpanded)
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "agentSessionRow", for: indexPath)
            cell.selectionStyle = .none
            cell.backgroundColor = ThemeChrome.background
            cell.clipsToBounds = true
            cell.transform = .identity
            cell.layer.zPosition = 0
            let sessionIndex = indexPath.row - 1
            let session = project.sessions[sessionIndex]
            let isLast = sessionIndex == project.sessions.count - 1
            cell.contentConfiguration = UIHostingConfiguration {
                SessionRow(
                    session: session,
                    isCurrent: store.currentSessionKey == session.key,
                    showsProject: false,
                    isTreeChild: true,
                    isLastTreeChild: isLast,
                    isFirst: false,
                    isLast: isLast
                )
            }
            .margins(.horizontal, ListCard.outerMargin)
            .margins(.vertical, 0)
            return cell
        }
    }

    private func configureProjectHeaderCell(
        _ cell: UITableViewCell,
        project: MockProject,
        isExpanded: Bool
    ) {
        cell.contentConfiguration = UIHostingConfiguration {
            ProjectRow(
                project: project,
                isExpanded: isExpanded,
                isFirst: true,
                isLast: !isExpanded || project.sessions.isEmpty,
                accessibilityID: "agent.folder.\(project.stableKey)"
            )
        }
        .margins(.horizontal, ListCard.outerMargin)
        .margins(.vertical, 0)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let project = projects[indexPath.section]
        if indexPath.row == 0 {
            toggleProjectExpansion(project, inSection: indexPath.section)
        } else {
            store.openSession(project.sessions[indexPath.row - 1])
        }
    }

    private func toggleProjectExpansion(_ project: MockProject, inSection section: Int) {
        let nowExpanded = expandedProjects.insert(project.stableKey).inserted
        if !nowExpanded {
            expandedProjects.remove(project.stableKey)
        }
        tableView.animateDrawerToggle(
            inSection: section,
            childCount: project.sessions.count,
            nowExpanded: nowExpanded
        ) { [weak self] headerCell in
            self?.configureProjectHeaderCell(headerCell, project: project, isExpanded: nowExpanded)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row > 0,
              store.deviceEndpoint != nil,
              let sessionID = projects[indexPath.section].sessions[indexPath.row - 1].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: localized("Close")) { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard store.deviceEndpoint != nil else { return nil }
        let project = projects[indexPath.section]
        if indexPath.row == 0 {
            guard project.rosterID != nil else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(title: project.name, children: self?.store.newSessionActions(in: project) ?? [])
            }
        }
        let session = project.sessions[indexPath.row - 1]
        guard let sessionID = session.rosterID else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: session.title, children: [
                UIAction(
                    title: localized("Close Session"),
                    image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { _ in
                    self?.store.stopSession(sessionID)
                },
            ])
        }
    }
}
