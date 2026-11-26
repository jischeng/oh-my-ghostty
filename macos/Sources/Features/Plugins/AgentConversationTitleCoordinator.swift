import AppKit
import Combine
import Foundation
import ObjectiveC

/// Finds the title of the Agent conversation a pane is running and keeps it in
/// `AgentConversationTitleStore`.
///
/// A title is looked for when a pane becomes bound to a conversation and when
/// the Agent starts or finishes a turn. The Agent's own title is preferred;
/// when the mode allows it and the Agent has not named the conversation after
/// its grace window, the opening prompt is summarised once by the configured
/// endpoint, or sanitized to a short fallback if no endpoint answers.
///
/// Work is keyed by conversation, so several panes showing one conversation
/// share one lookup, and it stops when the last tab that asked for it is gone.
@MainActor
final class AgentConversationTitleCoordinator: ObservableObject {
    typealias Key = AgentConversationTitleStore.Key

    /// One conversation and the host its transcript is on.
    struct Target: Equatable, Sendable {
        let agent: SupportedAgent
        let conversationID: AgentConversationID
        /// The SSH destination of a remote conversation; nil for a local one.
        let remoteHost: String?
        /// Optional workspace/repository folder name for shorthand context; excluded from identity equality.
        let projectName: String?

        init(
            agent: SupportedAgent,
            conversationID: AgentConversationID,
            remoteHost: String?,
            projectName: String? = nil
        ) {
            self.agent = agent
            self.conversationID = conversationID
            self.remoteHost = remoteHost
            self.projectName = projectName
        }

        var key: Key { .init(agent: agent, conversationID: conversationID) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.agent == rhs.agent
                && lhs.conversationID == rhs.conversationID
                && lhs.remoteHost == rhs.remoteHost
        }
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
    private let alwaysUseAI: @MainActor () -> Bool
    private let language: @MainActor () -> OhMyGhosttyLanguage
    private let sleep: Sleep
    private let now: () -> Date
    private let retryDelays: [Duration]
    /// Further looks the Agent gets to name a conversation once its opening
    /// prompt has been read, before that prompt is summarised instead.
    private let nativeGraceAttempts: Int
    /// A conversation whose transcript held a prompt and no name is not read
    /// again on every turn start.
    private let settleInterval: TimeInterval
    private let isEnabled: Bool

    @Published private(set) var generatingTargets: Set<Key> = []
    @Published private(set) var manualRenamingTabIDs: Set<UUID> = []
    /// Sent after `generatingTargets` or `manualRenamingTabIDs` mutates so chrome
    /// observers read the updated state immediately without `@Published` `willSet` lag.
    let generationStateChanges = PassthroughSubject<Void, Never>()

    private struct Flight {
        let token: UUID
        let epoch: UInt64
        let task: Task<Void, Never>
        var owners: Set<UUID>
        var generatingOwners: Set<UUID>
        var manualTabsByOwner: [UUID: Set<UUID>] = [:]
        var onForcedGenerated: [@MainActor () -> Void] = []
        var forced = false
        /// Set when a forced manual request arrived while an automatic LLM call was already in flight,
        /// so if the automatic call fails/sheds, `finish` runs one forced retry instead of dropping it.
        var pendingForcedRetry = false
        var isGenerating = false
        /// A turn finished while the conversation was being read.
        var sawCompletedTurn = false
        /// Settings (`aiTitleRoute`, `language`, `alwaysUseAI`, or `mode`) changed while in flight.
        var needsReevaluation = false

        var manualTabIDs: Set<UUID> {
            manualTabsByOwner.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        }
    }

    private var flights: [Key: Flight] = [:]
    private var settledAt: [Key: Date] = [:]
    private var configurationEpoch: UInt64 = 0
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
        alwaysUseAI: @escaping @MainActor () -> Bool = { OhMyGhosttySettings.shared.agentSessionTitleAlwaysUseAI },
        language: @escaping @MainActor () -> OhMyGhosttyLanguage = { OhMyGhosttySettings.shared.language },
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
        self.alwaysUseAI = alwaysUseAI
        self.language = language
        self.sleep = sleep
        self.now = now
        self.retryDelays = retryDelays
        self.nativeGraceAttempts = max(nativeGraceAttempts, 0)
        self.settleInterval = settleInterval
        self.isEnabled = isEnabled
    }

    private var prefersGeneratedTitles: Bool {
        mode() == .generate && alwaysUseAI()
    }

