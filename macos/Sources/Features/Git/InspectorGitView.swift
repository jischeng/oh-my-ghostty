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
                    hint: "SSH remote Git inspection will be enabled in task #13."
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
                    Text(branch)
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
        }
    }

    private var tabPickerView: some View {
        Picker(
            "",
            selection: Binding(
                get: { content.activeTab },
                set: { perform(.gitAction(.selectTab($0))) }
            )
        ) {
            ForEach(InspectorGitContent.ActiveTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func tabContentView(headCommitID: String?) -> some View {
        switch content.activeTab {
        case .history:
            historyView(headCommitID: headCommitID)

        case .changes:
            placeholderCard(
                systemImage: "doc.badge.plus",
                title: "Working Tree Changes",
                subtitle: "Stage, unstage and inspect file diffs.",
                taskHint: "Changes will appear here when supported."
            )

        case .branches:
            placeholderCard(
                systemImage: "arrow.triangle.branch",
                title: "Branches",
                subtitle: content.branch ?? "Current branch",
                taskHint: "Branch management will appear here when supported."
            )
        }
    }

    private func historyView(headCommitID: String?) -> some View {
        VStack(spacing: 8) {
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
            .pickerStyle(.segmented)
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
                    onSelect: { perform(.gitAction(.selectCommit($0))) }
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

    private func placeholderCard(
        systemImage: String,
        title: String,
        subtitle: String,
        taskHint: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.7))

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(taskHint)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.08))
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
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
