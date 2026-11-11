import AppKit
import SwiftUI

struct GitHistoryScopePicker: NSViewRepresentable {
    let title: String
    let branches: [GitBranchInfo]
    let enabled: Bool
    var isActive = true
    var isBusy = false
    var worktrees: [GitWorktreeInfo] = []
    var worktreesError: String?
    var state: GitCollectionState?
    var stateKey = "history-refs"
    var selectedID: String?
    var tags: [GitRefDecoration] = []
    var repository: GitRepositoryIdentity?
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors
    var nativeColors: GitCollectionColors { colors }

    final class Control: NSButton, NSPopoverDelegate {
        private let chevron = NSImageView()
        fileprivate var content: GitHistoryScopePicker?
        private(set) var popover: NSPopover?
        private var host: GitHistoryScopePopoverController?
        private weak var responderBeforePopover: NSResponder?
        override init(frame: NSRect) {
            super.init(frame: frame)
            cell = GitScopeButtonCell()
            font = .systemFont(ofSize: 11, weight: .medium)
            alignment = .left
            isBordered = false
            imagePosition = .imageLeft
            cell?.lineBreakMode = .byTruncatingMiddle
            chevron.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            addSubview(chevron)
            wantsLayer = true
            layer?.cornerRadius = 4
            target = self
            action = #selector(showPicker)
            setAccessibilityLabel(GitL10n.text("Choose history branch or worktree"))
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(_ content: GitHistoryScopePicker) {
            self.content = content
            isEnabled = content.enabled && !content.isBusy
            if !isEnabled { popover?.performClose(nil) }
            host?.updateContent(content)
            if title != content.title { title = content.title }
            toolTip = content.title
            contentTintColor = content.colors.text
            let selected = content.selectedID ?? "scope:allBranches"
            let symbol = selected.hasPrefix("refs/tags/") ? "tag" : selected.hasPrefix("refs/remotes/") ? "network"
                : selected.hasPrefix("worktree:") ? "folder" : selected == "scope:allBranches" ? "square.stack.3d.up" : "arrow.triangle.branch"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            chevron.contentTintColor = content.colors.secondary
            layer?.backgroundColor = (selected == "scope:allBranches" ? content.colors.hover : content.colors.accent.withAlphaComponent(0.09)).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = content.colors.separator.cgColor
            setAccessibilityValue(content.title)
        }
        private func browser(_ content: GitHistoryScopePicker) -> GitHistoryScopePopoverController {
            GitHistoryScopePopoverController(content: content) { [weak self] in
                self?.popover?.performClose(nil)
            }
        }
        @objc func showPicker() {
            guard isEnabled, window != nil, let snapshot = content else { return }
            if popover?.isShown == true { popover?.performClose(nil); return }
            responderBeforePopover = window?.firstResponder
            let host = browser(snapshot)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            host.bindTheme(to: window)
            popover.contentViewController = host
            popover.contentSize = host.preferredContentSize
            self.host = host
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
        }
        func popoverDidClose(_ notification: Notification) {
            host?.saveAnchor()
            if let window {
                if let view = responderBeforePopover as? NSView, view.window === window {
                    window.makeFirstResponder(view)
                } else if self.window != nil {
                    window.makeFirstResponder(self)
                }
            }
            responderBeforePopover = nil
            popover = nil
            host = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { popover?.performClose(nil) }
        }
        override func layout() {
            super.layout()
            chevron.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
        }
    }
    func makeNSView(context: Context) -> Control { Control() }
    func updateNSView(_ view: Control, context: Context) {
        view.configure(self)
        view.isHidden = !isActive
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 28)
    }
}

struct GitHistoryBranchFavorites {
    struct Entry: Codable, Equatable {
        var target: String
        var identity: String
        var commonGitDir: String
        var refs: [String]
    }

    private struct Store: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    private let defaults: UserDefaults
    private let target: String
    private let identity: String
    private let sshConnection: GitSSHConnection?
    private let commonGitDir: String
    private static let defaultsKey = "git.history.favoriteBranches.v2"
    /// Legacy dictionaries used NUL-separated composite keys (`local\0<gitDir>`
    /// and `ssh\0<connection.identity>\0<gitDir>`). Binary property lists keep
    /// NUL bytes intact, while some serialized representations strip them.
    private static let legacyDefaultsKey = "git.history.favoriteBranches"

