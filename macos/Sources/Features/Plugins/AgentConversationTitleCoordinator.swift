import AppKit
import Combine
import Foundation
import ObjectiveC

/// Finds the title of the Agent conversation a pane is running and keeps it in
/// `AgentConversationTitleStore`.
///
/// A title is looked for when a pane becomes bound to a conversation and when
/// the Agent starts or finishes a turn. The Agent's own title is preferred;
/// the opening prompt, cut short, stands in until one exists; and when the
/// mode allows it and the Agent has not named the conversation, the opening
/// prompt is summarised once by the configured endpoint.
///
/// Work is keyed by conversation, so several panes showing one conversation
/// share one lookup, and it stops when the last tab that asked for it is gone.
@MainActor
final class AgentConversationTitleCoordinator {
    typealias Key = AgentConversationTitleStore.Key

    /// One conversation and the host its transcript is on.
    struct Target: Equatable, Sendable {
        let agent: SupportedAgent
        let conversationID: AgentConversationID
        /// The SSH destination of a remote conversation; nil for a local one.
        let remoteHost: String?

        var key: Key { .init(agent: agent, conversationID: conversationID) }
    }

    enum Trigger: String, Equatable, Sendable {
        /// A pane became bound to the conversation.
        case bound
        /// The Agent started a turn.
        case working
        /// The Agent finished a turn.
        case done
    }

    typealias SeedLoader = @Sendable (Target) async -> AgentHistoryStore.TitleSeed?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let shared = AgentConversationTitleCoordinator(
        // App-hosted tests create real tabs; those must not read the user's
        // session stores or reach an endpoint. Tests drive their own instance.
        isEnabled: !OMGApplicationEnvironment.isRunningTests
    )