    /// Whether AI or manual title generation is currently running for `controller`.
    func isGeneratingTitle(for controller: TerminalController) -> Bool {
        if manualRenamingTabIDs.contains(controller.tabSessionID) {
            return true
        }
        guard !generatingTargets.isEmpty else { return false }
        if let override = controller.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return false
        }
        for surface in controller.surfaceTree where !surface.hasUserSetTitle {
            guard let descriptor = controller.agentResumeDescriptor(for: surface),
                  let conversationID = descriptor.conversationID else { continue }
            if generatingTargets.contains(Key(agent: descriptor.agent, conversationID: conversationID)) {
                return true
            }
        }
        return false
    }

    /// Whether an explicit manual or workspace-batch rename is in flight for `controller`.
    func isManualRenaming(for controller: TerminalController) -> Bool {
        manualRenamingTabIDs.contains(controller.tabSessionID)
    }

    private func syncPublishedFlightState() {
        let nextGenerating = Set(flights.compactMap { key, flight in
            flight.isGenerating ? key : nil
        })
        let nextManual = flights.values.reduce(into: Set<UUID>()) { result, flight in
            result.formUnion(flight.manualTabIDs)
        }
        let generatingChanged = generatingTargets != nextGenerating
        let manualChanged = manualRenamingTabIDs != nextManual
        guard generatingChanged || manualChanged else { return }
        if generatingChanged { generatingTargets = nextGenerating }
        if manualChanged { manualRenamingTabIDs = nextManual }
        generationStateChanges.send()
    }

    /// Asks for the title of `target`.
    ///
    /// - Parameters:
    ///   - owner: Identifies the caller to `release(owner:)`.
    ///   - allowsGeneration: False while the calling tab has a manual override,
    ///     skipping background LLM requests until the override is cleared.
    ///   - force: When true, bypasses cached titles and `settleInterval` to
    ///     immediately re-fetch the seed and regenerate the title.
    ///   - manualTabID: The tab session ID when initiated from an explicit user
    ///     Auto-Rename action, enabling menu and row progress feedback.
    func request(
        _ target: Target,
        trigger: Trigger,
        owner: UUID,
        allowsGeneration: Bool = true,
        force: Bool = false,
        manualTabID: UUID? = nil,
        onForcedGenerated: (@MainActor () -> Void)? = nil
    ) {
        guard isEnabled else { return }
        let currentMode = mode()
        guard force || currentMode != .off else {
            skip(target, trigger, "titles are off")
            return
        }
        let key = target.key
        var initialOwners: Set<UUID> = [owner]
        var initialGeneratingOwners: Set<UUID> = allowsGeneration ? [owner] : []
        var initialManualTabs: [UUID: Set<UUID>] = [:]
        var initialForcedCallbacks: [@MainActor () -> Void] = []
        if let manualTabID {
            initialManualTabs[owner] = [manualTabID]
        }
        if let onForcedGenerated {
            initialForcedCallbacks.append(onForcedGenerated)
        }
        if let existingFlight = flights[key] {
            let alreadyGenerating = existingFlight.isGenerating || generatingTargets.contains(key)
            if force && !existingFlight.forced && !alreadyGenerating {
                existingFlight.task.cancel()
                initialOwners.formUnion(existingFlight.owners)
                initialGeneratingOwners.formUnion(existingFlight.generatingOwners)
                for (existingOwner, tabs) in existingFlight.manualTabsByOwner {
                    initialManualTabs[existingOwner, default: []].formUnion(tabs)
                }
                initialForcedCallbacks = existingFlight.onForcedGenerated + initialForcedCallbacks
                flights[key] = nil
            } else {
                flights[key]?.owners.insert(owner)
                if allowsGeneration {
                    flights[key]?.generatingOwners.insert(owner)
                } else {
                    flights[key]?.generatingOwners.remove(owner)
                }
                if let manualTabID {
                    flights[key]?.manualTabsByOwner[owner, default: []].insert(manualTabID)
                }
                if let onForcedGenerated {
                    flights[key]?.onForcedGenerated.append(onForcedGenerated)
                }
                if force {
                    if !existingFlight.forced {
                        flights[key]?.pendingForcedRetry = true
                    }
                    flights[key]?.forced = true
                    if !(flights[key]?.generatingOwners.isEmpty ?? true) {
                        flights[key]?.isGenerating = true
                    }
                }
                if trigger == .done { flights[key]?.sawCompletedTurn = true }
                if existingFlight.epoch != configurationEpoch {
                    flights[key]?.needsReevaluation = true
                }
                syncPublishedFlightState()
                skip(target, trigger, "already being read")
                return
            }
        }
        let existingRecord = store.record(agent: target.agent, conversationID: target.conversationID)
        let source = existingRecord?.source
        let isChinese = SettingsStrings(language: language()).isChinese
        let alwaysGenerate = currentMode == .generate && alwaysUseAI()
        let canUpgradeNative = existingRecord.map { record in
            record.source == .native
                && currentMode == .generate
                && allowsGeneration
                && alwaysGenerate
        } ?? false
        let canRestoreNativeMode = existingRecord.map { record in
            record.source != .native
                && record.isUserRequested != true
                && currentMode == .native
        } ?? false
        let canLocalizeGenerated = existingRecord.map { record in
            record.source == .generated
                && currentMode == .generate
                && allowsGeneration
                && isChinese
                && !AgentConversationTitleStore.containsCJK(record.title)
                && settledAt[key] == nil
        } ?? false
        let delays: [Duration]
        if force {
            settledAt[key] = nil
            delays = [.zero]
        } else {
            switch trigger {
            case .done:
                // Every completed turn checks the transcript once without waiting so
                // Claude `/rename` (`custom-title`) and Codex `thread_name` update live.
                delays = [.zero]
            case .bound, .working:
                guard source == nil || source == .prompt || canUpgradeNative || canRestoreNativeMode || canLocalizeGenerated else {
                    skip(target, trigger, "has a \(source?.rawValue ?? "stored") title")
                    return
                }
                let canUpgradePrompt = source == .prompt && currentMode == .generate && allowsGeneration
                if !canUpgradePrompt, !canRestoreNativeMode, !canLocalizeGenerated,
                   let settled = settledAt[key],
                   now().timeIntervalSince(settled) < settleInterval {
                    skip(target, trigger, "read recently, the Agent named nothing")
                    return
                }
                if canUpgradeNative || canRestoreNativeMode || canLocalizeGenerated {
                    delays = [.zero]
                } else if source == .prompt || settledAt[key] != nil {
                    // Once a prompt was already read, the transcript exists: check once without grace retries.
                    delays = canUpgradePrompt ? [.zero] : Array(retryDelays.prefix(1))
                } else {
                    // Only a turn that just started can be ahead of its transcript.
                    delays = trigger == .working ? retryDelays : Array(retryDelays.prefix(1))
                }
            }
        }
        AgentConversationTitleLog.info(
            "requested \(Self.describe(target)) trigger=\(trigger.rawValue) " +
                "stored=\(source?.rawValue ?? "none") reads=\(delays.count) force=\(force)"
        )
        start(
            target,
            delays: delays,
            owners: initialOwners,
            generatingOwners: initialGeneratingOwners,
            manualTabsByOwner: initialManualTabs,
            onForcedGenerated: initialForcedCallbacks,
            forced: force,
            startsGenerating: force && !initialGeneratingOwners.isEmpty
        )
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
        var mutated = false
        for (key, flight) in flights where flight.owners.contains(owner) {
            mutated = true
            if flight.owners.count == 1 {
                flight.task.cancel()
                flights[key] = nil
            } else {
                flights[key]?.owners.remove(owner)
                flights[key]?.generatingOwners.remove(owner)
                flights[key]?.manualTabsByOwner.removeValue(forKey: owner)
            }
        }
        if mutated {
            syncPublishedFlightState()
        }
    }

    /// The number of conversations being read.
    var inFlightCount: Int { flights.count }

    /// Returns once nothing requested so far is still running.
    func waitUntilIdle() async {
        while let flight = flights.values.first {
            await flight.task.value
            await Task.yield()
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func start(
        _ target: Target,
        delays: [Duration],
        owners: Set<UUID>,
        generatingOwners: Set<UUID>,
        manualTabsByOwner: [UUID: Set<UUID>],
        onForcedGenerated: [@MainActor () -> Void] = [],
        forced: Bool,
        startsGenerating: Bool
    ) {
        let token = UUID()
        let epoch = configurationEpoch
        let task = Task { [weak self] in
            await self?.read(target, delays: delays, force: forced)
            self?.finish(target, token: token)
        }
        flights[target.key] = Flight(
            token: token,
            epoch: epoch,
            task: task,
            owners: owners,
            generatingOwners: generatingOwners,
            manualTabsByOwner: manualTabsByOwner,
            onForcedGenerated: onForcedGenerated,
            forced: forced,
            isGenerating: startsGenerating
        )
        syncPublishedFlightState()
    }

    /// Clears recent-read throttling when language, naming mode, or title route changes,
    /// and schedules one fresh pass for any lookup currently in flight on the superseded config.
    func invalidateSettledState() {
        configurationEpoch &+= 1
        settledAt.removeAll()
        for key in Array(flights.keys) {
            flights[key]?.needsReevaluation = true
        }
    }

    private func markSettled(_ key: Key) {
        if let flight = flights[key], flight.epoch != configurationEpoch {
            return
        }
        settledAt[key] = now()
    }

    private func finish(_ target: Target, token: UUID) {
        guard let flight = flights[target.key], flight.token == token else { return }
        flights[target.key] = nil
        syncPublishedFlightState()
        let retryForced = flight.pendingForcedRetry
        let retryBackground = (flight.sawCompletedTurn || flight.needsReevaluation) && mode() != .off
        guard retryBackground || retryForced,
              !flight.task.isCancelled,
              isEnabled, !flight.owners.isEmpty else { return }
        start(
            target,
            delays: [.zero],
            owners: flight.owners,
            generatingOwners: flight.generatingOwners,
            manualTabsByOwner: retryForced ? flight.manualTabsByOwner : [:],
            onForcedGenerated: retryForced ? flight.onForcedGenerated : [],
            forced: retryForced,
            startsGenerating: retryForced && !flight.generatingOwners.isEmpty
        )
    }

    private func runForcedGeneratedCallbacks(for key: Key) {
        guard let callbacks = flights[key]?.onForcedGenerated, !callbacks.isEmpty else { return }
        flights[key]?.onForcedGenerated.removeAll()
        for callback in callbacks {
            callback()
        }
    }

    private func generateTitle(
        for target: Target,
        prompt: String,
        nativeTitle: String? = nil,
        force: Bool = false
    ) async -> AITitleGenerationResult {
        let token = flights[target.key]?.token
        if let token, flights[target.key]?.token == token {
            flights[target.key]?.isGenerating = true
            syncPublishedFlightState()
        }
        defer {
            if let token, flights[target.key]?.token == token {
                flights[target.key]?.isGenerating = false
                syncPublishedFlightState()
            }
        }
        let outcome = await generator.generate(
            forFirstPrompt: prompt,
            nativeTitle: nativeTitle,
            projectName: target.projectName,
            force: force
        )
        if case .generated = outcome, let token, flights[target.key]?.token == token, !Task.isCancelled {
            flights[target.key]?.pendingForcedRetry = false
            runForcedGeneratedCallbacks(for: target.key)
        }
        return Task.isCancelled ? .rejectedOrCancelled : outcome
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func sanitizedPromptFallback(_ prompt: String) -> String? {
        AITitleSanitizer.sanitize(AISecretRedactor.redact(prompt))
    }

    private func read(_ target: Target, delays: [Duration], force: Bool) async {
        if force {
            await readForced(target)
            return
        }
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
                await handleNativeTitle(
                    target,
                    native: native,
                    firstPrompt: seed?.firstPrompt,
                    isUserRenamed: seed?.isUserRenamed == true
                )
                return
            }
            guard let found = seed?.firstPrompt else { continue }
            if prompt != nil {
                graceLeft -= 1
            }
            prompt = found
            if graceLeft <= 0 { break }
        }
        guard let prompt else {
            if await upgradeCachedNativeIfNeeded(target) { return }
            AgentConversationTitleLog.info(
                "no title \(Self.describe(target)): nothing to read after \(delays.count) look(s)"
            )
            return
        }
        guard !Task.isCancelled else { return }
        let allowsGeneration = flights[target.key].map { !$0.generatingOwners.isEmpty } ?? true
        await resolveFromPrompt(target, prompt: prompt, allowsGeneration: allowsGeneration)
    }

    private func readForced(_ target: Target) async {
        guard !Task.isCancelled else { return }
        if flights[target.key] != nil {
            flights[target.key]?.pendingForcedRetry = false
        }
        let seed = await loadSeedInTurn(target)
        guard !Task.isCancelled else { return }
        let prompt = Self.nonEmptyTrimmed(seed?.firstPrompt)
        let native = Self.nonEmptyTrimmed(seed?.native)
        let existingRecord = store.record(agent: target.agent, conversationID: target.conversationID)
        // Never feed an already-generated short title back into the LLM when the transcript is unreachable.
        let cachedFallback = existingRecord?.source == .generated ? nil : Self.nonEmptyTrimmed(existingRecord?.title)
        let allowsGeneration = flights[target.key].map { !$0.generatingOwners.isEmpty } ?? true
        if allowsGeneration, let input = prompt ?? native ?? cachedFallback {
            switch await generateTitle(for: target, prompt: input, nativeTitle: native, force: true) {
            case .generated(let title):
                guard !Task.isCancelled else { return }
                markSettled(target.key)
                store.set(
                    title,
                    source: .generated,
                    agent: target.agent,
                    conversationID: target.conversationID,
                    remoteHost: target.remoteHost,
                    force: true,
                    supersededNativeTitle: native,
                    isUserRequested: true
                )
                return
            case .rejectedOrCancelled:
                if Task.isCancelled { return }
            case .unavailableOrFailed:
                break
            }
        }
        // When AI generation was unavailable or failed, never clobber an existing `.generated` title
        // with a raw `.prompt` or an unchanged auto-native title, and never write `.prompt` outside `.generate`.
        if let native {
            if seed?.isUserRenamed == true {
                runForcedGeneratedCallbacks(for: target.key)
            }
            store.set(
                native,
                source: .native,
                agent: target.agent,
                conversationID: target.conversationID,
                remoteHost: target.remoteHost,
                force: seed?.isUserRenamed == true,
                isUserRequested: seed?.isUserRenamed == true
            )
        } else if mode() == .generate, let prompt, let fallback = Self.sanitizedPromptFallback(prompt) {
            store.set(
                fallback,
                source: .prompt,
                agent: target.agent,
                conversationID: target.conversationID,
                remoteHost: target.remoteHost,
                force: false
            )
        }
    }

    private func handleNativeTitle(
        _ target: Target,
        native: String,
        firstPrompt: String?,
        isUserRenamed: Bool = false
    ) async {
        // Explicit user CLI renames (e.g. Claude `/rename`) always win over background AI shortening.
        if isUserRenamed {
            store.set(
                native,
                source: .native,
                agent: target.agent,
                conversationID: target.conversationID,
                remoteHost: target.remoteHost,
                force: true
            )
            return
        }
        let existing = store.record(agent: target.agent, conversationID: target.conversationID)
        let displayNative = AgentConversationTitleStore.displayTitle(
            native,
            columns: AgentConversationTitleStore.maximumTitleColumns
        )
        let forcedFlight = flights[target.key]?.forced == true
        let currentMode = mode()
        if currentMode == .native, !forcedFlight {
            if let existing, existing.source == .generated, existing.isUserRequested == true,
               let displayNative, existing.supersededNativeTitle == displayNative {
                return
            }
            store.set(
                native,
                source: .native,
                agent: target.agent,
                conversationID: target.conversationID,
                remoteHost: target.remoteHost,
                force: existing != nil && existing?.source != .native
            )
            return
        }
        let allowsGeneration = flights[target.key].map { !$0.generatingOwners.isEmpty } ?? true
        let alwaysGenerate = prefersGeneratedTitles
        let isChinese = SettingsStrings(language: language()).isChinese
        let shouldGenerateFromNative = allowsGeneration && (alwaysGenerate || forcedFlight)
        let needsLocalization = shouldGenerateFromNative
            && isChinese
            && existing.map({ !AgentConversationTitleStore.containsCJK($0.title) }) == true
            && settledAt[target.key] == nil
        if let existing, existing.source == .generated,
           let displayNative, existing.supersededNativeTitle == displayNative,
           !forcedFlight, !needsLocalization {
            return
        }
        if shouldGenerateFromNative {
            if let existing, existing.source == .generated, !forcedFlight, !needsLocalization {
                return
            }
            let input = Self.nonEmptyTrimmed(firstPrompt) ?? native
            switch await generateTitle(
                for: target,
                prompt: input,
                nativeTitle: native,
                force: forcedFlight
            ) {
            case .generated(let generated):
                guard !Task.isCancelled else { return }
                let stillForced = flights[target.key]?.forced == true
                if !stillForced, let flight = flights[target.key], flight.epoch != configurationEpoch {
                    return
                }
                markSettled(target.key)
                store.set(
                    generated,
                    source: .generated,
                    agent: target.agent,
                    conversationID: target.conversationID,
                    remoteHost: target.remoteHost,
                    force: true,
                    allowGeneratedOverNative: alwaysGenerate || stillForced,
                    supersededNativeTitle: native,
                    isUserRequested: stillForced
                )
                return
            case .unavailableOrFailed:
                guard !Task.isCancelled else { return }
                markSettled(target.key)
            case .rejectedOrCancelled:
                // Rejected by queue capacity, configuration switch, or task cancellation:
                // never write `settledAt` so the conversation remains eligible for retry.
                if Task.isCancelled { return }
            }
        }
        store.set(
            native,
            source: .native,
            agent: target.agent,
            conversationID: target.conversationID,
            remoteHost: target.remoteHost
        )
    }

    private func upgradeCachedNativeIfNeeded(_ target: Target) async -> Bool {
        let alwaysGenerate = prefersGeneratedTitles
        let forcedFlight = flights[target.key]?.forced == true
        guard alwaysGenerate || forcedFlight,
              let existing = store.record(agent: target.agent, conversationID: target.conversationID),
              existing.source == .native else {
            return false
        }
        let allowsGeneration = flights[target.key].map { !$0.generatingOwners.isEmpty } ?? true
        guard allowsGeneration else { return false }
        switch await generateTitle(
            for: target,
            prompt: existing.title,
            nativeTitle: existing.title,
            force: forcedFlight
        ) {
        case .generated(let generated):
            guard !Task.isCancelled else { return true }
            let stillForced = flights[target.key]?.forced == true
            if !stillForced, let flight = flights[target.key], flight.epoch != configurationEpoch {
                return true
            }
            markSettled(target.key)
            store.set(
                generated,
                source: .generated,
                agent: target.agent,
                conversationID: target.conversationID,
                remoteHost: target.remoteHost,
                force: true,
                allowGeneratedOverNative: alwaysGenerate || stillForced,
                supersededNativeTitle: existing.title,
                isUserRequested: stillForced
            )
            return true
        case .unavailableOrFailed:
            if !Task.isCancelled {
                markSettled(target.key)
            }
            return false
        case .rejectedOrCancelled:
            return false
        }
    }

    private func resolveFromPrompt(
        _ target: Target,
        prompt: String,
        allowsGeneration: Bool
    ) async {
        let existingRecord = store.record(agent: target.agent, conversationID: target.conversationID)
        let existing = existingRecord?.source
        let forcedFlight = flights[target.key]?.forced == true
        let currentMode = mode()
        let isChinese = SettingsStrings(language: language()).isChinese
        let canLocalizeExisting = existingRecord.map { record in
            record.source == .generated
                && currentMode == .generate
                && allowsGeneration
                && isChinese
                && !AgentConversationTitleStore.containsCJK(record.title)
        } ?? false
        guard forcedFlight || existing == nil || existing == .prompt || canLocalizeExisting else {
            markSettled(target.key)
            return
        }
        if !forcedFlight, currentMode != .generate {
            markSettled(target.key)
            AgentConversationTitleLog.info(
                "not stored \(Self.describe(target)): mode is \(currentMode.rawValue) and the Agent named nothing"
            )
            return
        }
        if allowsGeneration {
            // Only the opening prompt leaves the process; the service redacts and bounds it.
            switch await generateTitle(for: target, prompt: prompt, nativeTitle: nil, force: forcedFlight) {
            case .generated(let title):
                guard !Task.isCancelled else { return }
                let forceStore = flights[target.key]?.forced == true
                if !forceStore, let flight = flights[target.key], flight.epoch != configurationEpoch {
                    return
                }
                markSettled(target.key)
                store.set(
                    title,
                    source: .generated,
                    agent: target.agent,
                    conversationID: target.conversationID,
                    remoteHost: target.remoteHost,
                    force: forceStore || canLocalizeExisting,
                    isUserRequested: forceStore
                )
                return
            case .unavailableOrFailed:
                guard !Task.isCancelled else { return }
                markSettled(target.key)
                AgentConversationTitleLog.info(
                    "not generated \(Self.describe(target)): the endpoint gave no title, sanitised prompt stands in"
                )
            case .rejectedOrCancelled:
                // Never write `settledAt` on queue overflow or cancellation so the next trigger retries.
                if Task.isCancelled { return }
                AgentConversationTitleLog.info(
                    "deferred \(Self.describe(target)): generation slot rejected, sanitised prompt stands in temporarily"
                )
            }
        } else {
            markSettled(target.key)
            AgentConversationTitleLog.info(
                "not generated \(Self.describe(target)): tab has a manual title override, sanitised prompt stands in"
            )
        }
        guard currentMode == .generate, !Task.isCancelled,
              let fallback = Self.sanitizedPromptFallback(prompt) else { return }
        store.set(fallback, source: .prompt, agent: target.agent,
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
    let coordinator: AgentConversationTitleCoordinator
    private let owner = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var targets: [UUID: Target] = [:]
    private var states: [UUID: TabActivityState] = [:]
    private var lastAllowsGeneration = true
    private var lastIsGenerating = false
    private var lastIsManualRenaming = false
    /// Why each Agent pane without a readable conversation has none, as last
    /// logged, so the reason is reported when it changes and not on every signal.
    private var unreadable: [UUID: String] = [:]
    private var evaluationScheduled = false

    init(controller: TerminalController, coordinator: AgentConversationTitleCoordinator = .shared) {
        self.controller = controller
        self.coordinator = coordinator
        self.lastAllowsGeneration = Self.allowsGeneration(in: controller)
        self.lastIsGenerating = coordinator.isGeneratingTitle(for: controller)
        self.lastIsManualRenaming = coordinator.isManualRenaming(for: controller)
        let changes: [AnyPublisher<Void, Never>] = [
            controller.$agentResumeDescriptors.map { _ in () }.eraseToAnyPublisher(),
            controller.$agentActivities.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .terminalPaneSessionContextsDidChange)
                .filter { [weak controller] notification in
                    guard let controller, let sender = notification.object as? TerminalController else { return false }
                    return sender === controller
                }
                .map { _ in () }
                .eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .ghosttyTabPresentationDidChange)
                .filter { [weak controller] notification in
                    guard let controller, let sender = notification.object as? BaseTerminalController else {
                        return false
                    }
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
        OhMyGhosttySettings.shared.$agentSessionTitleAlwaysUseAI
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.modeChanged() }
            .store(in: &subscriptions)
        OhMyGhosttySettings.shared.$language
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.modeChanged() }
            .store(in: &subscriptions)
        OhMyGhosttySettings.shared.$aiTitleRoute
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.modeChanged() }
            .store(in: &subscriptions)
        OhMyGhosttySettings.shared.$aiProviders
            .map { $0.map { "\($0.id):\($0.enabled):\($0.baseURL)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.modeChanged() }
            .store(in: &subscriptions)
        coordinator.store.titleChanges
            .sink { [weak self] key in self?.titleChanged(key) }
            .store(in: &subscriptions)
        coordinator.generationStateChanges
            .sink { [weak self] in self?.generationStateChanged() }
            .store(in: &subscriptions)
        if lastIsGenerating || lastIsManualRenaming {
            NotificationCenter.default.post(name: .ghosttyTabPresentationDidChange, object: controller)
        }
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

    private static func allowsGeneration(in controller: TerminalController) -> Bool {
        guard let override = controller.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }
        return override.isEmpty
    }

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
        let allowsGeneration = Self.allowsGeneration(in: controller)
        let generationJustAllowed = allowsGeneration && !lastAllowsGeneration
        lastAllowsGeneration = allowsGeneration

        var nextTargets: [UUID: Target] = [:]
        var nextStates: [UUID: TabActivityState] = [:]
        var nextSurfaceAllowsGeneration: [UUID: Bool] = [:]
        var nextUnreadable: [UUID: String] = [:]
        for surface in controller.surfaceTree {
            if let state = controller.agentActivity(for: surface)?.state {
                nextStates[surface.id] = state
            }
            guard let descriptor = controller.agentResumeDescriptor(for: surface) else { continue }
            guard let session = controller.paneSessionContext(for: surface),
                  let binding = PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session)
            else {
                let reason = descriptor.conversationID == nil
                    ? "the pane has no conversation ID" : "its connection is not ready"
                nextUnreadable[surface.id] = "\(descriptor.agent.rawValue) \(descriptor.scope.rawValue): \(reason)"
                continue
            }
            nextTargets[surface.id] = Target(
                agent: binding.agent,
                conversationID: binding.conversationID,
                remoteHost: binding.remoteHost,
                projectName: Self.projectName(from: descriptor.workingDirectory)
                    ?? Self.projectName(from: session.workingDirectory)
                    ?? Self.projectName(from: surface.pwd)
            )
            nextSurfaceAllowsGeneration[surface.id] = allowsGeneration && !surface.hasUserSetTitle
        }
        for (surfaceID, reason) in nextUnreadable where unreadable[surfaceID] != reason {
            AgentConversationTitleLog.info("no lookup \(reason)")
        }
        unreadable = nextUnreadable
        for (surfaceID, target) in nextTargets {
            let state = nextStates[surfaceID]
            let newlyBound = targets[surfaceID] != target || generationJustAllowed
            guard newlyBound || state != states[surfaceID],
                  let trigger = Self.trigger(for: state, newlyBound: newlyBound) else { continue }
            coordinator.request(
                target,
                trigger: trigger,
                owner: owner,
                allowsGeneration: nextSurfaceAllowsGeneration[surfaceID] ?? allowsGeneration
            )
        }
        targets = nextTargets
        states = nextStates
    }

    func autoRename(force: Bool, clearUserSurfaceTitle: Bool = true) {
        guard let controller else { return }
        let allowsGeneration = Self.allowsGeneration(in: controller)
        let orderedSurfaces = controller.focusOrderedSurfaces
        for surface in orderedSurfaces {
            if !clearUserSurfaceTitle, surface.hasUserSetTitle {
                continue
            }
            guard let descriptor = controller.agentResumeDescriptor(for: surface) else { continue }
            let session = controller.paneSessionContext(for: surface)
                ?? .init(workingDirectory: surface.pwd, terminalTitle: surface.title)
            guard let binding = PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session)
            else { continue }
            let target = Target(
                agent: binding.agent,
                conversationID: binding.conversationID,
                remoteHost: binding.remoteHost,
                projectName: Self.projectName(from: descriptor.workingDirectory)
                    ?? Self.projectName(from: session.workingDirectory)
                    ?? Self.projectName(from: surface.pwd)
            )
            targets[surface.id] = target
            let surfaceAllowsGeneration: Bool = if force {
                clearUserSurfaceTitle || !surface.hasUserSetTitle
            } else {
                allowsGeneration && !surface.hasUserSetTitle
            }
            var clearManualOverrideOnSuccess: (@MainActor () -> Void)?
            if force {
                clearManualOverrideOnSuccess = { [weak self, weak controller, weak surface] in
                    guard let controller else { return }
                    if controller.titleOverride != nil {
                        controller.titleOverride = nil
                    }
                    if clearUserSurfaceTitle, let surface, surface.hasUserSetTitle {
                        surface.titleOverride = nil
                    }
                    self?.lastAllowsGeneration = true
                }
            }
            coordinator.request(
                target,
                trigger: .done,
                owner: owner,
                allowsGeneration: surfaceAllowsGeneration,
                force: force,
                manualTabID: force ? controller.tabSessionID : nil,
                onForcedGenerated: clearManualOverrideOnSuccess
            )
        }
    }

    static func projectName(from workingDirectory: String?) -> String? {
        guard let raw = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "~", raw != "/" else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded == NSHomeDirectory() || expanded == "/" { return nil }
        let name = URL(fileURLWithPath: expanded).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" || name == "~" ? nil : name
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
        coordinator.invalidateSettledState()
        targets = [:]
        states = [:]
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.controller else { return }
            NotificationCenter.default.post(name: .ghosttyTabPresentationDidChange, object: controller)
        }
        scheduleEvaluation()
    }

    private func titleChanged(_ key: AgentConversationTitleStore.Key) {
        guard let controller, controller.agentResumeDescriptors.values.contains(where: {
            $0.agent == key.agent && $0.conversationID == key.conversationID
        }) else { return }
        NotificationCenter.default.post(name: .ghosttyTabPresentationDidChange, object: controller)
    }

    private func generationStateChanged() {
        guard let controller else { return }
        let nextGenerating = coordinator.isGeneratingTitle(for: controller)
        let nextManual = coordinator.isManualRenaming(for: controller)
        guard nextGenerating != lastIsGenerating || nextManual != lastIsManualRenaming else { return }
        lastIsGenerating = nextGenerating
        lastIsManualRenaming = nextManual
        NotificationCenter.default.post(name: .ghosttyTabPresentationDidChange, object: controller)
    }
}