    init(repository: GitRepositoryIdentity, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        switch repository.target {
        case .local:
            target = "local"
            identity = ""
            sshConnection = nil
        case .ssh(let connection):
            target = "ssh"
            identity = Self.sshRepositoryIdentity(connection)
            sshConnection = connection
        }
        commonGitDir = repository.commonGitDirPath
    }

    var refs: Set<String> {
        var store = load()
        let matching = store.entries.filter(matches)
        if !matching.isEmpty {
            let merged = Set(matching.flatMap(\.refs))
            if matching.count > 1 || matching.first?.identity != identity {
                store.entries.removeAll(where: matches)
                if !merged.isEmpty {
                    store.entries.append(.init(target: target, identity: identity,
                                               commonGitDir: commonGitDir, refs: merged.sorted()))
                }
                save(store)
            }
            return merged
        }
        guard let migrated = legacyRefs else { return [] }
        store.entries.append(.init(target: target, identity: identity,
                                   commonGitDir: commonGitDir, refs: migrated))
        save(store)
        return Set(migrated)
    }

    func toggle(_ ref: String) {
        guard ref == "HEAD" || ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/") ||
                ref.hasPrefix("worktree:") else { return }
        var values = refs
        if !values.insert(ref).inserted { values.remove(ref) }
        var store = load()
        store.entries.removeAll(where: matches)
        if !values.isEmpty {
            store.entries.append(.init(target: target, identity: identity,
                                       commonGitDir: commonGitDir, refs: values.sorted()))
        }
        save(store)
    }

    /// Worktrees are favorited by their exact path so a favorite survives
    /// branch renames and detached HEAD states.
    static func worktreeID(path: String) -> String { "worktree:" + path }

    private static func sshRepositoryIdentity(_ connection: GitSSHConnection) -> String {
        ([connection.destination] + connection.options).joined(separator: "\0")
    }

    private static func legacySSHIdentityMatches(_ candidate: String, connection: GitSSHConnection) -> Bool {
        let parts = candidate.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0] == connection.destination else { return false }
        return Array(parts.dropFirst(4)) == connection.options
    }

    private func matches(_ entry: Entry) -> Bool {
        guard entry.target == target, entry.commonGitDir == commonGitDir else { return false }
        if entry.identity == identity { return true }
        guard let sshConnection else { return false }
        return Self.legacySSHIdentityMatches(entry.identity, connection: sshConnection)
    }

    private func load() -> Store {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return Store()
        }
        return store
    }

    private func save(_ store: Store) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Reads the legacy `[repositoryKey: [String]]` dictionary, supporting both
    /// preserved NUL-separated keys and stripped keys, and coalescing SSH keys
    /// that only differed by local CWD or local ssh executable path.
    private var legacyRefs: [String]? {
        let repositories = defaults.dictionary(forKey: Self.legacyDefaultsKey) ?? [:]
        guard !repositories.isEmpty else { return nil }
        var merged = Set<String>()
        if let sshConnection {
            let legacyFull = (["ssh", sshConnection.identity, commonGitDir]).joined(separator: "\0")
            let legacyStripped = "ssh" + sshConnection.identity.replacingOccurrences(of: "\0", with: "") + commonGitDir
            let normalizedStripped = "ssh" + identity.replacingOccurrences(of: "\0", with: "") + commonGitDir
            for key in [legacyFull, legacyStripped, normalizedStripped] {
                if let values = repositories[key] as? [String] { merged.formUnion(values) }
            }
            for (key, rawValues) in repositories {
                guard let values = rawValues as? [String] else { continue }
                let parts = key.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 6, parts[0] == "ssh", parts[1] == sshConnection.destination,
                      parts.last == commonGitDir,
                      Array(parts[5..<(parts.count - 1)]) == sshConnection.options else { continue }
                merged.formUnion(values)
            }
        } else {
            for key in ["local\0" + commonGitDir, "local" + commonGitDir] {
                if let values = repositories[key] as? [String] { merged.formUnion(values) }
            }
        }
        guard !merged.isEmpty else { return nil }
        return merged.sorted()
    }
}
