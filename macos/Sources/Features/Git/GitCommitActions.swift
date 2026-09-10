import AppKit

enum GitCommitOperation: String, CaseIterable, Equatable, Sendable {
    case createBranch, createWorktree, detachedWorktree, details, compareWithHead, cherryPick, revert
    var title: String {
        switch self {
        case .createBranch: GitL10n.text("Create Branch from This Commit…")
        case .createWorktree: GitL10n.text("Create Branch + Worktree…")
        case .detachedWorktree: GitL10n.text("Create Detached Worktree…")
        case .details: GitL10n.text("Show Commit Details / Changed Files")
        case .compareWithHead: GitL10n.text("Compare with HEAD")
        case .cherryPick: GitL10n.text("Cherry-pick…")
        case .revert: GitL10n.text("Revert…")
        }
    }
    var modifiesRepository: Bool { self != .details && self != .compareWithHead }
}

@MainActor
enum GitCommitActions {
    static func mutation(_ operation: GitCommitOperation, commit: GitHistoryCommit, window: NSWindow?) async -> GitMutation? {
        let alert = NSAlert()
        let field = NSTextField(string: "")
        let parent = NSPopUpButton()
        switch operation {
        case .createBranch:
            alert.messageText = GitL10n.text("Create Branch")
            alert.informativeText = GitL10n.format("Create a branch at {0}. The current branch will stay checked out.", String(describing: commit.id.shortSHA))
            field.placeholderString = "feature/new-branch"
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: GitL10n.text("Create Branch"))
        case .cherryPick, .revert:
            let verb = operation == .cherryPick ? GitL10n.text("Cherry-pick") : GitL10n.text("Revert")
            alert.messageText = GitL10n.format("{0} {1}?", String(describing: verb), String(describing: commit.id.shortSHA))
            alert.informativeText = GitL10n.format("{0}\n\nThis creates a commit on the current branch.", String(describing: commit.subject))
            if commit.parentIDs.count > 1 {
                parent.addItems(withTitles: commit.parentIDs.enumerated().map { GitL10n.format("Parent {0} · {1}", String(describing: $0.offset + 1), String(describing: $0.element.shortSHA)) })
                parent.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
                alert.accessoryView = parent
                alert.informativeText += GitL10n.text("\nChoose the merge parent to use as the mainline.")
            }
            alert.addButton(withTitle: verb)
        default: return nil
        }
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        if operation == .createBranch { return .createBranch(name: field.stringValue, commit: commit.id) }
        return .applyCommit(operation, commit.id, mainline: commit.parentIDs.count > 1 ? parent.indexOfSelectedItem + 1 : nil)
    }
}
