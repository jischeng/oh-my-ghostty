import AppKit
import SwiftUI

/// Sidebar and picker share search, modes, grouping, rows and selection.
struct GitRefBrowser: View {
    let branches: [GitBranchInfo]
    var worktrees: [GitWorktreeInfo] = []
    var isBusy = false
    var branchesError: String?
    var worktreesError: String?
    var isPicker = false
    var state: GitCollectionState?
    var stateKey = "refs"
    var selectedID: String?
    var decorations: [GitRefDecoration]?
    var tags: [GitRefDecoration] = []
    var pasteboard = NSPasteboard.general
    var close: () -> Void = {}
    let perform: (InspectorGitAction) -> Void
    @State private var query = ""
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var copied: String?
    @State private var controller = GitCollectionController()
    @AppStorage("git.refs.viewMode") private var mode: GitCollectionMode = .tree
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                GitCollectionToolbar(query: $query, mode: $mode, placeholder: decorations == nil ? GitL10n.text("Search branches…") : GitL10n.text("Search references…"), autofocus: isPicker || decorations != nil,
                                     controller: controller, cancel: cancel)
                if !isPicker && decorations == nil {
                    Button { perform(.createWorktree(nil)) } label: {
                        Image(systemName: "plus").font(.system(size: 11)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(GitL10n.text("New Worktree"))
                    .disabled(isBusy || worktreesError != nil)
                }
            }.padding(.horizontal, 10)
            GitCollectionView(source: decorations.map(GitCollectionSource.decorations) ?? .refs(branches: branches, worktrees: worktrees, scopes: isPicker,
                                            branchesError: branchesError, worktreesError: worktreesError),
                mode: mode, query: query, canWrite: !isBusy,
                interaction: decorations != nil ? .references : isPicker ? .picker : .branches, state: state, stateKey: stateKey,
                selectedID: selectedID, extraRefs: tags, pasteboard: pasteboard,
                referenceAction: { ref in copied = ref.name; InspectorCopyMenu.copy(ref.name, to: pasteboard) },
                controller: controller, cancel: cancel, perform: { action in
                    if isPicker { close() }
                    perform(action)
                })
            if let copied {
                HStack { Text(GitL10n.text("Copied")).font(.caption).foregroundStyle(.secondary); InspectorCopyText(text: copied) }
                    .padding(.horizontal, 10).frame(height: 20)
            }
        }.environment(\.locale, Locale(identifier: SettingsStrings(language: settings.language).languageCode))
    }
    private func cancel() { if isPicker || decorations != nil { close() } else { query = "" } }
}
