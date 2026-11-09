import SwiftUI
import TermioShared
import UIKit

/// Matches desktop AgentLogoStyle's timing and monochrome silhouettes.
struct OMGAgentMark: View {
    let agent: String
    let status: SessionStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: status != .working || reduceMotion)) { clock in
            let phase = clock.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8
            let opacity = status == .working && !reduceMotion ? 0.30 + 0.70 * (1 + cos(phase)) / 2 : 1
            Group {
                if UIImage(named: "OMGAgent-\(agent)") != nil {
                    Image("OMGAgent-\(agent)").renderingMode(.template).resizable().scaledToFit()
                } else {
                    Image(systemName: agent == "terminal" ? "terminal" : "sparkles").resizable().scaledToFit()
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
    private var collapsed: Set<String> = []
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "agent")
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
        collapsed.contains(projects[section].stableKey) ? 0 : projects[section].sessions.count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        36
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        12
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let project = projects[section]
        let isCollapsed = collapsed.contains(project.stableKey)
        let container = UIView()

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "agent.folder.\(project.stableKey)"
        button.contentHorizontalAlignment = .leading
        button.tintColor = .secondaryLabel

        let iconName = isCollapsed ? "folder" : "folder.fill"
        let chevronName = isCollapsed ? "chevron.right" : "chevron.down"
        let folderImage = UIImage(
            systemName: iconName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        let chevronImage = UIImage(
            systemName: chevronName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        )

        let iconView = UIImageView(image: folderImage)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = project.kind == "chats" ? localized("Agent") : project.name
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.lineBreakMode = .byTruncatingTail

        let chevronView = UIImageView(image: chevronImage)
        chevronView.tintColor = .tertiaryLabel
        chevronView.contentMode = .scaleAspectFit

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, chevronView, UIView()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stack)

        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if !collapsed.insert(project.stableKey).inserted {
                collapsed.remove(project.stableKey)
            }
            tableView.reloadSections(IndexSet(integer: section), with: .automatic)
        }, for: .touchUpInside)

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ListCard.headerInset),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ListCard.headerInset),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let sessions = projects[indexPath.section].sessions
        let session = sessions[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "agent", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(
                session: session,
                isCurrent: store.currentSessionKey == session.key,
                showsProject: false,
                isFirst: indexPath.row == 0,
                isLast: indexPath.row == sessions.count - 1
            )
        }
        .margins(.horizontal, ListCard.outerMargin)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        store.openSession(projects[indexPath.section].sessions[indexPath.row])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.deviceEndpoint != nil,
              let sessionID = projects[indexPath.section].sessions[indexPath.row].rosterID
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
        guard store.deviceEndpoint != nil,
              let sessionID = projects[indexPath.section].sessions[indexPath.row].rosterID
        else { return nil }
        let title = projects[indexPath.section].sessions[indexPath.row].title
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: title, children: [
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