    /// Waits before each look at the transcript after a turn starts. An Agent
    /// may create the file, and name the conversation, a moment after the
    /// first prompt is sent.
    nonisolated static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
    ]

    let store: AgentConversationTitleStore
    private let generator: any AITitleGenerating
    private let loadSeed: SeedLoader
    private let mode: @MainActor () -> AgentSessionTitleMode
    private let sleep: Sleep
    private let now: () -> Date
    private let retryDelays: [Duration]
    /// Further looks the Agent gets to name a conversation once its opening
    /// prompt has been read, before that prompt is summarised instead.
    private let nativeGraceAttempts: Int
    /// A conversation whose transcript held a prompt and no name is not read
    /// again on every turn.
    private let settleInterval: TimeInterval
    private let isEnabled: Bool

    private struct Flight {
        let token: UUID
        let task: Task<Void, Never>
        var owners: Set<UUID>
        /// A turn finished while the conversation was being read.
        var sawCompletedTurn = false
    }

    private var flights: [Key: Flight] = [:]
    /// Conversations that had their one second look after a completed turn.
    private var completedTurnReads = Set<Key>()
    private var settledAt: [Key: Date] = [:]
    /// The newest queued read per host. Reads of one host run in turn, so a
    /// restored window full of Agent tabs does not scan the stores in parallel
    /// or open a connection per tab.
    private var seedLanes: [String: Task<Void, Never>] = [:]

    init(
        store: AgentConversationTitleStore = .shared,
        generator: any AITitleGenerating = AITitleService.shared,
        loadSeed: @escaping SeedLoader = { target in
            await AgentHistoryStore.titleSeed(
                agent: target.agent, conversationID: target.conversationID, remoteHost: target.remoteHost
            )
        },
        mode: @escaping @MainActor () -> AgentSessionTitleMode = { OhMyGhosttySettings.shared.agentSessionTitleMode },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init,
        retryDelays: [Duration] = AgentConversationTitleCoordinator.defaultRetryDelays,
        nativeGraceAttempts: Int = 2,
        settleInterval: TimeInterval = 10 * 60,
        isEnabled: Bool = true
    ) {
        self.store = store
        self.generator = generator
        self.loadSeed = loadSeed
        self.mode = mode
        self.sleep = sleep
        self.now = now
        self.retryDelays = retryDelays
        self.nativeGraceAttempts = max(nativeGraceAttempts, 0)
        self.settleInterval = settleInterval
        self.isEnabled = isEnabled
    }

    /// Asks for the title of `target`. Does nothing when the mode is off, when
    /// the conversation already has the best title this trigger could bring,
    /// or when it is already being read.
    ///
    /// - Parameter owner: Identifies the caller to `release(owner:)`.
    func request(_ target: Target, trigger: Trigger, owner: UUID) {
        guard isEnabled else { return }
        guard mode() != .off else {
            skip(target, trigger, "titles are off")
            return
        }
        let key = target.key
        if flights[key] != nil {
            flights[key]?.owners.insert(owner)
            if trigger == .done { flights[key]?.sawCompletedTurn = true }
            skip(target, trigger, "already being read")
            return
        }
        let source = store.record(agent: target.agent, conversationID: target.conversationID)?.source
        let delays: [Duration]
        switch trigger {
        case .done:
            // The one planned second look: the Agent may have named the
            // conversation while it worked. A generated title can still be
            // replaced by the Agent's own, never by another generated one.
            guard source != .native else {
                skip(target, trigger, "has the Agent's title")
                return
            }
            guard completedTurnReads.insert(key).inserted else {
                skip(target, trigger, "had its look after a turn")
                return
            }
            delays = [.zero]
        case .bound, .working:
            guard source == nil || source == .prompt else {
                skip(target, trigger, "has a \(source?.rawValue ?? "stored") title")
                return
            }
            if let settled = settledAt[key], now().timeIntervalSince(settled) < settleInterval {
                skip(target, trigger, "read recently, the Agent named nothing")
                return
            }
            // Only a turn that just started can be ahead of its transcript.
            delays = trigger == .working ? retryDelays : Array(retryDelays.prefix(1))
        }
        AgentConversationTitleLog.info(
            "requested \(Self.describe(target)) trigger=\(trigger.rawValue) " +
                "stored=\(source?.rawValue ?? "none") reads=\(delays.count)"
        )
        start(target, delays: delays, owners: [owner])
    }

    /// An Agent, the start of a conversation ID and where its transcript is.
    /// Host names stay out of the log.
    nonisolated private static func describe(_ target: Target) -> String {
        "\(target.agent.rawValue) \(AgentConversationTitleLog.tag(target.conversationID)) " +
            (target.remoteHost == nil ? "local" : "remote")
    }

    private func skip(_ target: Target, _ trigger: Trigger, _ reason: String) {
        AgentConversationTitleLog.debug(
            "skipped \(Self.describe(target)) trigger=\(trigger.rawValue): \(reason)"
        )
    }

    /// Forgets a caller. Work nobody else asked for is cancelled.
    func release(owner: UUID) {
        for (key, flight) in flights where flight.owners.contains(owner) {
            if flight.owners.count == 1 {
                flight.task.cancel()
                flights[key] = nil
            } else {
                flights[key]?.owners.remove(owner)
            }
        }
    }

    /// The number of conversations being read.
    var inFlightCount: Int { flights.count }

    /// Returns once nothing requested so far is still running.
    func waitUntilIdle() async {
        while let flight = flights.values.first {
            await flight.task.value
            // A cancelled read is removed by `release`; one that finished
            // removes itself before its task ends.
            await Task.yield()
        }
    }

    private func start(_ target: Target, delays: [Duration], owners: Set<UUID>) {
        let token = UUID()
        let task = Task { [weak self] in
            await self?.read(target, delays: delays)
            self?.finish(target, token: token)
        }
        flights[target.key] = Flight(token: token, task: task, owners: owners)
    }

    private func finish(_ target: Target, token: UUID) {
        guard let flight = flights[target.key], flight.token == token else { return }
        flights[target.key] = nil
        guard flight.sawCompletedTurn, !flight.task.isCancelled else { return }
        for owner in flight.owners {
            request(target, trigger: .done, owner: owner)
        }
    }

    private func read(_ target: Target, delays: [Duration]) async {
        var prompt: String?
        var graceLeft = nativeGraceAttempts
        for delay in delays {
            if delay > .zero {
                do { try await self.sleep(delay) } catch { return }
            }
            guard !Task.isCancelled, mode() != .off else { return }
            let seed = await loadSeedInTurn(target)
            guard !Task.isCancelled else { return }
            if let native = seed?.native {
                store.set(native, source: .native, agent: target.agent,
                          conversationID: target.conversationID, remoteHost: target.remoteHost)
                return
            }
            guard let found = seed?.firstPrompt else { continue }
            if prompt == nil {
                store.set(found, source: .prompt, agent: target.agent,
                          conversationID: target.conversationID, remoteHost: target.remoteHost)
            } else {
                graceLeft -= 1
            }
            prompt = found
            if graceLeft <= 0 { break }
        }
        // No transcript yet: the next turn asks again.
        guard let prompt else {
            AgentConversationTitleLog.info(
                "no title \(Self.describe(target)): nothing to read after \(delays.count) look(s)"
            )
            return
        }
        settledAt[target.key] = now()
        await generate(target, prompt: prompt)
    }

    private func generate(_ target: Target, prompt: String) async {
        let currentMode = mode()
        guard currentMode == .generate else {
            AgentConversationTitleLog.info(
                "not generated \(Self.describe(target)): mode is \(currentMode.rawValue), the prompt stands in"
            )
            return
        }
        let source = store.record(agent: target.agent, conversationID: target.conversationID)?.source
        guard source == nil || source == .prompt else { return }
        // Only the opening prompt leaves the process; the service redacts and bounds it.
        guard let title = await generator.title(forFirstPrompt: prompt) else {
            // The service tells apart an endpoint that is not set, paused or failing.
            AgentConversationTitleLog.info(
                "not generated \(Self.describe(target)): the endpoint gave no title, the prompt stands in"
            )
            return
        }
        store.set(title, source: .generated, agent: target.agent,
                  conversationID: target.conversationID, remoteHost: target.remoteHost)
    }

    private func loadSeedInTurn(_ target: Target) async -> AgentHistoryStore.TitleSeed? {
        let lane = target.remoteHost ?? ""
        let previous = seedLanes[lane]
        let loadSeed = self.loadSeed
        let load = Task { () -> AgentHistoryStore.TitleSeed? in
            _ = await previous?.value
            guard !Task.isCancelled else { return nil }
            return await loadSeed(target)
        }
        seedLanes[lane] = Task { _ = await load.value }
        return await withTaskCancellationHandler {
            await load.value
        } onCancel: {
            load.cancel()
        }
    }
}

