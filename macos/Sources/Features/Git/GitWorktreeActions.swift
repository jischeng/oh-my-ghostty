import AppKit

@MainActor
enum GitWorktreeActions {
    static func creation(start: String?, repository: GitRepositoryIdentity, window: NSWindow?) async -> GitMutation? {
        let alert = NSAlert()
        alert.messageText = "Create Worktree"
        alert.informativeText = "Choose a directory and how to check out \(start ?? "HEAD")."
        let path = NSTextField(string: (repository.worktreePath as NSString).deletingLastPathComponent + "/")
        path.placeholderString = "Absolute worktree directory"
        let branch = NSTextField(string: "")
        branch.placeholderString = "New branch name"
        let mode = NSPopUpButton()
        mode.addItems(withTitles: ["New branch", "Detached HEAD"])
        if start?.hasPrefix("refs/heads/") == true { mode.addItem(withTitle: "Existing branch") }
        let stack = NSStackView(views: [NSTextField(labelWithString: "Directory"), path,
                                       NSTextField(labelWithString: "Checkout"), mode,
                                       NSTextField(labelWithString: "Branch name (for New branch)"), branch])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 170)
        for field in [path, branch] { field.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard await response(alert, window: window) == .alertFirstButtonReturn else { return nil }
        return .addWorktree(path: path.stringValue, start: start ?? "HEAD",
                            branch: mode.indexOfSelectedItem == 0 ? branch.stringValue : nil,
                            detached: mode.indexOfSelectedItem == 1)
    }

    static func removal(_ worktree: GitWorktreeInfo, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove Worktree?"
        alert.informativeText = "Remove \(worktree.path)? Its branch will be kept. Worktrees with uncommitted changes will not be removed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
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
            throw GitDiffServiceError.gitFailed("The source terminal session is no longer available.")
        }
        var configuration = Ghostty.SurfaceConfiguration()
        switch context.session.state {
        case .local:
            configuration.workingDirectory = worktree.path
        case .sshReady(let ssh, _):
            guard let replay = ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID),
                  let executable = Bundle.main.executableURL?.path,
                  let command = replay.command(executablePath: executable, remoteWorkingDirectory: worktree.path) else {
                throw GitDiffServiceError.gitFailed("This SSH session cannot be opened in another tab.")
            }
            configuration.workingDirectory = context.session.local.workingDirectory
            configuration.command = TerminalController.replaySurvivalCommand(command)
        case .sshConnecting:
            throw GitDiffServiceError.gitFailed("Wait for the SSH session to connect.")
        }
        guard EditorPaneDestination.open(in: controller, source: source, destination: .newTab, configuration: configuration) != nil else {
            throw GitDiffServiceError.gitFailed("Could not open a terminal for this worktree.")
        }
    }

}
