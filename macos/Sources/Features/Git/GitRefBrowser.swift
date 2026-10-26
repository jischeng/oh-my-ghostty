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
    var externalQuery: String?
    var externalMode: GitCollectionMode?
    var showsToolbar = true
    var externalController: GitCollectionController?
    var externalCancel: (() -> Void)?
    var state: GitCollectionState?
    var stateKey = "refs"
    var selectedID: String?
    var decorations: [GitRefDecoration]?
    var tags: [GitRefDecoration] = []
    var pasteboard = NSPasteboard.general
    var close: () -> Void = {}
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors
    @State private var query = ""
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var copied: String?
    @State private var controller = GitCollectionController()
    @AppStorage("git.refs.viewMode") private var mode: GitCollectionMode = .tree
    var body: some View {
        VStack(spacing: 6) {
            if showsToolbar {
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
            }
            if isPicker {
                HStack(spacing: 0) {
                    scopeButton(.currentBranch)
                    scopeButton(.allBranches)
                }
                .modifier(GitToolbarSegmentedStyle(colors: colors))
                .padding(.horizontal, 10)
            }
            GitCollectionView(source: decorations.map(GitCollectionSource.decorations) ?? .refs(branches: branches, worktrees: worktrees, scopes: false,
                                            branchesError: branchesError, worktreesError: worktreesError),
                mode: externalMode ?? mode, query: externalQuery ?? query, canWrite: !isBusy,
                interaction: decorations != nil ? .references : isPicker ? .picker : .branches, state: state, stateKey: stateKey,
                selectedID: selectedID, extraRefs: tags, pasteboard: pasteboard,
                referenceAction: { ref in copied = ref.name; InspectorCopyMenu.copy(ref.name, to: pasteboard) },
                controller: externalController ?? controller, cancel: cancel, perform: { action in
                    if isPicker { close() }
                    perform(action)
                })
            if let copied {
                HStack { Text(GitL10n.text("Copied")).font(.caption).foregroundStyle(.secondary); InspectorCopyText(text: copied) }
                    .padding(.horizontal, 10).frame(height: 20)
            }
        }.environment(\.locale, Locale(identifier: SettingsStrings(language: settings.language).languageCode))
    }
    private func scopeButton(_ scope: GitHistoryScope) -> some View {
        Button { close(); perform(.selectHistoryScope(scope)) } label: {
            Text(scope.displayName).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 24)
        }
        .buttonStyle(GitToolbarButtonStyle(colors: colors, selected: selectedID == "scope:" + scope.rawValue))
    }

    private func cancel() {
        if let externalCancel { externalCancel() } else if isPicker || decorations != nil { close() } else { query = "" }
    }
}
