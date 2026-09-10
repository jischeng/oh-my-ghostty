import SwiftUI

struct InspectorGitView: View {
    let content: InspectorGitContent
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var collectionState = GitCollectionState()
    @State private var changesController = GitCollectionController()
    @State private var changesQuery = ""
    @AppStorage("git.changes.viewMode") private var changesMode: GitCollectionMode = .list

    private var collectionKey: String { content.repository?.stateKey ?? "git" }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()
            if let error = content.operationError {
                HStack(alignment: .top) {
                    ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        .frame(maxHeight: 90)
                    Button { perform(.gitAction(.clearOperationError)) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(GitL10n.text("Dismiss Git error"))
                }.padding(8)
            }
            if let operation = content.operation, !content.isUpdatingIndex {
                HStack { ProgressView().controlSize(.small); Text(operation).font(.caption) }.padding(6)
            }

            switch content.status {
            case .notRepository(let directory):
                emptyStateView(
                    systemImage: "folder.badge.questionmark",
                    title: GitL10n.text("Not a Git Repository"),
                    subtitle: directory.isEmpty
                        ? GitL10n.text("The terminal has not reported a working directory.")
                        : GitL10n.text("The current directory is not tracked by Git."),
                    hint: GitL10n.text("Run 'git init' in the terminal to initialize a repository.")
                )

            case .unborn:
                VStack(spacing: 12) {
                    tabPickerView
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    tabContentView(headCommitID: nil)
                }

            case .detached(_, let commitID):
                VStack(spacing: 12) {
                    tabPickerView
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    tabContentView(headCommitID: commitID.rawValue)
                }

            case .ssh(let host, let directory):
                emptyStateView(
                    systemImage: "network",
                    title: GitL10n.format("Remote Git ({0})", String(describing: host)),
                    subtitle: directory.isEmpty ? host : directory,
                    hint: GitL10n.text("Waiting for the SSH session to report its remote working directory.")
                )

            case .error(let title, let message):
                emptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: title,
                    subtitle: message,
                    hint: nil
                )

            case .ready(_, _, let headCommitID):
                VStack(spacing: 12) {
                    tabPickerView
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    tabContentView(headCommitID: headCommitID?.rawValue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: settings.language) { _ in perform(.gitAction(.refresh)) }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: content.connectionLabel == nil ? "arrow.triangle.branch" : "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)

                Text(content.repository?.repositoryName ?? "Git")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(content.repository?.worktreePath ?? "")
                    .contextMenu {
                        Button(GitL10n.text("Copy repository name")) { InspectorCopyMenu.copy(content.repository?.repositoryName ?? "Git") }
                    }

                Spacer(minLength: 4)

                if content.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                Button {
                    perform(.gitAction(.refresh))
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(GitL10n.text("Refresh Git status"))
            }

            if let repository = content.repository {
                InspectorCopyText(text: repository.worktreePath).frame(height: 14)
                if let address = content.workingTree.remoteURL {
                    InspectorCopyText(text: address).frame(height: 14)
                }

            }
            if let connection = content.connectionLabel ?? content.repository?.sshConnection?.destination {
                InspectorCopyText(text: "SSH · " + connection).frame(height: 14)
            }
            if !headerReferences.isEmpty { GitHeaderReferences(refs: headerReferences) }
            if content.workingTree.branchesError == nil,
               let current = content.workingTree.branches.first(where: { $0.isCurrent }) {
                InspectorCopyText(text: current.upstream.isEmpty ? GitL10n.text("No upstream configured") :
                    "\(current.upstream) \(current.tracking.isEmpty ? GitL10n.text("· up to date") : current.tracking)")
                    .frame(height: 14)
            }
        }
    }

    private var headerReferences: [GitRefDecoration] {
        let branch: [GitRefDecoration]
        switch content.status {
        case .ready(_, let name, _), .unborn(_, let name): branch = [.init(name: name, kind: .currentBranch)]
        case .detached: branch = [.init(name: "HEAD", kind: .head)]
        default: branch = []
        }
        return branch + currentTags
    }

    private var currentTags: [GitRefDecoration] {
        let head: GitCommitID?
        switch content.status {
        case .ready(_, _, let id): head = id
        case .detached(_, let id): head = id
        default: head = nil
        }
        guard let head else { return [] }
        let refs = content.history.snapshot?.decorationsByCommitID[head] ??
            content.history.commits.first(where: { $0.id == head })?.refDecorations ?? []
        return refs.filter { $0.kind == .tag }
    }

    private var tabPickerView: some View {
        GitSidebarNavigation(selected: content.activeTab) { perform(.gitAction(.selectTab($0))) }
    }

