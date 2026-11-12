import SwiftUI
import TermioShared
import UIKit

/// The Terminals tab: the Mac's loose shell sessions (the `terminals`-kind
/// container) — the phone twin of the desktop sidebar's Terminals section, and
/// the exact mirror of the Chats tab for shells instead of agents. Loose
/// terminals used to fall through as a project *folder* you had to tap into;
/// promoting them to their own tab keeps a live shell one tap away, the same
/// shape Chats already got. A row goes straight to its terminal. The ＋ opens a
/// new plain shell at `~` — no agent to pick, so (unlike Chats) it carries no
/// per-agent menu.
///
/// Sectioned by workspace, like the Projects list: there is one loose funnel per
/// workspace, so with two machines paired a flat list would show both boxes'
/// shells as one column with nothing saying which is which.
final class TerminalListViewController: UIViewController {
    private let store: RosterStore

    /// The store's loose terminal containers, grouped by workspace in roster
    /// order — one section each.
    private var groups: [WorkspaceGroup] = []
    /// Workspaces whose detached "Background Sessions" drawer is currently expanded.
    private var expandedBackgroundWorkspaces: Set<String> = []

    private let newTerminalButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let emptyState = ListEmptyStateView()
    private var scopeObserver: NSObjectProtocol?
    private var rosterObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    init(store: RosterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.sizeScrollingHeaderToFit()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeObserver = installThemeBackdrop()
        configureNewTerminalButton()
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        configureFab()
        refilter()
        scopeObserver = NotificationCenter.default.addObserver(forName: WorkspaceScope.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
    }

    deinit {
        if let scopeObserver { NotificationCenter.default.removeObserver(scopeObserver) }
        if let rosterObserver {
            NotificationCenter.default.removeObserver(rosterObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    func refresh() {
        tableView.reloadData()
    }

    // MARK: - Top bar (large title)

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = localized("Terminals")
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

    /// The compose ＋ floats in the bottom-right corner as a glass FAB, above the
    /// native tab bar — thumb-reachable and clear of the large title. Added
    /// after the table so it sits above the rows.
    private func configureFab() {
        newTerminalButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newTerminalButton)
        NSLayoutConstraint.activate([
            newTerminalButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            newTerminalButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            newTerminalButton.widthAnchor.constraint(equalToConstant: 52),
            newTerminalButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    /// The compose menu: New Terminal (a plain login shell the Mac gathers into
    /// the loose `.terminals` funnel) and New SSH. Deferred as a whole because
    /// both entries read the live roster — New SSH is a read-only pick from the
    /// Mac's `~/.ssh/config` aliases (the phone never types a host), and New
    /// Terminal names the workspace it will land in.
    private func configureNewTerminalButton() {
        newTerminalButton.applyGlassIcon(.add, boxSize: 24)
        newTerminalButton.accessibilityLabel = localized("New Terminal")
        newTerminalButton.accessibilityIdentifier = "terminals.new"
        newTerminalButton.showsMenuAsPrimaryAction = true
        newTerminalButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenuItems() ?? [])
            },
        ])
    }

    private func composeMenuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(
                title: newTerminalTitle,
                image: HugeIcon.terminal.strokeImage(boxSize: 22)
            ) { [weak self] _ in self?.store.startNewTerminal() },
            sshMenu(),
        ]
        if let destinations = store.destinationPickerMenu() { items.append(destinations) }
        return items
    }

    /// "New Terminal in Alpha" — the destination stated on the action itself, so
    /// starting a shell never means guessing which machine it landed on. Plain
    /// "New Terminal" when there is only one workspace to land in: naming a
    /// choice nobody has is noise.
    private var newTerminalTitle: String {
        guard store.localWorkspaces.count > 1,
              let name = store.destinationWorkspace?.name, !name.isEmpty
        else { return localized("New Terminal") }
        return localized("New Terminal in \(name)")
    }