private nonisolated(unsafe) var agentConversationTitleTrackerKey: UInt8 = 0

extension AgentConversationTitleStore {
    /// The one rule for whether a pane shows a conversation title: the mode
    /// allows it (or the user explicitly requested a manual rename) and the
    /// pane's current resume descriptor names a conversation that has one.
    func title(for descriptor: AgentResumeDescriptor?, mode: AgentSessionTitleMode) -> String? {
        guard let descriptor, let conversationID = descriptor.conversationID,
              let record = record(agent: descriptor.agent, conversationID: conversationID) else {
            return nil
        }
        switch mode {
        case .off:
            return record.isUserRequested == true ? record.title : nil
        case .native:
            return (record.source == .native || record.isUserRequested == true) ? record.title : nil
        case .generate:
            return record.title
        }
    }
}

extension TerminalController {
    /// The title coordinator active on this tab (its tracker's coordinator when
    /// injected by tests, otherwise `.shared`).
    @MainActor
    var agentConversationTitleCoordinator: AgentConversationTitleCoordinator {
        (objc_getAssociatedObject(self, &agentConversationTitleTrackerKey) as? AgentConversationTitleTracker)?
            .coordinator ?? .shared
    }

    /// Whether AI or manual title generation is currently running for this tab.
    @MainActor
    var isGeneratingTabTitle: Bool {
        agentConversationTitleCoordinator.isGeneratingTitle(for: self)
    }