    @ViewBuilder
    private func tabContentView(headCommitID: String?) -> some View {
        ZStack {
            historyView(headCommitID: headCommitID)
                .opacity(content.activeTab == .history ? 1 : 0)
                .allowsHitTesting(content.activeTab == .history)
                .accessibilityHidden(content.activeTab != .history)
            nonHistoryTabContent
        }
    }

    @ViewBuilder
    private var nonHistoryTabContent: some View {
        switch content.activeTab {
        case .history:
            EmptyView()

        case .changes:
            VStack(spacing: 0) {
                GitCollectionToolbar(query: $changesQuery, mode: $changesMode, placeholder: GitL10n.text("Search files…"),
                                     controller: changesController, cancel: { changesQuery = "" })
                    .padding(.horizontal, 10).padding(.bottom, 6)
                GitCollectionView(source: .changes(content.workingTree), mode: changesMode, query: changesQuery,
                    pending: content.pendingIndexPaths, canWrite: content.operation == nil || content.isUpdatingIndex,
                    state: collectionState, stateKey: collectionKey + "/changes", controller: changesController,
                    cancel: { changesQuery = "" }, perform: {
                    perform(.gitAction($0))
                })
                Divider()
                GitCommitComposer(message: Binding(get: { content.commitDraft }, set: { perform(.gitAction(.updateCommitDraft($0))) }),
                    stagedCount: content.workingTree.staged.count, isBusy: content.operation != nil,
                    canCommit: content.workingTree.stagedError == nil, isUpdatingIndex: content.isUpdatingIndex) {
                    perform(.gitAction(.commitStaged))
                }
                .padding(10)
            }
        case .branches:
            GitRefBrowser(branches: content.workingTree.branches, worktrees: content.workingTree.worktrees,
                          isBusy: content.operation != nil, branchesError: content.workingTree.branchesError,
                          worktreesError: content.workingTree.worktreesError,
                          state: collectionState, stateKey: collectionKey + "/refs/sidebar") {
                perform(.gitAction($0))
            }
        }
    }

    private func historyView(headCommitID: String?) -> some View {
        VStack(spacing: 8) {
            GitHistoryScopePicker(title: content.history.snapshot?.browsedBranch ?? content.history.scope.displayName,
                                  branches: content.workingTree.branches, enabled: content.workingTree.branchesError == nil,
                                  isBusy: content.operation != nil,
                                  worktrees: content.workingTree.worktrees, worktreesError: content.workingTree.worktreesError,
                                  state: collectionState, stateKey: collectionKey + "/refs/picker", selectedID: historySelectionID,
                                  tags: Array(Set(content.history.snapshot?.decorationsByCommitID.values.joined().filter { $0.kind == .tag } ?? [])).sorted { $0.name < $1.name }) {
                perform(.gitAction($0))
            }
            .frame(height: 28)
            .padding(.horizontal, 12)

            if content.history.commits.isEmpty && !content.history.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(content.history.statusMessage ?? (headCommitID == nil ? GitL10n.text("No commits yet") : GitL10n.text("No history found")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GitHistoryTable(
                    commits: content.history.commits,
                    selectedCommitID: content.history.selectedCommitID,
                    headCommitID: content.history.snapshot?.headCommitID,
                    expandedCommits: content.expandedCommits,
                    hasMore: content.history.hasMore,
                    isLoading: content.history.isLoading,
                    automaticLoadingAllowed: content.activeTab == .history && content.history.statusMessage == nil,
                    isBusy: content.operation != nil,
                    onSelect: { perform(.gitAction(.selectCommit($0))) },
                    onOpen: { perform(.gitAction(.openCommit($0))) },
                    onShowInTerminal: {
                        perform(.gitAction(.sendHistoryToTerminal($0)))
                    },
                    onOpenFile: { commit, file in perform(.gitAction(.openDiff(file, .commit(commit)))) },
                    onLoadMore: { perform(.gitAction(.loadMoreHistory)) },
                    onCommitAction: { perform(.gitAction(.commitOperation($0, $1))) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = content.history.statusMessage, !content.history.commits.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
            if content.history.isLoading && content.history.commits.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 4)
            }
        }
    }

    private var historySelectionID: String {
        if let path = content.history.snapshot?.browsedWorktree { return "worktree:" + path }
        return content.history.snapshot?.browsedRef ?? "scope:" + content.history.scope.rawValue
    }

    private func emptyStateView(
        systemImage: String,
        title: String,
        subtitle: String,
        hint: String?
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.8))

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