    /// The "New SSH" submenu: one entry per `~/.ssh/config` host the Mac knows.
    /// Read-only by design — the phone chooses a known alias, it never authors a
    /// host. An empty config shows a disabled hint pointing back to the Mac, so
    /// the item never dead-ends on a tap.
    private func sshMenu() -> UIMenu {
        let icon = UIImage(systemName: "cloud")
        let hosts = store.sshHosts
        guard !hosts.isEmpty else {
            let hint = UIAction(title: localized("Add hosts in ~/.ssh/config on your Mac")) { _ in }
            hint.attributes = .disabled
            return UIMenu(title: localized("New SSH"), image: icon, children: [hint])
        }
        let items = hosts.map { host in
            UIAction(
                title: host.alias,
                subtitle: host.user.isEmpty ? host.hostName : "\(host.user)@\(host.hostName)"
            ) { [weak self] _ in self?.store.startSSH(host: host.alias) }
        }
        return UIMenu(title: localized("New SSH"), image: icon, children: items)
    }

    // MARK: - Table

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(
            WorkspaceSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: WorkspaceSectionHeaderView.reuseID
        )
        tableView.setScrollingHeader(topBar, horizontalInset: 16, top: 8, bottom: 16)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The native tab controller contributes the correct safe-area and
        // adjusted scroll insets for both the classic and Liquid Glass bars.
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func refilter() {
        groups = store.terminalGroups
        // Shown whenever paired: New Terminal is project-less, so it no longer
        // needs an existing terminals container to land in (it seeds the first).
        newTerminalButton.isHidden = store.deviceEndpoint == nil
        tableView.reloadData()
        updateEmptyState()
    }

    /// Every terminal on screen, in section order.
    private var visible: [MockSession] { groups.flatMap(\.sessions) }

    // MARK: - Empty state

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

    /// Link-state nuance lives on the Projects tab (the pairing home); this
    /// zero state only answers "no terminals yet". Whenever paired the ＋ can
    /// seed the first terminal, so it's the next step; only while unpaired (＋
    /// hidden) does the message fall back to pointing at the Mac.
    private func updateEmptyState() {
        emptyState.isHidden = !visible.isEmpty
        guard !emptyState.isHidden else { return }
        let canStart = store.deviceEndpoint != nil
        emptyState.configure(
            icon: .terminal,
            title: localized("No terminals yet"),
            message: canStart
                ? localized("Terminals are plain shells that aren't tied to a project. Start one with ＋, or on your Mac.")
                : localized("Terminals are plain shells that aren't tied to a project. Start one on your Mac and it appears here."),
            actionTitle: nil,
            busy: false
        )
    }
}

// MARK: - Table data source / delegate

extension TerminalListViewController: UITableViewDataSource, UITableViewDelegate {
    private func splitSessions(in section: Int) -> (active: [MockSession], detached: [MockSession]) {
        let all = groups[section].sessions
        let currentKey = store.currentSessionKey
        var active: [MockSession] = []
        var detached: [MockSession] = []
        for session in all {
            if !session.isBackground || session.isMobileCreated || session.key == currentKey {
                active.append(session)
            } else {
                detached.append(session)
            }
        }
        return (active, detached)
    }

    private func isBackgroundExpanded(in section: Int) -> Bool {
        expandedBackgroundWorkspaces.contains(groups[section].id)
    }

    private func backgroundHeaderProject(for group: WorkspaceGroup, detached: [MockSession]) -> MockProject {
        MockProject(
            name: localized("Background Sessions"),
            path: "",
            branch: "\(detached.count)",
            workspaceID: group.id,
            workspaceName: group.name,
            deviceAlias: group.deviceAlias,
            sessions: detached
        )
    }

