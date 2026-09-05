import AppKit
import Foundation
import OSLog

@MainActor
final class BuiltInGitInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "git-inspector"
    )

    static let pluginID = "builtin.git"
    static let paneID = "builtin.git"

    struct WorktreeUIState: Equatable, Sendable {
        var activeTab: InspectorGitContent.ActiveTab = .history
        var commitDraft: String = ""
        var selectedCommitID: GitCommitID?
        var historyScope: GitHistoryScope = .allBranches
        var history: InspectorGitHistoryContent = InspectorGitHistoryContent()
    }

    private let registry: InspectorRegistry
    private let repositoryService: GitRepositoryService
    private let historyService: GitHistoryService
    private let terminalBridge: GitTerminalBridge
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var tabWorktreeStates: [UUID: [String: WorktreeUIState]] = [:]
    private var lastPublishedContent: [UUID: InspectorGitContent] = [:]
    private var pollTimer: Timer?

    init(
        registry: InspectorRegistry,
        repositoryService: GitRepositoryService = GitRepositoryService(),
        historyService: GitHistoryService? = nil,
        terminalBridge: GitTerminalBridge? = nil
    ) {
        self.registry = registry
        self.repositoryService = repositoryService
        self.historyService = historyService ?? GitHistoryService()
        self.terminalBridge = terminalBridge ?? GitTerminalBridge()
    }

    func register() throws {
        let descriptor = InspectorPaneDescriptor(id: Self.paneID, title: "Git", systemImage: "arrow.triangle.branch", source: .plugin(Self.pluginID), preferredWidth: RightInspectorMetrics.defaultWidth, minimumWidth: 220)
        try registry.registerPluginPane(descriptor, lifecycle: { [weak self] event in self?.handle(event) }, action: { [weak self] action in self?.handle(action) })
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context): presentedContexts[context.tabID] = context; load(context: context); ensurePollingTimer()
        case .disappeared(let context): cancelTask(tabID: context.tabID); presentedContexts.removeValue(forKey: context.tabID); if presentedContexts.isEmpty { stopPollingTimer() }
        }
    }

    private func handle(_ action: InspectorPaneAction) {
        guard case .gitAction(let gitAction) = action.kind else { return }
        switch gitAction {
        case .refresh: load(context: action.context, force: true)
        case .selectTab(let tab):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key); state.activeTab = tab; save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] {
                publish(makeContent(from: current, activeTab: tab, history: state.history), tabID: action.context.tabID)
                if tab == .history && state.history.snapshot == nil { loadHistory(context: action.context, force: true) }
            }
        case .selectHistoryScope(let scope):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            guard state.historyScope != scope else { return }
            state.historyScope = scope; state.selectedCommitID = nil; state.history = InspectorGitHistoryContent(scope: scope, isLoading: true); save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] { publish(makeContent(from: current, history: state.history), tabID: action.context.tabID) }
            loadHistory(context: action.context, force: true)
        case .loadMoreHistory: loadHistory(context: action.context, force: false)
        case .selectCommit(let commitID):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            guard state.history.commits.contains(where: { $0.id == commitID }) else { return }
            state.selectedCommitID = commitID
            state.history = InspectorGitHistoryContent(scope: state.history.scope, commits: state.history.commits, selectedCommitID: commitID, hasMore: state.history.hasMore, isLoading: state.history.isLoading, statusMessage: state.history.statusMessage, snapshot: state.history.snapshot)
            save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] { publish(makeContent(from: current, history: state.history), tabID: action.context.tabID) }
        case .openCommit(let commitID):
            guard let content = lastPublishedContent[action.context.tabID],
                  let repository = content.repository,
                  content.history.commits.contains(where: { $0.id == commitID }) else {
                return
            }
            GitDetailWindowController.open(
                repository: repository,
                target: .commit(commitID),
                tabID: action.context.tabID
            )

        case .sendHistoryToTerminal(let commitID):
            guard let content = lastPublishedContent[action.context.tabID],
                  let repository = content.repository else { return }
            let intent: GitTerminalCommandIntent
            if let commitID {
                guard content.history.commits.contains(where: { $0.id == commitID }) else {
                    return
                }
                intent = .show(repository: repository, commit: commitID)
            } else {
                intent = .log(repository: repository)
            }
            _ = terminalBridge.dispatch(intent, in: action.context)
        }
    }

    private func load(context: InspectorPaneContext, force: Bool = false) {
        cancelTask(tabID: context.tabID)
        let generation = nextGeneration(for: context.tabID)
        let key = currentWorktreeKey(for: context)
        let activeTab = state(for: context.tabID, worktreeKey: key).activeTab
        switch context.session.state {
        case .sshReady(let ssh, let remoteDir): publish(InspectorGitContent(status: .ssh(host: ssh.alias, workingDirectory: remoteDir), activeTab: activeTab), tabID: context.tabID); return
        case .sshConnecting(let ssh): publish(InspectorGitContent(status: .ssh(host: ssh.alias, workingDirectory: context.session.workingDirectory ?? ""), activeTab: activeTab), tabID: context.tabID); return
        case .local: break
        }
        guard let directory = context.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty else { publish(InspectorGitContent(status: .notRepository(directory: ""), activeTab: activeTab), tabID: context.tabID); return }
        let oldContent = lastPublishedContent[context.tabID]
        if force || oldContent == nil { publish(InspectorGitContent(repository: oldContent?.repository, branch: oldContent?.branch, status: oldContent?.status ?? .notRepository(directory: directory), activeTab: activeTab, history: state(for: context.tabID, worktreeKey: key).history, isLoading: true), tabID: context.tabID) }
        loadTasks[context.tabID] = Task { [weak self] in
            guard let self else { return }
            let status = await self.repositoryService.resolveStatus(workingDirectory: directory, session: context.session)
            guard !Task.isCancelled, self.generations[context.tabID] == generation else { return }
            let repo = status.repository; let resolvedKey = repo?.worktreePath ?? directory
            var state = self.state(for: context.tabID, worktreeKey: resolvedKey)
            var history = state.history
            if history.scope != state.historyScope { history = InspectorGitHistoryContent(scope: state.historyScope) }
            if let repo, force || (activeTab == .history && history.snapshot == nil) {
                do {
                    let snapshot = try await self.historyService.captureSnapshot(for: repo, scope: state.historyScope)
                    let page = try await self.historyService.loadPage(snapshot: snapshot, repository: repo, offset: 0)
                    history = InspectorGitHistoryContent(scope: state.historyScope, commits: page.commits, selectedCommitID: state.selectedCommitID, hasMore: page.hasMore, snapshot: snapshot)
                } catch is CancellationError { return
                } catch { history = InspectorGitHistoryContent(scope: state.historyScope, selectedCommitID: state.selectedCommitID, statusMessage: error.localizedDescription) }
            }
            guard !Task.isCancelled, self.generations[context.tabID] == generation else { return }
            var latestState = self.state(for: context.tabID, worktreeKey: resolvedKey)
            history = InspectorGitHistoryContent(
                scope: latestState.historyScope,
                commits: history.commits,
                selectedCommitID: latestState.selectedCommitID,
                hasMore: history.hasMore,
                isLoading: false,
                statusMessage: history.statusMessage,
                snapshot: history.snapshot
            )
            latestState.history = history
            self.save(latestState, tabID: context.tabID, worktreeKey: resolvedKey)
            self.loadTasks.removeValue(forKey: context.tabID)
            self.publish(InspectorGitContent(repository: repo, branch: status.headDescription, status: status, activeTab: latestState.activeTab, history: history), tabID: context.tabID)
        }
    }

    private func loadHistory(context: InspectorPaneContext, force: Bool) {
        guard let current = lastPublishedContent[context.tabID], let repository = current.repository else { return }
        guard force || current.history.hasMore else { return }
        cancelTask(tabID: context.tabID)
        let generation = nextGeneration(for: context.tabID)
        let key = repository.worktreePath
        let stateBefore = state(for: context.tabID, worktreeKey: key)
        let offset = force ? 0 : stateBefore.history.commits.count
        let oldCommits = force ? [] : stateBefore.history.commits
        let loading = InspectorGitHistoryContent(scope: stateBefore.historyScope, commits: oldCommits, selectedCommitID: force ? nil : stateBefore.selectedCommitID, hasMore: stateBefore.history.hasMore, isLoading: true, snapshot: force ? nil : stateBefore.history.snapshot)
        var loadingState = stateBefore; loadingState.history = loading; if force { loadingState.selectedCommitID = nil }; save(loadingState, tabID: context.tabID, worktreeKey: key); publish(makeContent(from: current, history: loading), tabID: context.tabID)
        loadTasks[context.tabID] = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = force || stateBefore.history.snapshot == nil ? try await self.historyService.captureSnapshot(for: repository, scope: stateBefore.historyScope) : stateBefore.history.snapshot!
                let page = try await self.historyService.loadPage(snapshot: snapshot, repository: repository, offset: offset)
                guard !Task.isCancelled, self.generations[context.tabID] == generation else { return }
                var updated = self.state(for: context.tabID, worktreeKey: key)
                let history = InspectorGitHistoryContent(scope: updated.historyScope, commits: oldCommits + page.commits, selectedCommitID: updated.selectedCommitID, hasMore: page.hasMore, snapshot: snapshot)
                updated.history = history; self.save(updated, tabID: context.tabID, worktreeKey: key); self.loadTasks.removeValue(forKey: context.tabID)
                if let latest = self.lastPublishedContent[context.tabID] { self.publish(self.makeContent(from: latest, history: history), tabID: context.tabID) }
            } catch is CancellationError { return
            } catch {
                guard !Task.isCancelled, self.generations[context.tabID] == generation else { return }
                let history = InspectorGitHistoryContent(scope: stateBefore.historyScope, commits: oldCommits, selectedCommitID: stateBefore.selectedCommitID, statusMessage: error.localizedDescription, snapshot: stateBefore.history.snapshot)
                self.loadTasks.removeValue(forKey: context.tabID)
                if let latest = self.lastPublishedContent[context.tabID] { self.publish(self.makeContent(from: latest, history: history), tabID: context.tabID) }
            }
        }
    }

    private func ensurePollingTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollActiveTabs() } }
    }
    private func stopPollingTimer() { pollTimer?.invalidate(); pollTimer = nil }

    private func pollActiveTabs() {
        guard NSApp.isActive else { return }
        for (tabID, context) in presentedContexts {
            guard loadTasks[tabID] == nil, case .local = context.session.state, let directory = context.workingDirectory, !directory.isEmpty else { continue }
            let generation = nextGeneration(for: tabID)
            loadTasks[tabID] = Task { [weak self] in
                guard let self else { return }
                let status = await self.repositoryService.resolveStatus(workingDirectory: directory, session: context.session)
                guard !Task.isCancelled, self.generations[tabID] == generation else { return }
                guard let current = self.lastPublishedContent[tabID] else {
                    self.loadTasks.removeValue(forKey: tabID)
                    return
                }
                guard let repository = status.repository else {
                    self.loadTasks.removeValue(forKey: tabID)
                    self.load(context: context, force: true)
                    return
                }
                var refsChanged = false
                if let snapshot = current.history.snapshot,
                   let latest = try? await self.historyService.captureSnapshot(for: repository, scope: snapshot.scope) {
                    guard !Task.isCancelled, self.generations[tabID] == generation else {
                        return
                    }
                    refsChanged = latest != snapshot
                }
                self.loadTasks.removeValue(forKey: tabID)
                if refsChanged {
                    self.load(context: context, force: true)
                } else if current.status != status {
                    let state = self.state(for: tabID, worktreeKey: repository.worktreePath)
                    self.publish(
                        InspectorGitContent(
                            repository: repository,
                            branch: status.headDescription,
                            status: status,
                            activeTab: state.activeTab,
                            history: state.history
                        ),
                        tabID: tabID
                    )
                }
            }
        }
    }

    private func makeContent(from current: InspectorGitContent, activeTab: InspectorGitContent.ActiveTab? = nil, history: InspectorGitHistoryContent? = nil) -> InspectorGitContent { InspectorGitContent(repository: current.repository, branch: current.branch, status: current.status, activeTab: activeTab ?? current.activeTab, history: history ?? current.history, isLoading: current.isLoading, statusMessage: current.statusMessage) }
    private func state(for tabID: UUID, worktreeKey: String) -> WorktreeUIState { tabWorktreeStates[tabID]?[worktreeKey] ?? WorktreeUIState() }
    private func save(_ state: WorktreeUIState, tabID: UUID, worktreeKey: String) { var states = tabWorktreeStates[tabID] ?? [:]; states[worktreeKey] = state; tabWorktreeStates[tabID] = states }
    private func publish(_ content: InspectorGitContent, tabID: UUID) { lastPublishedContent[tabID] = content; do { try registry.updatePluginContent(paneID: Self.paneID, pluginID: Self.pluginID, tabID: tabID, content: .git(content)) } catch { Self.logger.error("Git state publish failed tab=\(tabID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)") } }
    private func cancelTask(tabID: UUID) { loadTasks.removeValue(forKey: tabID)?.cancel() }
    private func nextGeneration(for tabID: UUID) -> UInt64 { let next = (generations[tabID] ?? 0) &+ 1; generations[tabID] = next; return next }
    private func currentWorktreeKey(for context: InspectorPaneContext) -> String { lastPublishedContent[context.tabID]?.repository?.worktreePath ?? context.workingDirectory ?? "" }
}
