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
                    Image(systemName: agent == "terminal" ? "terminal" : "cpu").resizable().scaledToFit()
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

/// Folder headers and indented sessions follow the supplied Codex mobile layout.
final class OMGAgentListViewController: UITableViewController {
    private let store: RosterStore
    private var projects: [MockProject] = []
    private var collapsed: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init(store: RosterStore) {
        self.store = store
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.separatorStyle = .none
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "agent")
        let heading = UILabel()
        heading.text = "Agent"
        heading.font = .systemFont(ofSize: 34, weight: .bold)
        heading.frame = CGRect(x: 20, y: 12, width: 280, height: 54)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 82))
        header.addSubview(heading)
        tableView.tableHeaderView = header
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
        tableView.reloadData()
        var config = UIContentUnavailableConfiguration.empty()
        config.text = localized("No chats yet")
        contentUnavailableConfiguration = projects.isEmpty ? config : nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int { projects.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        collapsed.contains(projects[section].stableKey) ? 0 : projects[section].sessions.count
    }
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 58 }
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let project = projects[section]
        let header = UIStackView()
        header.alignment = .center
        header.spacing = 8
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 4, left: 20, bottom: 4, right: 16)
        let folder = UIButton(type: .system)
        folder.setImage(UIImage(systemName: collapsed.contains(project.stableKey) ? "folder" : "folder"), for: .normal)
        folder.setTitle("  \(project.kind == "chats" ? "Agent" : project.name)", for: .normal)
        folder.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        folder.tintColor = .label
        folder.contentHorizontalAlignment = .leading
        folder.accessibilityIdentifier = "agent.folder.\(project.stableKey)"
        folder.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if !collapsed.insert(project.stableKey).inserted { collapsed.remove(project.stableKey) }
            tableView.reloadSections(IndexSet(integer: section), with: .automatic)
        }, for: .touchUpInside)
        let add = UIButton(type: .system)
        add.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
        add.accessibilityLabel = localized("New Chat")
        add.showsMenuAsPrimaryAction = true
        add.menu = UIMenu(children: store.newSessionActions(in: project))
        header.addArrangedSubview(folder)
        header.addArrangedSubview(add)
        add.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return header
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let session = projects[indexPath.section].sessions[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "agent", for: indexPath)
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(session: session, isCurrent: store.currentSessionKey == session.key)
                .padding(.leading, 24)
        }.margins(.all, 0)
        cell.backgroundColor = .clear
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        store.openSession(projects[indexPath.section].sessions[indexPath.row])
    }
}
