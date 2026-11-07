import UIKit

/// Native drill-down: paired desktop -> registered host -> folder.
@MainActor
enum OMGProjectPicker {
    private struct Context {
        let control: OMGControl
        let mac: PairedMac
        let workspace: String
        let store: RosterStore
    }

    static func present(from parent: UIViewController, store: RosterStore) {
        let desktops = CompanionLink.pairedMacs.filter { $0.kind == .omgd }
        let page = OMGChoiceController(title: localized("Add Project"))
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        page.items = desktops.map { mac in
            .init(title: mac.name, subtitle: mac.displayAddress, symbol: "desktopcomputer") {
                guard let endpoint = mac.endpoint else { return }
                let control = OMGControl(endpoint)
                page.perform {
                    let result = try await control.call(["t": "workspaces"])
                    let workspaces = result["workspaces"] as? [[String: String]] ?? []
                    if let id = store.workspaceScope?.selectedID, workspaces.contains(where: { $0["id"] == id }) {
                        try await showHosts(nav, context: Context(control: control, mac: mac, workspace: id, store: store))
                    } else {
                        let chooser = OMGChoiceController(title: localized("Workspaces"))
                        chooser.items = workspaces.map { ws in
                            .init(title: ws["name"] ?? "", subtitle: nil, symbol: "square.grid.2x2") {
                                let context = Context(control: control, mac: mac,
                                                      workspace: ws["id"] ?? "", store: store)
                                chooser.perform { try await showHosts(nav, context: context) }
                            }
                        }
                        nav.pushViewController(chooser, animated: true)
                    }
                }
            }
        }
        if desktops.isEmpty { page.navigationItem.prompt = "Pair an OMG desktop in Settings → Devices first." }
        parent.present(nav, animated: true)
    }

    private static func showHosts(_ nav: UINavigationController, context: Context) async throws {
        let result = try await context.control.call(["t": "hosts"])
        let hosts = result["hosts"] as? [[String: String]] ?? []
        let page = OMGChoiceController(title: context.mac.name)
        page.items = hosts.map { host in
            let id = host["id"] ?? ""
            return .init(title: id == "local" ? localized("Local Machine") : host["name"] ?? id,
                         subtitle: id == "local" ? nil : "SSH", symbol: id == "local" ? "desktopcomputer" : "server.rack") {
                page.perform { try await showDirectory(nav, context: context, host: id, path: "") }
            }
        }
        nav.pushViewController(page, animated: true)
    }

    private static func showDirectory(_ nav: UINavigationController, context: Context,
                                      host: String, path: String) async throws {
        let result = try await context.control.call(["t": "directories", "host": host, "path": path])
        let resolved = result["path"] as? String ?? ""
        let page = OMGChoiceController(title: URL(fileURLWithPath: resolved).lastPathComponent)
        page.navigationItem.prompt = resolved
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(title: localized("Use This Folder"), primaryAction: UIAction { [weak page, weak nav] _ in
            page?.perform {
                _ = try await context.control.call(["t": "addProject", "host": host,
                                                     "path": resolved, "workspace": context.workspace])
                context.store.workspaceScope?.select(context.workspace)
                if CompanionLink.activeMacID != context.mac.id { CompanionLink.setActive(context.mac.id) }
                context.store.chooseDestinationWorkspace(context.workspace)
                context.store.reconnectNow()
                nav?.dismiss(animated: true)
            }
        })
        var names = result["names"] as? [String] ?? []
        if resolved != "/" { names.insert("..", at: 0) }
        page.items = names.map { name in
            .init(title: name == ".." ? "↑ .." : name, subtitle: nil, symbol: "folder") {
                let next = name == ".." ? (result["parent"] as? String ?? "/") :
                    URL(fileURLWithPath: resolved).appendingPathComponent(name).path
                page.perform { try await showDirectory(nav, context: context, host: host, path: next) }
            }
        }
        nav.pushViewController(page, animated: true)
    }
}

final class OMGChoiceController: UITableViewController {
    struct Item {
        let title: String
        let subtitle: String?
        let symbol: String
        let action: () -> Void
    }
    var items: [Item] = []
    private var operation: Task<Void, Never>?
    init(title: String) { super.init(style: .insetGrouped); self.title = title }
    required init?(coder: NSCoder) { fatalError() }
    deinit { operation?.cancel() }
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        tableView.isUserInteractionEnabled = false
        operation = Task { [weak self] in
            defer { self?.operation = nil; self?.tableView.isUserInteractionEnabled = true }
            do { try await work() } catch {
                guard let self, !Task.isCancelled else { return }
                let alert = UIAlertController(title: localized("Couldn't connect"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: localized("OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.subtitle
        cell.imageView?.image = UIImage(systemName: item.symbol)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        items[indexPath.row].action()
    }
}
