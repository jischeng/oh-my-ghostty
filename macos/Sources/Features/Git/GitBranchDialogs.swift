import AppKit

@MainActor
enum GitBranchDialogs {
    static func mutation(for operation: GitBranchOperation, branch: GitBranchInfo,
                         branches: [GitBranchInfo], repository: GitRepositoryIdentity,
                         window: NSWindow?) async throws -> GitMutation? {
        if operation == .checkout && !branch.isRemote { return .checkout(branch.name) }
        let alert = NSAlert()
        let field = NSTextField(string: branch.name)
        let popup = NSPopUpButton()
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let remotes: [String]
        switch operation {
        case .checkout, .create:
            alert.messageText = GitL10n.text("Create and Switch Branch")
            alert.informativeText = GitL10n.format("Starting from {0}. Enter the new local branch name.", String(describing: branch.name))
            if branch.isRemote {
                let names = try await GitMutationService().remotes(in: repository)
                let remote = names.sorted { $0.count > $1.count }.first { branch.name.hasPrefix($0 + "/") }
                field.stringValue = remote.map { String(branch.name.dropFirst($0.count + 1)) } ?? branch.name
            } else { field.stringValue = "" }
            field.placeholderString = "feature/new-branch"
            alert.accessoryView = field
            alert.addButton(withTitle: GitL10n.text("Create and Switch"))
            remotes = []
        case .push:
            remotes = try await GitMutationService().remotes(in: repository)
            guard !remotes.isEmpty else { throw GitDiffServiceError.gitFailed(GitL10n.text("No Git remotes configured.")) }
            popup.addItems(withTitles: remotes)
            if let upstreamRemote = remotes.first(where: { branch.upstream.hasPrefix($0 + "/") }) {
                popup.selectItem(withTitle: upstreamRemote)
            } else if remotes.contains("origin") { popup.selectItem(withTitle: "origin") }
            if let remote = popup.titleOfSelectedItem, branch.upstream.hasPrefix(remote + "/") {
                field.stringValue = String(branch.upstream.dropFirst(remote.count + 1))
            } else { field.stringValue = branch.name }
            alert.messageText = GitL10n.format("Push {0}", String(describing: branch.name))
            alert.informativeText = GitL10n.text("Choose the remote and destination branch. This uses a normal push; Git will reject non-fast-forward updates.")
            let stack = NSStackView(views: [NSTextField(labelWithString: "Remote"), popup,
                                           NSTextField(labelWithString: GitL10n.text("Destination branch")), field])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 110)
            alert.accessoryView = stack
            alert.addButton(withTitle: GitL10n.text("Push"))
        case .setUpstream:
            remotes = branches.filter(\.isRemote).map(\.id)
            guard !remotes.isEmpty else { throw GitDiffServiceError.gitFailed(GitL10n.text("No remote branches available. Fetch remote refs first.")) }
            popup.addItems(withTitles: remotes.map { String($0.dropFirst("refs/remotes/".count)) })
            popup.selectItem(withTitle: branch.upstream)
            popup.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
            alert.messageText = GitL10n.format("Set Upstream for {0}", String(describing: branch.name))
            alert.informativeText = GitL10n.text("Select the remote branch to track.")
            alert.accessoryView = popup
            alert.addButton(withTitle: GitL10n.text("Set Upstream"))
        }
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        switch operation {
        case .checkout, .create:
            return .create(name: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), start: branch.id)
        case .push:
            guard let remote = popup.titleOfSelectedItem else { return nil }
            return .push(branch: branch.name, remote: remote,
                         destination: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .setUpstream:
            guard remotes.indices.contains(popup.indexOfSelectedItem) else { return nil }
            return .setUpstream(branch: branch.name, upstream: remotes[popup.indexOfSelectedItem])
        }
    }
}