/// Watches one tab's panes and asks the coordinator for their conversations'
/// titles. Owned by its controller, so it stops with it.
@MainActor
final class AgentConversationTitleTracker {
    typealias Target = AgentConversationTitleCoordinator.Target

    private weak var controller: TerminalController?
    private let coordinator: AgentConversationTitleCoordinator
    private let owner = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var targets: [UUID: Target] = [:]
    private var states: [UUID: TabActivityState] = [:]
    /// Why each Agent pane without a readable conversation has none, as last
    /// logged, so the reason is reported when it changes and not on every signal.
    private var unreadable: [UUID: String] = [:]
    private var shownTitle: String?
    private var evaluationScheduled = false

    init(controller: TerminalController, coordinator: AgentConversationTitleCoordinator = .shared) {
        self.controller = controller
        self.coordinator = coordinator
        let changes: [AnyPublisher<Void, Never>] = [
            controller.$agentResumeDescriptors.map { _ in () }.eraseToAnyPublisher(),
            controller.$agentActivities.map { _ in () }.eraseToAnyPublisher(),
            // A remote conversation can be read once its connection is ready.
            // The publisher must not retain the controller that owns this object.
            NotificationCenter.default.publisher(for: .terminalPaneSessionContextsDidChange)
                .filter { [weak controller] notification in
                    guard let controller, let sender = notification.object as? TerminalController else { return false }
                    return sender === controller
                }
                .map { _ in () }
                .eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] _ in self?.scheduleEvaluation() }
            .store(in: &subscriptions)
        OhMyGhosttySettings.shared.$agentSessionTitleMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.modeChanged() }
            .store(in: &subscriptions)
        coordinator.store.titleChanges
            .sink { [weak self] key in self?.titleChanged(key) }
            .store(in: &subscriptions)
        scheduleEvaluation()
    }

    deinit {
        let coordinator = self.coordinator
        let owner = self.owner
        if Thread.isMainThread {
            MainActor.assumeIsolated { coordinator.release(owner: owner) }
        } else {
            Task { @MainActor in coordinator.release(owner: owner) }
        }
    }

    /// Published values are sent before they are stored, and one signal can
    /// change the descriptor and the activity. Read both once they settled.
    private func scheduleEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.evaluationScheduled = false
            self.evaluate()
        }
    }

    private func evaluate() {
        guard let controller else { return }
        var nextTargets: [UUID: Target] = [:]
        var nextStates: [UUID: TabActivityState] = [:]
        var nextUnreadable: [UUID: String] = [:]
        for surface in controller.surfaceTree {
            if let state = controller.agentActivity(for: surface)?.state {
                nextStates[surface.id] = state
            }
            guard let descriptor = controller.agentResumeDescriptor(for: surface) else { continue }
            // The same rule the Inspector uses for when a pane's conversation
            // may be read: never the old side of a connection handoff.
            guard let session = controller.paneSessionContext(for: surface),
                  let binding = PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session)
            else {
                // Without an ID there is no conversation to title: the Agent
                // has not reported one, or reports none at all.
                let reason = descriptor.conversationID == nil
                    ? "the pane has no conversation ID" : "its connection is not ready"
                nextUnreadable[surface.id] = "\(descriptor.agent.rawValue) \(descriptor.scope.rawValue): \(reason)"
                continue
            }
            nextTargets[surface.id] = Target(
                agent: binding.agent, conversationID: binding.conversationID, remoteHost: binding.remoteHost
            )
        }
        for (surfaceID, reason) in nextUnreadable where unreadable[surfaceID] != reason {
            AgentConversationTitleLog.info("no lookup \(reason)")
        }
        unreadable = nextUnreadable
        for (surfaceID, target) in nextTargets {
            let state = nextStates[surfaceID]
            let newlyBound = targets[surfaceID] != target
            guard newlyBound || state != states[surfaceID],
                  let trigger = Self.trigger(for: state, newlyBound: newlyBound) else { continue }
            coordinator.request(target, trigger: trigger, owner: owner)
        }
        targets = nextTargets
        states = nextStates
        // The window title names the conversation too, and a pane can move to
        // another conversation without its terminal title changing.
        let title = controller.tabAgentConversationTitle
        if title != shownTitle {
            shownTitle = title
            controller.refreshPresentedTerminalTitle()
        }
    }

    /// What a pane's state asks for: a conversation it just became bound to is
    /// looked up whatever the Agent is doing; after that only a turn starting
    /// or finishing is a reason to look again.
    static func trigger(
        for state: TabActivityState?, newlyBound: Bool
    ) -> AgentConversationTitleCoordinator.Trigger? {
        switch state {
        case .working?: return .working
        case .done?: return .done
        default: return newlyBound ? .bound : nil
        }
    }

    private func modeChanged() {
        // Conversations bound while titles were off are looked up now.
        targets = [:]
        states = [:]
        // Sent before the setting is stored; redraw once it is.
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.controller else { return }
            controller.objectWillChange.send()
            self.shownTitle = controller.tabAgentConversationTitle
            controller.refreshPresentedTerminalTitle()
        }
        scheduleEvaluation()
    }

    private func titleChanged(_ key: AgentConversationTitleStore.Key) {
        guard let controller, controller.agentResumeDescriptors.values.contains(where: {
            $0.agent == key.agent && $0.conversationID == key.conversationID
        }) else { return }
        // Tab rows and tab chrome redraw on the controller's change signal;
        // the window title is recomputed through the usual path.
        controller.objectWillChange.send()
        shownTitle = controller.tabAgentConversationTitle
        controller.refreshPresentedTerminalTitle()
    }
}

