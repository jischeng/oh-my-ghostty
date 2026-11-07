import UIKit
import SwiftUI

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: ConnectController())
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class ConnectController: UIViewController {
    private let address = UITextField()
    private let secret = UITextField()
    private let status = UILabel()
    private var catalogue: WebSocketLink?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OMG"
        view.backgroundColor = .systemBackground
        address.placeholder = "Mac 地址，例如 192.168.1.10:8791"
        address.text = PairingStore.address
        address.keyboardType = .URL
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        secret.placeholder = "配对密钥"
        secret.text = PairingStore.token
        secret.isSecureTextEntry = true
        secret.autocorrectionType = .no
        secret.autocapitalizationType = .none
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-test-server"), arguments.indices.contains(index + 1) {
            address.text = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--ui-test-token"), arguments.indices.contains(index + 1) {
            secret.text = arguments[index + 1]
        }
        #endif
        for field in [address, secret] {
            field.borderStyle = .roundedRect
            field.heightAnchor.constraint(equalToConstant: 48).isActive = true
            field.accessibilityIdentifier = field === address ? "connection.address" : "connection.token"
        }
        let description = UILabel()
        description.text = "连接同一 Wi-Fi 下的 Mac，继续使用正在运行的终端。"
        description.numberOfLines = 0
        description.textColor = .secondaryLabel
        let button = UIButton(type: .system)
        button.configuration = .filled()
        button.setTitle("连接 Mac", for: .normal)
        button.accessibilityIdentifier = "connection.connect"
        button.addTarget(self, action: #selector(connect), for: .touchUpInside)
        status.numberOfLines = 0
        status.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [description, address, secret, button, status])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    @objc private func connect() {
        view.endEditing(true)
        let value = (address.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (secret.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "ws://\(value)"),
              let scheme = url.scheme, ["ws", "wss"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            status.text = "请输入 Mac 的地址和端口。"
            return
        }
        guard token.count >= 32, token.count <= 256,
              token.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) })
        else { status.text = "配对密钥应为 32–256 位字母或数字。"; return }
        do { try PairingStore.save(token: token) } catch { status.text = "无法保存配对密钥：\(error.localizedDescription)"; return }
        PairingStore.address = value
        catalogue?.stop()
        var config = WebSocketLink.Configuration(name: "catalogue", url: url.appendingPathComponent("catalogue"))
        config.delegateQueue = .main
        config.subprotocols = ["omg.\(token)"]
        let link = WebSocketLink(configuration: config)
        catalogue = link
        status.text = "正在连接…"
        link.onDown = { [weak self] in self?.status.text = "无法连接。请检查 Mac 地址、密钥和本地网络权限，正在重试…" }
        link.onText = { [weak self, weak link] text in
            guard let self else { return }
            do {
                struct Catalogue: Decodable { let endpoints: [MobileEndpoint] }
                let endpoints = try JSONDecoder().decode(Catalogue.self, from: Data(text.utf8)).endpoints
                link?.stop()
                status.text = endpoints.isEmpty ? "Mac 上暂无运行中的本地 runtime。" : nil
                if !endpoints.isEmpty {
                    navigationController?.pushViewController(SessionListController(base: url, token: token, endpoints: endpoints), animated: true)
                }
            } catch { status.text = "无法读取会话列表：\(error.localizedDescription)"; link?.stop() }
        }
        link.start()
    }
}

final class SessionListController: UITableViewController {
    private let connections: [RuntimeConnection]
    private var sessions: [[MobileSession]]
    private var statuses: [String]