    /// Whether an explicit manual/batch rename is currently running for this tab.
    @MainActor
    var isManualRenamingTab: Bool {
        agentConversationTitleCoordinator.isManualRenaming(for: self)
    }

    /// Whether this tab has at least one bound, reachable Agent conversation eligible for auto-renaming.
    @MainActor
    var canAutoRenameTab: Bool {
        surfaceTree.contains { surface in
            guard let descriptor = agentResumeDescriptor(for: surface) else { return false }
            let session = paneSessionContext(for: surface)
                ?? .init(workingDirectory: surface.pwd, terminalTitle: surface.title)
            return PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session) != nil
        }
    }

    /// Surfaces ordered by focus priority: `focusedSurface` first (when live),
    /// followed by `tabPaneFocusHistory.recent` siblings, then any remaining `surfaceTree` leaves.
    @MainActor
    var focusOrderedSurfaces: [Ghostty.SurfaceView] {
        let all = Array(surfaceTree)
        guard all.count > 1 else { return all }
        var byID: [UUID: Ghostty.SurfaceView] = [:]
        for surface in all {
            byID[surface.id] = surface
        }
        var ordered: [Ghostty.SurfaceView] = []
        ordered.reserveCapacity(all.count)
        var seen = Set<UUID>()
        if let focused = focusedSurface, let live = byID[focused.id], seen.insert(live.id).inserted {
            ordered.append(live)
        }
        for recentID in tabPaneFocusHistory.recent {
            if let live = byID[recentID], seen.insert(live.id).inserted {
                ordered.append(live)
            }
        }
        for surface in all where seen.insert(surface.id).inserted {
            ordered.append(surface)
        }
        return ordered
    }

    /// The conversation title `surface` shows in the Inbox, if any.
    func agentConversationTitle(for surface: Ghostty.SurfaceView?) -> String? {
        agentConversationTitleCoordinator.store.title(
            for: agentResumeDescriptor(for: surface),
            mode: OhMyGhosttySettings.shared.agentSessionTitleMode
        )
    }

    /// The conversation title of the pane that names this tab in the Inbox.
    var tabAgentConversationTitle: String? {
        guard let primary = focusedSurface ?? surfaceTree.first else { return nil }
        if primary.hasUserSetTitle { return nil }
        if let primaryTitle = agentConversationTitle(for: primary) {
            return primaryTitle
        }
        guard surfaceTree.isSplit else { return nil }
        for sibling in focusOrderedSurfaces.dropFirst() where !sibling.hasUserSetTitle {
            if let siblingTitle = agentConversationTitle(for: sibling) {
                return siblingTitle
            }
        }
        return nil
    }

    /// Starts looking up conversation titles for this tab's panes. Calling it
    /// again with the same coordinator changes nothing; tracking ends when the
    /// controller is released.
    func startAgentConversationTitleTracking(coordinator: AgentConversationTitleCoordinator = .shared) {
        if let existing = objc_getAssociatedObject(
            self, &agentConversationTitleTrackerKey
        ) as? AgentConversationTitleTracker,
           existing.coordinator === coordinator {
            return
        }
        objc_setAssociatedObject(
            self,
            &agentConversationTitleTrackerKey,
            AgentConversationTitleTracker(controller: self, coordinator: coordinator),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Triggers immediate AI title regeneration on an eligible Agent tab, clearing any manual
    /// `titleOverride` only once a replacement title is actually generated.
    @MainActor
    func autoRenameTab(force: Bool = true, clearUserSurfaceTitle: Bool = true) {
        guard canAutoRenameTab else { return }
        if objc_getAssociatedObject(self, &agentConversationTitleTrackerKey) == nil {
            startAgentConversationTitleTracking()
        }
        if let tracker = objc_getAssociatedObject(
            self, &agentConversationTitleTrackerKey
        ) as? AgentConversationTitleTracker {
            tracker.autoRename(force: force, clearUserSurfaceTitle: clearUserSurfaceTitle)
        }
    }

    /// Triggers forced auto-rename for all eligible Agent tabs in `controllers`,
    /// skipping tabs with an explicit manual `titleOverride` and preserving per-pane user titles.
    @MainActor
    static func autoRenameWorkspaceTabs(_ controllers: [TerminalController]) {
        for controller in controllers where controller.canAutoRenameTab {
            if let override = controller.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                continue
            }
            controller.autoRenameTab(force: true, clearUserSurfaceTitle: false)
        }
    }
}
