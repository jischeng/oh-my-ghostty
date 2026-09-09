import AppKit

enum GitCommitOperation: String, CaseIterable, Equatable, Sendable {
    case createBranch, createWorktree, detachedWorktree, details, compareWithHead, cherryPick, revert
    var title: String {
        switch self {
        case .createBranch: "Create Branch from This Commit…"
        case .createWorktree: "Create Branch + Worktree…"
        case .detachedWorktree: "Create Detached Worktree…"
        case .details: "Show Commit Details / Changed Files"
        case .compareWithHead: "Compare with HEAD"
        case .cherryPick: "Cherry-pick…"
        case .revert: "Revert…"
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
            alert.messageText = "Create Branch"
            alert.informativeText = "Create a branch at \(commit.id.shortSHA). The current branch will stay checked out."
            field.placeholderString = "feature/new-branch"
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Create Branch")
        case .cherryPick, .revert:
            let verb = operation == .cherryPick ? "Cherry-pick" : "Revert"
            alert.messageText = "\(verb) \(commit.id.shortSHA)?"
            alert.informativeText = "\(commit.subject)\n\nThis creates a commit on the current branch."
            if commit.parentIDs.count > 1 {
                parent.addItems(withTitles: commit.parentIDs.enumerated().map { "Parent \($0.offset + 1) · \($0.element.shortSHA)" })
                parent.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
                alert.accessoryView = parent
                alert.informativeText += "\nChoose the merge parent to use as the mainline."
            }
            alert.addButton(withTitle: verb)
        default: return nil
        }
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        if operation == .createBranch { return .createBranch(name: field.stringValue, commit: commit.id) }
        return .applyCommit(operation, commit.id, mainline: commit.parentIDs.count > 1 ? parent.indexOfSelectedItem + 1 : nil)
    }
}
