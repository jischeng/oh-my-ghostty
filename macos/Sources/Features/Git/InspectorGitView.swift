import SwiftUI

struct InspectorGitView: View {
    let content: InspectorGitContent
    let perform: (InspectorPaneActionKind) -> Void

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
                        .buttonStyle(.plain).help("Dismiss Git error")
                }.padding(8)
            }
            if let operation = content.operation {
                HStack { ProgressView().controlSize(.small); Text(operation).font(.caption) }.padding(6)
            }

            switch content.status {
            case .notRepository(let directory):
                emptyStateView(
                    systemImage: "folder.badge.questionmark",
                    title: "Not a Git Repository",
                    subtitle: directory.isEmpty
                        ? "The terminal has not reported a working directory."
                        : "The current directory is not tracked by Git.",
                    hint: "Run 'git init' in the terminal to initialize a repository."
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
                    title: "Remote Git (\(host))",
                    subtitle: directory.isEmpty ? host : directory,
                    hint: "Waiting for the SSH session to report its remote working directory."
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
                .help("Refresh Git status")
            }

            if let connection = content.connectionLabel ?? content.repository?.sshConnection?.destination {
                Text("SSH · " + connection).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let branch = content.branch, !branch.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    Text(branch)
                        .lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }
            if let current = content.workingTree.branches.first(where: { $0.isCurrent }) {
                Text(current.upstream.isEmpty ? "No upstream configured" :
                        "\(current.upstream) \(current.tracking.isEmpty ? "· up to date" : current.tracking)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Compared with the locally cached upstream ref; refresh does not fetch.")
            }
        }
    }

    private var tabPickerView: some View {
        HStack(spacing: 2) {
            ForEach(InspectorGitContent.ActiveTab.allCases, id: \.self) { tab in
                Button { perform(.gitAction(.selectTab(tab))) } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: content.activeTab == tab ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(content.activeTab == tab ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityValue(content.activeTab == tab ? "Selected" : "")
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func tabContentView(headCommitID: String?) -> some View {
        switch content.activeTab {
        case .history:
            historyView(headCommitID: headCommitID)

        case .changes:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = content.workingTree.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        changeSection("Staged", files: content.workingTree.staged, target: .staged)
                        changeSection("Unstaged / Untracked", files: content.workingTree.unstaged, target: .unstaged)
                        Divider()
                        Text("Checked files are staged for commit.").font(.caption2).foregroundStyle(.secondary)
                        Text("Commit message").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { content.commitDraft }, set: {
                            perform(.gitAction(.updateCommitDraft($0)))
                        }))
                        .font(.system(size: 12))
                        .frame(height: 72)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                        .accessibilityLabel("Commit message")
                        Button("Commit Staged (\(content.workingTree.staged.count))") {
                            perform(.gitAction(.commitStaged))
                        }
                        .disabled(content.operation != nil || content.workingTree.staged.isEmpty ||
                                  content.commitDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.horizontal, 12)
            }
        case .branches:
            if let error = content.workingTree.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            GitBranchTree(branches: content.workingTree.branches, isBusy: content.operation != nil) {
                perform(.gitAction($0))
            }
        }
    }

    private func changeSection(_ title: String, files: [GitDiffFile], target: GitDiffTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) (\(files.count))").font(.caption).foregroundStyle(.secondary)
            ForEach(files) { file in
                HStack(alignment: .top, spacing: 5) {
                    Toggle("Stage \(file.path)", isOn: Binding(get: { target == .staged }, set: {
                        perform(.gitAction(.setFileStaged(file, $0)))
                    }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(content.operation != nil)
                Button { perform(.gitAction(.openDiff(file, target))) } label: {
                    HStack(spacing: 6) {
                        Text(file.isUntracked ? "?" : file.status).font(.caption.monospaced())
                            .foregroundStyle(file.kind == .deleted ? Color.red : Color.green)
                        Text(file.displayPath).lineLimit(2).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(file.displayPath)
                }
            }
            if files.isEmpty { Text("No changes").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func historyView(headCommitID: String?) -> some View {
        VStack(spacing: 8) {
            Menu {
                ForEach(GitHistoryScope.allCases, id: \.self) { scope in
                    Button(scope.displayName) { perform(.gitAction(.selectHistoryScope(scope))) }
                }
                Divider()
                ForEach(content.workingTree.branches) { branch in
                    Button { perform(.gitAction(.browseBranch(branch.id))) } label: {
                        Label(branch.name, systemImage: branch.isRemote ? "network" : "arrow.triangle.branch")
                    }
                }
            } label: {
                Label(content.history.snapshot?.browsedBranch ?? content.history.scope.displayName,
                      systemImage: "line.3.horizontal.decrease")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)

            if content.history.commits.isEmpty && !content.history.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(content.history.statusMessage ?? (headCommitID == nil ? "No commits yet" : "No history found"))
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
                    automaticLoadingAllowed: content.history.statusMessage == nil,
                    onSelect: { perform(.gitAction(.selectCommit($0))) },
                    onOpen: { perform(.gitAction(.openCommit($0))) },
                    onShowInTerminal: {
                        perform(.gitAction(.sendHistoryToTerminal($0)))
                    },
                    onOpenFile: { commit, file in perform(.gitAction(.openDiff(file, .commit(commit)))) },
                    onLoadMore: { perform(.gitAction(.loadMoreHistory)) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = content.history.statusMessage, !content.history.commits.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
            if content.history.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 4)
            } else if content.history.hasMore {
                Button("Load more history") {
                    perform(.gitAction(.loadMoreHistory))
                }
                .buttonStyle(.link)
                .padding(.bottom, 5)
            }
        }
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
