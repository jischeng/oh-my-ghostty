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
    var close: () -> Void = {}
    let perform: (InspectorGitAction) -> Void
    @State private var query = ""
    @State private var controller = GitCollectionController()
    @AppStorage("git.refs.viewMode") private var mode: GitCollectionMode = .tree
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                GitCollectionToolbar(query: $query, mode: $mode, autofocus: isPicker,
                                     controller: controller, cancel: cancel)
                if !isPicker {
                    Button { perform(.createWorktree(nil)) } label: {
                        Image(systemName: "plus").font(.system(size: 11)).frame(width: 20, height: 23)
                    }
                    .buttonStyle(.plain).help("New Worktree")
                    .disabled(isBusy || worktreesError != nil)
                }
            }.padding(.horizontal, 10)
            GitCollectionView(source: .refs(branches: branches, worktrees: worktrees, scopes: isPicker,
                                            branchesError: branchesError, worktreesError: worktreesError),
                mode: mode, query: query, canWrite: !isBusy,
                interaction: isPicker ? .picker : .branches, state: state, stateKey: stateKey,
                selectedID: selectedID, controller: controller, cancel: cancel) { action in
                    if isPicker { close() }
                    perform(action)
                }
        }
    }
    private func cancel() { if isPicker { close() } else { query = "" } }
}
