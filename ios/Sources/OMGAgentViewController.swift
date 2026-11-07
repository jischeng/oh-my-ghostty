import SwiftUI
import TermioShared
import UIKit

/// Reads the desktop's normalized history while input continues through the
/// same live PTY and its writer grant. Terminal remains available for TUI prompts.
final class OMGAgentViewController: UIViewController, UITableViewDataSource {
    var onBack: (() -> Void)?
    var onTerminal: (() -> Void)?
    private let endpoint: DeviceEndpoint
    private let agentSession: MockSession
    private let transport: OMGSession
    private let control: OMGControl
    private let table = UITableView(frame: .zero, style: .plain)
    private let input = UITextView()
    private let stateLabel = UILabel()
    private let titleLabel = UILabel()
    private let placeholder = UILabel()
    private let send = UIButton(type: .system)
    private var messages: [[String: String]] = []
    private var refreshTask: Task<Void, Never>?
    private var rendering = false
    private var fingerprint = ""

    init(endpoint: DeviceEndpoint, session: MockSession) {
        self.endpoint = endpoint
        self.agentSession = session
        self.transport = OMGSession(endpoint: endpoint, sessionID: session.rosterID ?? "")
        self.control = OMGControl(endpoint)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { refreshTask?.cancel(); transport.stop() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "agent.conversation"
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.accessibilityIdentifier = "agent.back"
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        let mark = UIImageView(image: UIImage(named: "OMGAgent-\(agentSession.agent.id)") ??
                                UIImage(systemName: "cpu"))
        mark.tintColor = .label
        mark.contentMode = .scaleAspectFit
        mark.widthAnchor.constraint(equalToConstant: 28).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 28).isActive = true
        titleLabel.text = agentSession.title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "agent.title"
        let terminal = UIButton(type: .system)
        terminal.setImage(UIImage(systemName: "terminal"), for: .normal)
        terminal.accessibilityLabel = localized("Terminal")
        terminal.accessibilityIdentifier = "agent.terminal"
        terminal.addAction(UIAction { [weak self] _ in
            self?.setRuntimeRendering(false)
            self?.onTerminal?()
        }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [back, mark, titleLabel, terminal])
        header.spacing = 12
        header.alignment = .center
        stateLabel.font = .preferredFont(forTextStyle: .caption1)
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 3
        stateLabel.accessibilityIdentifier = "agent.connection"
        table.dataSource = self
        table.separatorStyle = .none
        table.keyboardDismissMode = .interactive
        table.backgroundColor = .clear
        table.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        input.font = .preferredFont(forTextStyle: .body)
        input.backgroundColor = .secondarySystemBackground
        input.layer.cornerRadius = 18
        input.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        input.accessibilityIdentifier = "agent.composer"
        input.accessibilityLabel = localized("Message")
        input.autocorrectionType = .no
        placeholder.text = localized("Message \(agentSession.agent.name)")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 15),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: input.trailingAnchor, constant: -12),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 12),
        ])
        input.delegate = self
        send.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        send.setPreferredSymbolConfiguration(.init(pointSize: 34), forImageIn: .normal)
        send.accessibilityLabel = localized("Send")
        send.accessibilityIdentifier = "agent.send"
        send.isEnabled = false
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setImage(UIImage(systemName: "stop.circle"), for: .normal)
        cancel.accessibilityLabel = localized("Interrupt")
        cancel.addAction(UIAction { [weak self] _ in self?.transport.send(Data([3])) }, for: .touchUpInside)
        let composer = UIStackView(arrangedSubviews: [input, cancel, send])
        composer.spacing = 8
        composer.alignment = .bottom
        for item in [header, stateLabel, table, composer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 44),
            back.widthAnchor.constraint(equalToConstant: 36),
            terminal.widthAnchor.constraint(equalToConstant: 44),
            stateLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            stateLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            table.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            input.heightAnchor.constraint(equalToConstant: 82),
            cancel.widthAnchor.constraint(equalToConstant: 36),
            send.widthAnchor.constraint(equalToConstant: 44),
        ])
        transport.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected, .readOnly: send.isEnabled = true
            default: send.isEnabled = false
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setRuntimeRendering(true)
    }

    func setRuntimeRendering(_ showing: Bool) {
        guard rendering != showing else { return }
        rendering = showing
        if !showing {
            refreshTask?.cancel()
            refreshTask = nil
            transport.stop()
            input.resignFirstResponder()
            return
        }
        loadViewIfNeeded()
        transport.start()
        // A conversation page observes the existing PTY grid without resizing it.
        transport.setRendering(false)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        do {
            let response = try await control.call(["t": "transcript", "session": agentSession.rosterID ?? ""])
            guard !Task.isCancelled else { return }
            stateLabel.text = response["available"] as? Bool == true
                ? (response["truncated"] as? Bool == true
                    ? localized("Earlier messages omitted") : agentSession.agent.name)
                : localized("Conversation history is not available yet. Continue in Terminal.")
            if let title = response["title"] as? String, !title.isEmpty {
                titleLabel.text = title
            }
            let next = response["messages"] as? [[String: String]] ?? []
            let key = next.map { ($0["id"] ?? "") + ($0["text"] ?? "") }.joined()
            guard key != fingerprint else { return }
            let atBottom = table.contentOffset.y + table.bounds.height >= table.contentSize.height - 80
            fingerprint = key
            messages = next
            table.reloadData()
            if atBottom, !messages.isEmpty {
                table.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false)
            }
        } catch {
            if !Task.isCancelled { stateLabel.text = error.localizedDescription }
        }
    }

    private func submit() {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard send.isEnabled, !text.isEmpty, text.utf8.count <= 128 * 1024 else { return }
        transport.sendInput(.paste(text))
        transport.send(Data([13]))
        input.text = ""
        placeholder.isHidden = false
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = messages[indexPath.row]
        let user = message["role"] == "user"
        let text = message["text"] ?? ""
        let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentConfiguration = UIHostingConfiguration {
            HStack(alignment: .top, spacing: 10) {
                if !user {
                    OMGAgentMark(agent: agentSession.agent.id, status: .idle)
                        .frame(width: 28, height: 28)
                }
                if user { Spacer(minLength: 36) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(user ? localized("You") : agentSession.agent.name).font(.caption).foregroundStyle(.secondary)
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                        .font(.body).textSelection(.enabled)
                }
                .padding(14)
                .background(user ? Color(uiColor: .secondarySystemBackground) : .clear, in: RoundedRectangle(cornerRadius: 18))
                if !user { Spacer(minLength: 8) }
            }.padding(.vertical, 8)
        }.margins(.horizontal, 16)
        return cell
    }
}

extension OMGAgentViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
    }
}
