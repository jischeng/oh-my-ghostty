import AppKit

@MainActor
enum GitWorktreeActions {
    struct Creation { let mutation: GitMutation; let openAfterCreation: Bool }
    static func creation(start: String?, repository: GitRepositoryIdentity, window: NSWindow?,
                         detached: Bool = false) async -> Creation? {
        let alert = NSAlert()
        alert.messageText = GitL10n.text("Create Worktree")
        alert.informativeText = GitL10n.format("Choose a directory and how to check out {0}.", String(describing: start ?? "HEAD"))
        let path = NSTextField(string: (repository.worktreePath as NSString).deletingLastPathComponent + "/")
        path.placeholderString = GitL10n.text("Absolute worktree directory")
        let branch = NSTextField(string: "")
        branch.placeholderString = GitL10n.text("New branch name")
        let mode = NSPopUpButton()
        mode.addItems(withTitles: [GitL10n.text("New branch"), "Detached HEAD"])
        if start?.hasPrefix("refs/heads/") == true { mode.addItem(withTitle: GitL10n.text("Existing branch")) }
        if detached { mode.selectItem(at: 1); mode.isEnabled = false; branch.isEnabled = false }
        let open = NSButton(checkboxWithTitle: GitL10n.text("Open in a new tab after creation"), target: nil, action: nil)
        open.state = .on
        let stack = NSStackView(views: [NSTextField(labelWithString: "Directory"), path,
                                       NSTextField(labelWithString: GitL10n.text("Checkout")), mode,
                                       NSTextField(labelWithString: GitL10n.text("Branch name (for New branch)")), branch, open])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 196)
        for field in [path, branch] { field.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: GitL10n.text("Create"))
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        guard await response(alert, window: window) == .alertFirstButtonReturn else { return nil }
        return Creation(mutation: .addWorktree(path: path.stringValue, start: start ?? "HEAD",
                            branch: mode.indexOfSelectedItem == 0 ? branch.stringValue : nil,
                            detached: mode.indexOfSelectedItem == 1), openAfterCreation: open.state == .on)
    }

    static func removal(_ worktree: GitWorktreeInfo, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = GitL10n.text("Remove Worktree?")
        alert.informativeText = GitL10n.format("Remove {0}? Its branch will be kept. Worktrees with uncommitted changes will not be removed.", String(describing: worktree.path))
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        return await response(alert, window: window) == .alertFirstButtonReturn
    }

    private static func response(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    static func open(_ worktree: GitWorktreeInfo, repository: GitRepositoryIdentity, context: InspectorPaneContext) throws {
        guard worktree.canOpen, repository.matches(context.session),
              let controller = TerminalController.all.first(where: { $0.tabSessionID == context.tabID }),
              let source = controller.surfaceTree.first(where: { $0.id == context.surfaceID }),
              controller.paneSessionContext(for: source)?.state == context.session.state else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("The source terminal session is no longer available."))
        }
        var configuration = Ghostty.SurfaceConfiguration()
        switch context.session.state {
        case .local:
            configuration.workingDirectory = worktree.path
        case .sshReady(let ssh, _):
            guard let replay = ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID),
                  let executable = Bundle.main.executableURL?.path,
                  let command = replay.command(executablePath: executable, remoteWorkingDirectory: worktree.path) else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("This SSH session cannot be opened in another tab."))
            }
            configuration.workingDirectory = context.session.local.workingDirectory
            configuration.command = TerminalController.replaySurvivalCommand(command)
        case .sshConnecting:
            throw GitDiffServiceError.gitFailed(GitL10n.text("Wait for the SSH session to connect."))
        }
        guard EditorPaneDestination.open(in: controller, source: source, destination: .newTab, configuration: configuration) != nil else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Could not open a terminal for this worktree."))
        }
    }

}

/// File actions use the same editor and terminal destinations as Files.
@MainActor
enum GitFileActions {
    static func absolutePath(_ file: GitDiffFile, repository: GitRepositoryIdentity) throws -> String {
        let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !file.path.isEmpty, !file.path.hasPrefix("/"), !file.path.contains("\0"),
              !components.contains(".."), !components.contains("."), !components.contains("") else {
            throw GitDiffServiceError.invalidPath(file.path)
        }
        return (repository.worktreePath as NSString).appendingPathComponent(file.path)
    }

    static func open(_ file: GitDiffFile, repository: GitRepositoryIdentity,
                     context: InspectorPaneContext, directory: Bool) throws {
        guard repository.matches(context.session) else {
            throw GitDiffServiceError.gitFailed("The source terminal session is no longer available.")
        }
        let path = try absolutePath(file, repository: repository)
        if directory {
            try GitWorktreeActions.open(GitWorktreeInfo(path: (path as NSString).deletingLastPathComponent,
                head: nil, branchRef: nil, isMain: false, isCurrent: false), repository: repository, context: context)
        } else {
            EditorWorkspaceStore.shared.open(path: path, context: context, destination: .currentPane)
        }
    }
}
