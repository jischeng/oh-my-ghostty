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
        var selectedCommitID: String?
    }

    private let registry: InspectorRegistry
    private let repositoryService: GitRepositoryService

    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var tabWorktreeStates: [UUID: [String: WorktreeUIState]] = [:]
    private var lastPublishedContent: [UUID: InspectorGitContent] = [:]
    private var pollTimer: Timer?

    init(
        registry: InspectorRegistry,
        repositoryService: GitRepositoryService = GitRepositoryService()
    ) {
        self.registry = registry
        self.repositoryService = repositoryService
    }

    func register() throws {
        let descriptor = InspectorPaneDescriptor(
            id: Self.paneID,
            title: "Git",
            systemImage: "arrow.triangle.branch",
            source: .plugin(Self.pluginID),
            preferredWidth: RightInspectorMetrics.defaultWidth,
            minimumWidth: 220
        )
        try registry.registerPluginPane(
            descriptor,
            lifecycle: { [weak self] event in self?.handle(event) },
            action: { [weak self] action in self?.handle(action) }
        )
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            presentedContexts[context.tabID] = context
            load(context: context)
            ensurePollingTimer()

        case .disappeared(let context):
            cancelTask(tabID: context.tabID)
            presentedContexts.removeValue(forKey: context.tabID)
            if presentedContexts.isEmpty {
                stopPollingTimer()
            }
        }
    }

    private func handle(_ action: InspectorPaneAction) {
        guard case .gitAction(let gitAction) = action.kind else { return }
        switch gitAction {
        case .refresh:
            load(context: action.context, force: true)

        case .selectTab(let tab):
            let worktreeKey = currentWorktreeKey(for: action.context)
            var states = tabWorktreeStates[action.context.tabID] ?? [:]
            var state = states[worktreeKey] ?? WorktreeUIState()
            state.activeTab = tab
            states[worktreeKey] = state
            tabWorktreeStates[action.context.tabID] = states

            if var current = lastPublishedContent[action.context.tabID] {
                current = InspectorGitContent(
                    repository: current.repository,
                    branch: current.branch,
                    status: current.status,
                    activeTab: tab,
                    isLoading: current.isLoading,
                    statusMessage: current.statusMessage
                )
                publish(current, tabID: action.context.tabID)
            }
        }
    }

    private func load(context: InspectorPaneContext, force: Bool = false) {
        cancelTask(tabID: context.tabID)
        let generation = nextGeneration(for: context.tabID)

        let worktreeKey = currentWorktreeKey(for: context)
        let activeTab = tabWorktreeStates[context.tabID]?[worktreeKey]?.activeTab ?? .history

        // Check for SSH session first
        switch context.session.state {
        case .sshReady(let ssh, let remoteDir):
            let content = InspectorGitContent(
                repository: nil,
                branch: nil,
                status: .ssh(host: ssh.alias, workingDirectory: remoteDir),
                activeTab: activeTab,
                isLoading: false
            )
            publish(content, tabID: context.tabID)
            return

        case .sshConnecting(let ssh):
            let content = InspectorGitContent(
                repository: nil,
                branch: nil,
                status: .ssh(
                    host: ssh.alias,
                    workingDirectory: context.session.workingDirectory ?? ""
                ),
                activeTab: activeTab,
                isLoading: false
            )
            publish(content, tabID: context.tabID)
            return

        case .local:
            break
        }

        guard let directory = context.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            let content = InspectorGitContent(
                repository: nil,
                branch: nil,
                status: .notRepository(directory: ""),
                activeTab: activeTab,
                isLoading: false
            )
            publish(content, tabID: context.tabID)
            return
        }

        // Show loading state if forced or no cached content
        if force || lastPublishedContent[context.tabID] == nil {
            let current = lastPublishedContent[context.tabID]
            let loadingContent = InspectorGitContent(
                repository: current?.repository,
                branch: current?.branch,
                status: current?.status ?? .notRepository(directory: directory),
                activeTab: activeTab,
                isLoading: true
            )
            publish(loadingContent, tabID: context.tabID)
        }

        loadTasks[context.tabID] = Task { [weak self] in
            guard let self else { return }
            let status = await self.repositoryService.resolveStatus(
                workingDirectory: directory,
                session: context.session
            )

            guard !Task.isCancelled,
                  self.generations[context.tabID] == generation else {
                return
            }

            let repo = status.repository
            let branch = status.headDescription

            let resolvedWorktreeKey = repo?.worktreePath ?? directory
            let selectedTab = self.tabWorktreeStates[context.tabID]?[resolvedWorktreeKey]?.activeTab ?? activeTab

            let content = InspectorGitContent(
                repository: repo,
                branch: branch,
                status: status,
                activeTab: selectedTab,
                isLoading: false
            )

            self.loadTasks.removeValue(forKey: context.tabID)
            self.publish(content, tabID: context.tabID)
        }
    }

    private func ensurePollingTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollActiveTabs()
            }
        }
    }

    private func stopPollingTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollActiveTabs() {
        guard NSApp.isActive else { return }
        for (tabID, context) in presentedContexts {
            // Do not overlap polling queries with ongoing loads
            guard loadTasks[tabID] == nil else { continue }
            guard case .local = context.session.state else { continue }
            guard let directory = context.workingDirectory, !directory.isEmpty else { continue }

            let generation = nextGeneration(for: tabID)
            loadTasks[tabID] = Task { [weak self] in
                guard let self else { return }
                let status = await self.repositoryService.resolveStatus(
                    workingDirectory: directory,
                    session: context.session
                )
                guard !Task.isCancelled,
                      self.generations[tabID] == generation else {
                    return
                }
                self.loadTasks.removeValue(forKey: tabID)

                if let current = self.lastPublishedContent[tabID], current.status != status {
                    let repo = status.repository
                    let branch = status.headDescription
                    let worktreeKey = repo?.worktreePath ?? directory
                    let activeTab = self.tabWorktreeStates[tabID]?[worktreeKey]?.activeTab ?? current.activeTab

                    let updated = InspectorGitContent(
                        repository: repo,
                        branch: branch,
                        status: status,
                        activeTab: activeTab,
                        isLoading: false
                    )
                    self.publish(updated, tabID: tabID)
                }
            }
        }
    }

    private func publish(_ content: InspectorGitContent, tabID: UUID) {
        lastPublishedContent[tabID] = content
        do {
            try registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: tabID,
                content: .git(content)
            )
        } catch {
            Self.logger.error("Git state publish failed tab=\(tabID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelTask(tabID: UUID) {
        loadTasks.removeValue(forKey: tabID)?.cancel()
    }

    private func nextGeneration(for tabID: UUID) -> UInt64 {
        let next = (generations[tabID] ?? 0) &+ 1
        generations[tabID] = next
        return next
    }

    private func currentWorktreeKey(for context: InspectorPaneContext) -> String {
        lastPublishedContent[context.tabID]?.repository?.worktreePath ??
            context.workingDirectory ??
            ""
    }
}