    private func session(at indexPath: IndexPath) -> MockSession? {
        let (active, detached) = splitSessions(in: indexPath.section)
        if indexPath.row < active.count {
            return active[indexPath.row]
        }
        guard !detached.isEmpty else { return nil }
        if indexPath.row == active.count {
            return nil
        }
        let childIndex = indexPath.row - active.count - 1
        guard detached.indices.contains(childIndex) else { return nil }
        return detached[childIndex]
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let (active, detached) = splitSessions(in: section)
        guard !detached.isEmpty else { return active.count }
        let expandedCount = isBackgroundExpanded(in: section) ? detached.count : 0
        return active.count + 1 + expandedCount
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard groups.namesWorkspaces else { return nil }
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: WorkspaceSectionHeaderView.reuseID
        ) as? WorkspaceSectionHeaderView else { return nil }
        let group = groups[section]
        header.configure(title: group.name, detail: group.machineLabel)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        groups.namesWorkspaces ? WorkspaceSectionHeaderView.height : 0
    }

    /// A whitespace gap below each group — the divider-free separator, matching
    /// the macOS sidebar's spacing-based grouping.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        12
    }

    /// An empty (transparent) footer view, so the gap above is just whitespace.
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let group = groups[indexPath.section]
        let (active, detached) = splitSessions(in: indexPath.section)
        let expanded = isBackgroundExpanded(in: indexPath.section)
        let totalRows = active.count + (detached.isEmpty ? 0 : (1 + (expanded ? detached.count : 0)))

        if indexPath.row < active.count {
            let session = active[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                SessionRow(
                    session: session,
                    isCurrent: session.key == store.currentSessionKey,
                    showsProject: false,
                    isFirst: indexPath.row == 0,
                    isLast: indexPath.row == totalRows - 1
                )
            }
            .margins(.horizontal, ListCard.outerMargin)
            .margins(.vertical, 0)
            return cell
        }

        if indexPath.row == active.count, !detached.isEmpty {
            let headerProject = backgroundHeaderProject(for: group, detached: detached)
            cell.contentConfiguration = UIHostingConfiguration {
                ProjectRow(
                    project: headerProject,
                    isExpanded: expanded,
                    isFirst: active.isEmpty,
                    isLast: !expanded,
                    accessibilityID: "terminals.background.\(group.id)"
                )
            }
            .margins(.horizontal, ListCard.outerMargin)
            .margins(.vertical, 0)
            return cell
        }

        let childIndex = indexPath.row - active.count - 1
        let session = detached[childIndex]
        let isLastChild = childIndex == detached.count - 1
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(
                session: session,
                isCurrent: session.key == store.currentSessionKey,
                showsProject: false,
                isTreeChild: true,
                isLastTreeChild: isLastChild,
                isFirst: false,
                isLast: isLastChild
            )
        }
        .margins(.horizontal, ListCard.outerMargin)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let group = groups[indexPath.section]
        let (active, detached) = splitSessions(in: indexPath.section)
        if !detached.isEmpty, indexPath.row == active.count {
            let nowExpanded = !expandedBackgroundWorkspaces.contains(group.id)
            if nowExpanded {
                expandedBackgroundWorkspaces.insert(group.id)
            } else {
                expandedBackgroundWorkspaces.remove(group.id)
            }
            let headerProject = backgroundHeaderProject(for: group, detached: detached)
            tableView.animateDrawerToggle(
                inSection: indexPath.section,
                headerRow: active.count,
                childCount: detached.count,
                nowExpanded: nowExpanded
            ) { headerCell in
                headerCell.contentConfiguration = UIHostingConfiguration {
                    ProjectRow(
                        project: headerProject,
                        isExpanded: nowExpanded,
                        isFirst: active.isEmpty,
                        isLast: !nowExpanded,
                        accessibilityID: "terminals.background.\(group.id)"
                    )
                }
                .margins(.horizontal, ListCard.outerMargin)
                .margins(.vertical, 0)
            }
            return
        }
        if let session = session(at: indexPath) {
            store.openSession(session)
        }
    }

    /// Trailing swipe: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.deviceEndpoint != nil,
              let sessionID = session(at: indexPath)?.rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: localized("Close")) { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }
}
