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
                    hint: "Remote Git inspection is not available yet."
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
                Image(systemName: "arrow.triangle.branch")
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
                    }
                }.padding(.horizontal, 12)
            }
        case .branches:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = content.workingTree.error { Text(error).foregroundStyle(.red) }
                    ForEach(content.workingTree.branches) { branch in
                        Button {
                            perform(.gitAction(.browseBranch(branch.id)))
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(branch.name, systemImage: branch.isCurrent ? "checkmark.circle.fill" :
                                        (branch.isRemote ? "network" : "arrow.triangle.branch"))
                                    .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.primary)
                                    .lineLimit(1).truncationMode(.middle)
                                if !branch.upstream.isEmpty {
                                    Text("\(branch.upstream) \(branch.tracking.isEmpty ? "· up to date" : branch.tracking)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Browse history · \(branch.name)")
                    }
                    if content.workingTree.branches.isEmpty {
                        Text("No branches yet").foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12)
            }
        }
    }

    private func changeSection(_ title: String, files: [GitDiffFile], target: GitDiffTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) (\(files.count))").font(.caption).foregroundStyle(.secondary)
            ForEach(files) { file in
                Button { perform(.gitAction(.openDiff(file, target))) } label: {
                    HStack(spacing: 6) {
                        Text(file.isUntracked ? "?" : file.status).font(.caption.monospaced())
                            .foregroundStyle(file.kind == .deleted ? Color.red : Color.green)
                        Text(file.displayPath).lineLimit(2).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(file.displayPath)
            }
            if files.isEmpty { Text("No changes").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func historyView(headCommitID: String?) -> some View {
        VStack(spacing: 8) {
            if let branch = content.history.snapshot?.browsedBranch {
                HStack {
                    Text("History: \(branch)").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Reset") { perform(.gitAction(.selectHistoryScope(content.history.scope))) }
                        .buttonStyle(.link)
                }.padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                Picker(
                    "History scope",
                    selection: Binding(
                        get: { content.history.scope },
                        set: { perform(.gitAction(.selectHistoryScope($0))) }
                    )
                ) {
                    ForEach(GitHistoryScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

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
                    onSelect: { perform(.gitAction(.selectCommit($0))) },
                    onOpen: { perform(.gitAction(.openCommit($0))) },
                    onShowInTerminal: {
                        perform(.gitAction(.sendHistoryToTerminal($0)))
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