    init(base: URL, token: String, endpoints: [MobileEndpoint]) {
        connections = endpoints.map { RuntimeConnection(base: base, token: token, endpoint: $0) }
        sessions = endpoints.map { _ in [] }
        statuses = endpoints.map { _ in "正在连接…" }
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "终端会话"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        for (index, connection) in connections.enumerated() {
            connection.onSessions = { [weak self, weak connection] values in
                self?.sessions[index] = values.filter { $0.ended == nil }
                self?.statuses[index] = values.allSatisfy { $0.ended != nil } ? "暂无运行中的会话" : ""
                self?.tableView.reloadData()
                self?.refreshControl?.endRefreshing()
                if connection?.hasSession == false { connection?.stop() }
            }
            connection.onStatus = { [weak self] status in
                self?.statuses[index] = status
                if self?.navigationController?.topViewController === self { self?.tableView.reloadData() }
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        connections.forEach { $0.detach(); $0.refresh() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { connections.forEach { $0.stop() } }
    }
    @objc private func refresh() { connections.forEach { $0.refresh() } }
    override func numberOfSections(in tableView: UITableView) -> Int { connections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, sessions[section].count) }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String { connections[section].endpoint.name }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard !sessions[indexPath.section].isEmpty else {
            cell.textLabel?.text = statuses[indexPath.section]
            cell.selectionStyle = .none
            return cell
        }
        let session = sessions[indexPath.section][indexPath.row]
        cell.accessibilityIdentifier = "session.\(session.id)"
        cell.textLabel?.text = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "终端"
        cell.detailTextLabel?.text = "\(session.cwd ?? "") · PID \(session.pid.map(String.init) ?? "?")"
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !sessions[indexPath.section].isEmpty else { return }
        let session = sessions[indexPath.section][indexPath.row]
        let connection = connections[indexPath.section]
        let controller = TerminalController(connection: connection)
        controller.title = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "终端"
        navigationController?.pushViewController(controller, animated: true)
        connection.open(session)
    }
}

final class TerminalController: UIViewController {
    private let connection: RuntimeConnection
    private let scroll = UIScrollView()
    private let status = UILabel()
    private let header = UIStackView()
    private let agentHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var renderedAgentActivity: MobileAgentActivity?
    private let terminal: StreamTerminalView
    private var viewport: TerminalGrid?
    private var wasWriter = false
    private var control = false
    private var option = false
    private var previousStatusObserver: ((String) -> Void)?

