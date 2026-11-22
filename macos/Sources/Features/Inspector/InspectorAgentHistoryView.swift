import AppKit
import SwiftUI

enum AgentHistoryGroupingMode: String, CaseIterable, Sendable {
    case none
    case project
    case agent
    case date
}

enum AgentHistoryOrderingMode: String, CaseIterable, Sendable {
    case recentlyUpdated
    case title
}

enum AgentHistoryDirectoryFilter: String, CaseIterable, Sendable {
    case any
    case currentTree
}

enum AgentHistoryTimeFilter: String, CaseIterable, Sendable {
    case any
    case day
    case week
    case month
    case quarter
    case year

    /// Inclusive lower bound for a session's last update.
    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .any: return nil
        case .day: return calendar.date(byAdding: .day, value: -1, to: now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

/// Filter and organize selection for Agent History. Held as one value so the
/// trigger can show a single "modified" state and Reset is unambiguous.
struct AgentHistoryFilterState: Equatable, Sendable {
    var agent: SupportedAgent?
    var directory: AgentHistoryDirectoryFilter = .any
    var time: AgentHistoryTimeFilter = .quarter
    var grouping: AgentHistoryGroupingMode = .none
    var ordering: AgentHistoryOrderingMode = .recentlyUpdated

    static let initial = Self()

    var isDefault: Bool { self == Self.initial }
    var narrowsSessions: Bool { agent != nil || directory != .any || time != .any }

    mutating func reset() { self = Self.initial }

    /// Directories match on the resolved path so a session started in a
    /// subfolder of the current one still counts as "this project".
    func includes(
        _ session: AgentHistorySession,
        currentDirectory: String?,
        now: Date = Date()
    ) -> Bool {
        includes(session, currentDirectory: currentDirectory, cutoff: time.cutoff(now: now))
    }

    func filtered(_ sessions: [AgentHistorySession], currentDirectory: String?, now: Date = Date()) -> [AgentHistorySession] {
        let cutoff = time.cutoff(now: now)
        return sessions.filter { includes($0, currentDirectory: currentDirectory, cutoff: cutoff) }
    }

    private func includes(_ session: AgentHistorySession, currentDirectory: String?, cutoff: Date?) -> Bool {
        if let agent, session.agent != agent { return false }
        if directory == .currentTree {
            guard let root = Self.normalizedPath(currentDirectory),
                  let value = Self.normalizedPath(session.workingDirectory) else {
                return false
            }
            let prefix = root == "/" ? "/" : root + "/"
            guard value == root || value.hasPrefix(prefix) else { return false }
        }
        if let cutoff, session.updatedAt < cutoff { return false }
        return true
    }

    static func normalizedPath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        var path = value
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

struct InspectorAgentHistoryView: View {
    let history: InspectorAgentHistoryContent
    /// Working directory of the presented pane, used by the folder filter.
    let currentDirectory: String?
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var visibleSessionCount = 60
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var searchMatches: [String: AgentHistorySearchMatch] = [:]
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var filter = AgentHistoryFilterState()
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var transcriptSearch = ""
    @State private var isTranscriptSearchVisible = false
    @State private var transcriptSearchFocusRequestID = 0

    private var strings: AgentHistoryStrings {
        .init(language: settings.language)
    }

    /// Sessions inside the selected folder/time scope, before the Agent filter.
    /// Agent counts in the popover come from this list so they stay meaningful.
    private var scopedSessions: [AgentHistorySession] {
        var scope = filter
        scope.agent = nil
        return scope.filtered(history.sessions, currentDirectory: currentDirectory)
    }

    private var availableAgents: [SupportedAgent] {
        let present = Set(scopedSessions.map(\.agent))
        return SupportedAgent.allCases.filter { present.contains($0) }
    }

    private var filteredAndOrderedSessions: [AgentHistorySession] {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = scopedSessions.filter { session in
            guard filter.agent == nil || session.agent == filter.agent else {
                return false
            }
            return needle.isEmpty || searchMatches[session.id] != nil
        }
        switch filter.ordering {
        case .recentlyUpdated:
            // Store snapshots are already newest-first. Preserve that order to
            // avoid sorting thousands of rows on every SwiftUI body update.
            return matching
        case .title:
            return matching.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private struct GroupedSection: Identifiable {
        let id: String
        let title: String
        let icon: GhosttyTabIcon
        let sessions: [AgentHistorySession]
    }

    private var groupedSections: [GroupedSection] {
        let list = filteredAndOrderedSessions
        switch filter.grouping {
        case .none:
            return [.init(id: "all", title: "", icon: .systemSymbol("folder"), sessions: list)]
        case .project:
            var buckets: [String: (title: String, icon: GhosttyTabIcon, sessions: [AgentHistorySession])] = [:]
            for session in list {
                let key = session.workingDirectory ?? "Other"
                let title = WorkspacePathPresentation.folderName(key)
                if buckets[key] == nil {
                    buckets[key] = (title: title.isEmpty ? key : title, icon: .systemSymbol("folder"), sessions: [])
                }
                buckets[key]?.sessions.append(session)
            }
            return buckets.map { key, value in
                GroupedSection(id: key, title: value.title, icon: value.icon, sessions: value.sessions)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .agent:
            var buckets: [SupportedAgent: [AgentHistorySession]] = [:]
            for session in list {
                buckets[session.agent, default: []].append(session)
            }
            return buckets.map { agent, sessions in
                GroupedSection(
                    id: agent.rawValue,
                    title: agent.displayName,
                    icon: .systemSymbol("terminal"),
                    sessions: sessions
                )
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .date:
            let calendar = Calendar.current
            var buckets: [String: (title: String, sessions: [AgentHistorySession])] = [:]
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            for session in list {
                let key: String
                let title: String
                if calendar.isDateInToday(session.updatedAt) {
                    key = "1_today"
                    title = strings.today
                } else if calendar.isDateInYesterday(session.updatedAt) {
                    key = "2_yesterday"
                    title = strings.yesterday
                } else {
                    key = "3_" + formatter.string(from: session.updatedAt)
                    title = formatter.string(from: session.updatedAt)
                }
                if buckets[key] == nil {
                    buckets[key] = (title: title, sessions: [])
                }
                buckets[key]?.sessions.append(session)
            }
            return buckets.sorted { $0.key < $1.key }.map { key, value in
                GroupedSection(id: key, title: value.title, icon: .systemSymbol("calendar"), sessions: value.sessions)
            }
        }
    }

    private var selectedSession: AgentHistorySession? {
        guard let id = history.selectedSessionID else { return nil }
        return history.sessions.first { $0.id == id }
    }

    var body: some View {
        if let session = selectedSession {
            transcriptView(session)
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            AgentHistorySessionListHeader(
                title: history.hostLabel.map {
                    strings.remoteSessionCount(filteredAndOrderedSessions.count, host: $0)
                } ?? strings.sessionCount(filteredAndOrderedSessions.count),
                isRemote: history.hostLabel != nil,
                isLoading: history.isLoadingSessions,
                strings: strings,
                refresh: { perform(.refreshAgentHistory) }
            )
            .frame(height: 40)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)

            AgentHistoryToolbar(
                query: query,
                isSearching: isSearching,
                filter: filter,
                sessions: scopedSessions,
                agents: availableAgents,
                strings: strings,
                currentDirectory: currentDirectory,
                searchChanged: { query = $0 },
                filterChanged: {
                    filter = $0
                    perform(.setAgentHistoryTimeRange($0.time))
                }
            )
            .frame(height: 28)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.bottom, 8)

            if history.isLoadingSessions && history.sessions.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "clock.arrow.circlepath",
                    title: strings.loading,
                    message: nil,
                    showsProgress: true
                )
            } else if history.sessions.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "clock.badge.questionmark",
                    title: strings.noSessions,
                    message: strings.noSessionsMessage
                )
            } else if filteredAndOrderedSessions.isEmpty, isSearching {
                AgentHistoryEmptyView(
                    systemImage: "magnifyingglass",
                    title: strings.searchingSessions,
                    message: strings.searchingSessionsMessage,
                    showsProgress: true
                )
            } else if filteredAndOrderedSessions.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "magnifyingglass",
                    title: strings.noMatches,
                    message: strings.noMatchesMessage
                )
            } else {
                InspectorAgentHistoryList(
                    rows: nativeSessionRows,
                    query: committedQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                    strings: strings,
                    select: selectSession,
                    toggleGroup: { id in
                        if collapsedGroupIDs.contains(id) {
                            collapsedGroupIDs.remove(id)
                        } else {
                            collapsedGroupIDs.insert(id)
                        }
                    },
                    loadMore: { visibleSessionCount += 60 },
                    perform: perform
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            perform(.setAgentHistoryTimeRange(filter.time))
            scheduleSessionSearch(query, immediately: true)
        }
        .onChange(of: history.hostLabel) { _ in perform(.setAgentHistoryTimeRange(filter.time)) }
        .onChange(of: query) { value in
            visibleSessionCount = 60
            scheduleSessionSearch(value)
        }
        .onChange(of: history.sessions.count) { _ in
            scheduleSessionSearch(query, immediately: true)
        }
        .onChange(of: filter) { _ in
            visibleSessionCount = 60
            scheduleSessionSearch(query, immediately: true)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var nativeSessionRows: [InspectorAgentHistoryListRow] {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        func row(_ session: AgentHistorySession) -> InspectorAgentHistoryListRow {
            let snippet = searchMatches[session.id]?.snippet
            return .session(session, snippet: !needle.isEmpty && snippet != session.title ? snippet : nil)
        }
        if filter.grouping == .none {
            let sessions = filteredAndOrderedSessions
            var rows = sessions.prefix(visibleSessionCount).map(row)
            if visibleSessionCount < sessions.count {
                rows.append(.more(remaining: sessions.count - visibleSessionCount))
            }
            return rows
        }
        return groupedSections.flatMap { section in
            let collapsed = collapsedGroupIDs.contains(section.id)
            var rows: [InspectorAgentHistoryListRow] = [
                .group(id: section.id, title: section.title, count: section.sessions.count, collapsed: collapsed),
            ]
            if !collapsed { rows.append(contentsOf: section.sessions.map(row)) }
            return rows
        }
    }

    private func selectSession(_ session: AgentHistorySession) {
        // A query that only matched the title would filter the conversation
        // down to nothing.
        let needle = searchMatches[session.id]?.isInTranscript == true
            ? committedQuery.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        transcriptSearch = needle
        isTranscriptSearchVisible = !needle.isEmpty
        if !needle.isEmpty { transcriptSearchFocusRequestID &+= 1 }
        perform(.selectAgentHistorySession(id: session.id))
    }

    private func toggleTranscriptSearch() {
        isTranscriptSearchVisible.toggle()
        if isTranscriptSearchVisible {
            transcriptSearchFocusRequestID &+= 1
        } else {
            transcriptSearch = ""
        }
    }

    private func closeTranscriptSearch() {
        isTranscriptSearchVisible = false
        transcriptSearch = ""
    }

    private func scheduleSessionSearch(
        _ value: String,
        immediately: Bool = false
    ) {
        searchTask?.cancel()
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            committedQuery = ""
            searchMatches = [:]
            isSearching = false
            return
        }
        let sessions = filter.filtered(history.sessions, currentDirectory: currentDirectory)
        isSearching = true
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            committedQuery = needle
            searchMatches = [:]
            for await matches in AgentHistoryStore.searchUpdates(
                sessions: sessions,
                query: needle
            ) {
                guard !Task.isCancelled else { return }
                searchMatches = matches
            }
            guard !Task.isCancelled else { return }
            isSearching = false
            searchTask = nil
        }
    }

    private func transcriptMessages(
        _ messages: [AgentHistoryMessage],
        aroundMatchesFor query: String
    ) -> [AgentHistoryMessage] {
        guard !query.isEmpty else { return messages }
        var indexes = Set<Int>()
        for index in messages.indices where
            messages[index].text.range(
                of: query,
                options: .caseInsensitive
            ) != nil {
            for nearby in max(messages.startIndex, index - 1)...min(
                messages.index(before: messages.endIndex),
                index + 1
            ) {
                indexes.insert(nearby)
            }
        }
        return indexes.sorted().map { messages[$0] }
    }

    private func transcriptView(_ session: AgentHistorySession) -> some View {
        let needle = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allMessages = history.transcript?.sessionID == session.id
            ? (history.transcript?.messages ?? [])
            : []
        let matchCount = needle.isEmpty ? 0 : allMessages.count {
            $0.text.range(of: needle, options: .caseInsensitive) != nil
        }
        let matchingMessages = transcriptMessages(
            allMessages,
            aroundMatchesFor: needle
        )

        return VStack(spacing: 0) {
            AgentHistoryTranscriptToolbar(
                session: session,
                strings: strings,
                query: transcriptSearch,
                isSearchVisible: isTranscriptSearchVisible,
                focusRequestID: transcriptSearchFocusRequestID,
                matchCount: matchCount,
                onQueryChange: { transcriptSearch = $0 },
                onToggleSearch: toggleTranscriptSearch,
                onEscape: closeTranscriptSearch,
                onBack: {
                    closeTranscriptSearch()
                    perform(.clearAgentHistorySelection)
                },
                onResume: { perform(.resumeAgentHistorySession(id: session.id)) },
                onFork: { perform(.forkAgentHistorySession(id: session.id, placement: $0)) }
            )
            .frame(height: isTranscriptSearchVisible ? 72 : 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                if let workingDirectory = session.workingDirectory {
                    Text(workingDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(workingDirectory)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.bottom, 9)

            Divider()

            if history.isLoadingTranscript {
                AgentHistoryEmptyView(
                    systemImage: "text.bubble",
                    title: strings.loadingTranscript,
                    message: nil,
                    showsProgress: true
                )
            } else if let transcript = history.transcript,
                      transcript.sessionID == session.id,
                      transcript.messages.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "text.bubble",
                    title: strings.emptyTranscript,
                    message: strings.emptyTranscriptMessage
                )
            } else if matchingMessages.isEmpty, !needle.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "magnifyingglass",
                    title: strings.noMatches,
                    message: strings.noMatchesMessage
                )
            } else if let transcript = history.transcript,
                      transcript.sessionID == session.id {
                VStack(spacing: 0) {
                    AgentHistoryTranscriptTable(
                        messages: matchingMessages,
                        agentName: session.agent.displayName,
                        strings: strings,
                        highlightText: needle,
                        onFork: session.supportsFork
                            ? { perform(.forkAgentHistorySession(id: session.id)) }
                            : nil,
                        onFind: toggleTranscriptSearch
                    )

                    if transcript.wasTruncated && needle.isEmpty {
                        Text(strings.truncated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, InspectorContentMetrics.leadingInset)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AgentHistoryEmptyView: View {
    let systemImage: String
    let title: String
    let message: String?
    var showsProgress = false

    var body: some View {
        VStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 25))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