private nonisolated(unsafe) var agentConversationTitleTrackerKey: UInt8 = 0

extension AgentConversationTitleStore {
    /// The one rule for whether a pane shows a conversation title: the mode
    /// allows it and the pane's current resume descriptor names a conversation
    /// that has one. Only the descriptor decides, so a new conversation in the
    /// same pane switches title by itself, a connection handoff does not blank
    /// it, and the title goes when the Agent ends and the descriptor is cleared.
    func title(for descriptor: AgentResumeDescriptor?, mode: AgentSessionTitleMode) -> String? {
        guard mode != .off, let descriptor, let conversationID = descriptor.conversationID else { return nil }
        return title(agent: descriptor.agent, conversationID: conversationID)
    }
}

extension TerminalController {
    /// The conversation title `surface` shows, if any. Tab rows, tab chrome,
    /// the window title, the command palette and the workspace picker all ask
    /// here; a manual tab name still wins wherever it applies.
    func agentConversationTitle(for surface: Ghostty.SurfaceView?) -> String? {
        AgentConversationTitleStore.shared.title(
            for: agentResumeDescriptor(for: surface),
            mode: OhMyGhosttySettings.shared.agentSessionTitleMode
        )
    }

    /// The conversation title of the pane that names this tab.
    var tabAgentConversationTitle: String? {
        agentConversationTitle(for: focusedSurface ?? surfaceTree.first)
    }

    /// True when this tab's row and chrome show a name with the place below
    /// it: the tab has a manual name or its pane a conversation title.
    ///
    /// This is `TerminalTabPresentationResolver.resolve` returning a subtitle,
    /// without building one: a few dictionary lookups, no path formatting.
    /// The sidebar asks for every row on every refresh to pick the row height.
    var tabTitleHasSubtitle: Bool {
        guard let surface = focusedSurface ?? surfaceTree.first else { return false }
        return titleOverride != nil || agentConversationTitle(for: surface) != nil
    }

    /// Starts looking up conversation titles for this tab's panes. Calling it
    /// again changes nothing; tracking ends when the controller is released.
    func startAgentConversationTitleTracking(coordinator: AgentConversationTitleCoordinator = .shared) {
        guard objc_getAssociatedObject(self, &agentConversationTitleTrackerKey) == nil else { return }
        objc_setAssociatedObject(
            self,
            &agentConversationTitleTrackerKey,
            AgentConversationTitleTracker(controller: self, coordinator: coordinator),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