    init(connection: RuntimeConnection) {
        self.connection = connection
        terminal = StreamTerminalView(appearance: .init(fontFamily: "Menlo", fallbackFamilies: [],
            fontSize: 12, paddingX: 8, paddingY: 8, backgroundOpacity: 1))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = .systemBackground
        navigationItem.standardAppearance = navigation
        navigationItem.scrollEdgeAppearance = navigation
        navigationItem.compactAppearance = navigation
        navigationItem.compactScrollEdgeAppearance = navigation
        status.textColor = .secondaryLabel
        status.backgroundColor = .secondarySystemBackground
        status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 2
        status.text = "正在恢复终端…"
        status.accessibilityIdentifier = "terminal.status"
        addChild(agentHost)
        agentHost.view.backgroundColor = .clear
        agentHost.view.isHidden = true
        agentHost.sizingOptions = .intrinsicContentSize
        header.axis = .vertical
        header.addArrangedSubview(agentHost.view)
        header.addArrangedSubview(status)
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.accessibilityIdentifier = "terminal.viewport"
        scroll.bounces = false
        scroll.alwaysBounceHorizontal = false
        // Termio's terminal owns vertical scrollback; this container pans the
        // shared desktop grid horizontally without changing the PTY.
        scroll.addSubview(terminal)
        view.addSubview(header)
        agentHost.didMove(toParent: self)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 40),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "接管", style: .plain, target: self, action: #selector(claim))
        terminal.terminal = { [weak connection] in connection?.terminal }
        terminal.sendInput = { [weak self] event in self?.connection.input(event) }
        terminal.onPaste = { [weak self] in
            if let text = UIPasteboard.general.string { self?.connection.input(.paste(text)) }
        }
        terminal.onPasteMenuRequested = { [weak self] _ in
            guard let self else { return }
            let menu = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
            if let text = connection.terminal?.selectedText {
                menu.addAction(UIAlertAction(title: "复制", style: .default) { _ in UIPasteboard.general.string = text })
            }
            menu.addAction(UIAlertAction(title: "选择全部", style: .default) { [weak self] _ in
                self?.connection.terminal?.selectAll()
            })
            menu.addAction(UIAlertAction(title: "粘贴", style: .default) { [weak self] _ in
                if let text = UIPasteboard.general.string { self?.connection.input(.paste(text)) }
            })
            menu.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(menu, animated: true)
        }
        terminal.onPinch = { [weak self] size in
            guard let self, var appearance = terminal.appearance else { return }
            appearance.fontSize = min(24, max(8, size))
            terminal.setAppearance(appearance)
            view.setNeedsLayout()
        }
        terminal.inputAccessory = accessory()
        previousStatusObserver = connection.onStatus
        connection.onStatus = { [weak self] in self?.status.text = $0 }
        connection.onChange = { [weak self] in self?.changed() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let cell = terminal.cellSize else { return }
        viewport = TerminalGrid.fitting(scroll.bounds.size, cell: cell, paddingX: 8, paddingY: 8)
        let grid = connection.terminal?.grid
        let width = max(scroll.bounds.width, CGFloat(grid?.cols ?? 1) * cell.width + 16)
        let height = max(scroll.bounds.height, CGFloat(grid?.rows ?? 1) * cell.height + 16)
        terminal.frame = CGRect(x: 0, y: 0, width: width, height: height)
        scroll.contentSize = terminal.frame.size
        if !scroll.isDragging && !scroll.isDecelerating, scroll.bounds.height > 0,
           let cursor = terminal.cursorRect {
            // A desktop grid can have many blank rows below its cursor.
            // Follow the cursor's context, not the bottom of that larger grid.
            let top = max(0, cursor.maxY - scroll.bounds.height + 8)
            scroll.scrollRectToVisible(CGRect(x: cursor.minX, y: top,
                width: cursor.width, height: scroll.bounds.height), animated: false)
        }
        if connection.isWriter, let viewport { connection.resize(viewport) }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            connection.detach()
            connection.onChange = nil
            connection.onStatus = previousStatusObserver
        }
    }
    @objc private func claim() {
        connection.claim()
        terminal.becomeFirstResponder()
    }
    private func changed() {
        if renderedAgentActivity != connection.agentState.activity {
            renderedAgentActivity = connection.agentState.activity
            if let activity = renderedAgentActivity {
                agentHost.rootView = AnyView(AgentActivityView(activity: activity))
                agentHost.view.isHidden = false
            } else {
                agentHost.view.isHidden = true
                agentHost.rootView = AnyView(EmptyView())
            }
            agentHost.view.invalidateIntrinsicContentSize()
        }
        navigationItem.rightBarButtonItem?.title = connection.isWriter ? "已接管" : "接管"
        if connection.isWriter && !wasWriter, let viewport { connection.resize(viewport) }
        wasWriter = connection.isWriter
        view.setNeedsLayout()
    }
    private func accessory() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 46), inputViewStyle: .keyboard)
        bar.backgroundColor = .secondarySystemBackground
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4)])
        let keys = [("esc", "escape"), ("tab", "tab"), ("ctrl", ""), ("alt", ""),
                    ("←", "arrow_left"), ("↓", "arrow_down"), ("↑", "arrow_up"), ("→", "arrow_right")]
        for (label, key) in keys {
            if label == "ctrl" || label == "alt" {
                let button = UIButton(type: .system)
                button.setTitle(label, for: .normal)
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let self else { return }
                    if label == "ctrl" { control.toggle() } else { option.toggle() }
                    button?.backgroundColor = (label == "ctrl" ? control : option) ? .systemGray3 : .clear
                    terminal.stickyMods = (control ? 2 : 0) | (option ? 4 : 0)
                }, for: .touchUpInside)
                stack.addArrangedSubview(button)
                continue
            }
            let button = RepeatingKeyButton(frame: .zero)
            button.setTitle(label, for: .normal)
            button.setTitleColor(.label, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            button.onFire = { [weak self, weak stack] in
                guard let self else { return }
                connection.input(.key(.init(key: key, mods: terminal.stickyMods)))
                control = false
                option = false
                for case let button as UIButton in stack?.arrangedSubviews ?? [] { button.backgroundColor = .clear }
                terminal.stickyMods = (control ? 2 : 0) | (option ? 4 : 0)
            }
            stack.addArrangedSubview(button)
        }
        terminal.onStickyConsumed = { [weak self, weak stack] in
            self?.control = false
            self?.option = false
            for case let button as UIButton in stack?.arrangedSubviews ?? [] { button.backgroundColor = .clear }
        }
        return bar
    }
}
