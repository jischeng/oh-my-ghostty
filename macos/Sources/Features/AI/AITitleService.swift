import Foundation

enum AITitleGenerationResult: Equatable, Sendable {
    /// Produced a sanitized conversation title.
    case generated(String)
    /// No route is configured, the breaker is paused, or an executed model call failed / returned empty.
    case unavailableOrFailed
    /// Rejected without attempting the model due to queue overflow, configuration switch, or cancellation.
    case rejectedOrCancelled
}

/// The seam stream B uses: nil while no endpoint is configured, generation is paused,
/// or the endpoint failed. Never throws to the caller.
protocol AITitleGenerating: Sendable {
    func title(forFirstPrompt prompt: String) async -> String?
    func title(forFirstPrompt prompt: String, nativeTitle: String?, projectName: String?) async -> String?
    func title(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String?,
        force: Bool
    ) async -> String?
    func generate(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String?,
        force: Bool
    ) async -> AITitleGenerationResult
}

extension AITitleGenerating {
    func title(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String?
    ) async -> String? {
        await title(forFirstPrompt: prompt)
    }

    func title(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String?,
        force: Bool
    ) async -> String? {
        await title(forFirstPrompt: prompt, nativeTitle: nativeTitle, projectName: projectName)
    }

    func generate(forFirstPrompt prompt: String) async -> AITitleGenerationResult {
        await generate(forFirstPrompt: prompt, nativeTitle: nil, projectName: nil, force: false)
    }

    func generate(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String?,
        force: Bool
    ) async -> AITitleGenerationResult {
        guard !Task.isCancelled else { return .rejectedOrCancelled }
        if let value = await title(
            forFirstPrompt: prompt,
            nativeTitle: nativeTitle,
            projectName: projectName,
            force: force
        ) {
            return Task.isCancelled ? .rejectedOrCancelled : .generated(value)
        }
        return Task.isCancelled ? .rejectedOrCancelled : .unavailableOrFailed
    }
}

/// Generates conversation titles with a bounded background channel: at most two
/// requests in flight, bounded queueing for both automatic and manual renames
/// (with priority for explicit `force: true` calls), and a breaker that pauses
/// after repeated endpoint/adapter failures.
actor AITitleService: AITitleGenerating {
    enum ResolvedTarget: Equatable, Sendable {
        case http(AIEndpoint)
        case acp(agent: GitCommitAgent, model: String)
    }

    /// Resolves the tab-title HTTP endpoint from settings and the credential store; nil disables generation.
    typealias EndpointProvider = @Sendable () async -> AIEndpoint?
    typealias ForcedEndpointProvider = @Sendable (_ force: Bool) async -> AIEndpoint?
    typealias TargetProvider = @Sendable (_ force: Bool) async -> ResolvedTarget?
    typealias ACPTitleGenerator = @Sendable (
        _ agent: GitCommitAgent,
        _ model: String,
        _ system: String,
        _ user: String
    ) async throws -> String?
    /// The language the title is written in: the app's display language.
    typealias LanguageProvider = @Sendable () async -> OhMyGhosttyLanguage

    struct Limits: Sendable {
        var maxInFlight = 2
        var maxPromptBytes = 1_500
        var consecutiveFailuresBeforePause = 3
        var pauseDuration: Duration = .seconds(300)
        var pollInterval: Duration = .milliseconds(500)
        var maxQueueDepth = 64

        static let `default` = Limits()
    }

    static let shared = AITitleService()

    private let client: AIHTTPClient
    private let targets: TargetProvider
    private let acpGenerator: ACPTitleGenerator
    private let language: LanguageProvider
    private let limits: Limits
    private let clock = ContinuousClock()

    private enum SlotResume: Sendable {
        case granted
        case rejected
        case paused
    }

    private struct SlotWaiter {
        let id: UUID
        let priority: Bool
        let continuation: CheckedContinuation<SlotResume, Never>
    }

    private enum GateOutcome {
        case ready
        case paused
        case aborted
    }

    private enum SlotAcquireOutcome {
        case acquired
        case paused
        case rejectedOrCancelled
    }

    private var inFlight = 0
    private var slotWaiters: [SlotWaiter] = []
    private var preparing = false
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private var consecutiveFailures = 0
    private var pausedUntil: ContinuousClock.Instant?
    /// Maximum remaining pause window a caller sits through before giving up.
    private var tailWaitWindow: Duration = .zero
    private var authBlocked = false
    private var currentTarget: ResolvedTarget?

    init(
        client: AIHTTPClient = AIHTTPClient(),
        endpoints: @escaping EndpointProvider,
        language: @escaping LanguageProvider = AITitleService.configuredLanguage,
        limits: Limits = .default
    ) {
        self.client = client
        self.targets = { _ in await endpoints().map(ResolvedTarget.http) }
        self.acpGenerator = AITitleService.defaultACPTitleGenerator
        self.language = language
        self.limits = limits
    }

    init(
        client: AIHTTPClient = AIHTTPClient(),
        forcedEndpoints: @escaping ForcedEndpointProvider,
        language: @escaping LanguageProvider = AITitleService.configuredLanguage,
        limits: Limits = .default
    ) {
        self.client = client
        self.targets = { force in await forcedEndpoints(force).map(ResolvedTarget.http) }
        self.acpGenerator = AITitleService.defaultACPTitleGenerator
        self.language = language
        self.limits = limits
    }

    init(
        client: AIHTTPClient = AIHTTPClient(),
        targets: @escaping TargetProvider = AITitleService.configuredTarget(force:),
        acpGenerator: @escaping ACPTitleGenerator = AITitleService.defaultACPTitleGenerator,
        language: @escaping LanguageProvider = AITitleService.configuredLanguage,
        limits: Limits = .default
    ) {
        self.client = client
        self.targets = targets
        self.acpGenerator = acpGenerator
        self.language = language
        self.limits = limits
    }

    @Sendable
    nonisolated static func defaultACPTitleGenerator(
        agent: GitCommitAgent,
        model: String,
        system: String,
        user: String
    ) async throws -> String? {
        try await GitACPService.shared.generateTitle(agent: agent, model: model, system: system, user: user)
    }

    /// Reads the HTTP endpoint chosen for tab titles (`ai.routes.title`) when the route points at an API service.
    @Sendable
    nonisolated static func configuredEndpoint() async -> AIEndpoint? {
        await configuredEndpoint(force: false)
    }

    @Sendable
    nonisolated static func configuredEndpoint(force: Bool) async -> AIEndpoint? {
        guard case .http(let endpoint) = await configuredTarget(force: force) else { return nil }
        return endpoint
    }

    /// Resolves `ai.routes.title` as either an API service HTTP endpoint or a local CLI ACP target.
    /// Explicit manual renames (`force: true`) may use `ai.routes.title` regardless of `agentSessionTitleMode`.
    @Sendable
    nonisolated static func configuredTarget(force: Bool) async -> ResolvedTarget? {
        await MainActor.run {
            let settings = OhMyGhosttySettings.shared
            if !force {
                guard settings.agentSessionTitleMode == .generate else { return nil }
            }
            guard let route = settings.aiTitleRoute else { return nil }
            switch route.target {
            case .provider(let providerID):
                guard let endpoint = try? AIProviderDirectory(providers: settings.aiProviders, credentials: .shared)
                    .endpoint(provider: providerID, model: route.model) else { return nil }
                return .http(endpoint)
            case .agent(let agent):
                guard let model = AIModelID.normalized(route.model) else { return nil }
                return .acp(agent: agent, model: model)
            }
        }
    }

    /// The Settings display language, read on the main actor like the endpoint.
    @Sendable
    nonisolated static func configuredLanguage() async -> OhMyGhosttyLanguage {
        await MainActor.run { OhMyGhosttySettings.shared.language }
    }

    /// Redacts, bounds and tags the first prompt (plus optional native title and project context)
    /// so the endpoint only ever sees quoted text.
    static func userMessage(
        for prompt: String,
        nativeTitle: String? = nil,
        projectName: String? = nil,
        maxBytes: Int = Limits.default.maxPromptBytes
    ) -> String? {
        let content = sanitizedTagBody(prompt, closingTags: ["</first_prompt>"], maxBytes: maxBytes)
        let cleanNative = nativeTitle.flatMap { raw -> String? in
            let body = sanitizedTagBody(
                raw,
                closingTags: ["</native_title>", "</session_context>"],
                maxBytes: min(maxBytes, 400)
            )
            return body.isEmpty || body == content ? nil : body
        }
        let cleanProject = projectName.flatMap { raw -> String? in
            let body = sanitizedTagBody(
                raw,
                closingTags: ["</project>", "</session_context>"],
                maxBytes: min(maxBytes, 120)
            )
            return body.isEmpty ? nil : body
        }
        guard !content.isEmpty || cleanNative != nil else { return nil }
        var sections: [String] = []
        if !content.isEmpty {
            sections.append("<first_prompt>\n\(content)\n</first_prompt>")
        }
        if cleanNative != nil || cleanProject != nil {
            var contextLines: [String] = ["<session_context>"]
            if let cleanProject {
                contextLines.append("<project>\(cleanProject)</project>")
            }
            if let cleanNative {
                contextLines.append("<native_title>\(cleanNative)</native_title>")
            }
            contextLines.append("</session_context>")
            sections.append(contextLines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func sanitizedTagBody(
        _ raw: String,
        closingTags: [String],
        maxBytes: Int
    ) -> String {
        let redacted = AISecretRedactor.redact(raw)
        var content = bounded(redacted, maxBytes: maxBytes)
        for tag in closingTags {
            let escaped = "<\\/" + tag.dropFirst(2)
            content = content.replacingOccurrences(of: tag, with: escaped, options: .caseInsensitive)
        }
        return content
    }

    /// Cuts at a character boundary so the endpoint never receives broken UTF-8.
    static func bounded(_ text: String, maxBytes: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxBytes else { return trimmed }
        var kept = ""
        var used = 0
        for character in trimmed {
            let size = String(character).utf8.count
            guard used + size <= maxBytes else { break }
            kept.append(character)
            used += size
        }
        return kept
    }

    func title(forFirstPrompt prompt: String) async -> String? {
        await title(forFirstPrompt: prompt, nativeTitle: nil, projectName: nil, force: false)
    }

    func title(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String? = nil
    ) async -> String? {
        await title(forFirstPrompt: prompt, nativeTitle: nativeTitle, projectName: projectName, force: false)
    }

    func title(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String? = nil,
        force: Bool
    ) async -> String? {
        if case .generated(let title) = await generate(
            forFirstPrompt: prompt,
            nativeTitle: nativeTitle,
            projectName: projectName,
            force: force
        ) {
            return title
        }
        return nil
    }

    func generate(
        forFirstPrompt prompt: String,
        nativeTitle: String?,
        projectName: String? = nil,
        force: Bool
    ) async -> AITitleGenerationResult {
        guard !Task.isCancelled else { return .rejectedOrCancelled }
        guard let target = await targets(force) else {
            return Task.isCancelled ? .rejectedOrCancelled : .unavailableOrFailed
        }
        noteTarget(target)
        currentTarget = target
        switch await waitUntilResolved(target) {
        case .ready:
            break
        case .paused:
            return .unavailableOrFailed
        case .aborted:
            return .rejectedOrCancelled
        }
        guard let message = Self.userMessage(
            for: prompt,
            nativeTitle: nativeTitle,
            projectName: projectName,
            maxBytes: limits.maxPromptBytes
        ) else {
            return .unavailableOrFailed
        }
        switch await acquireSlot(target, priority: force) {
        case .acquired:
            break
        case .paused:
            return .unavailableOrFailed
        case .rejectedOrCancelled:
            return .rejectedOrCancelled
        }
        defer { releaseSlot() }

        enum PreparedSend {
            case ready(ResolvedTarget, String)
            case abort(AITitleGenerationResult)
        }
        await acquirePrepareTurn()
        let prepared: PreparedSend
        if Task.isCancelled {
            prepared = .abort(.rejectedOrCancelled)
        } else if let latestTarget = await targets(force) {
            if sameConfiguration(target, latestTarget) {
                let system = AIHTTPClient.systemPrompt(language: await language())
                prepared = Task.isCancelled ? .abort(.rejectedOrCancelled) : .ready(latestTarget, system)
            } else {
                noteTarget(latestTarget)
                currentTarget = latestTarget
                prepared = .abort(.rejectedOrCancelled)
            }
        } else {
            prepared = .abort(Task.isCancelled ? .rejectedOrCancelled : .unavailableOrFailed)
        }
        releasePrepareTurn()

        let (latestTarget, system): (ResolvedTarget, String)
        switch prepared {
        case .ready(let resolvedTarget, let resolvedSystem):
            (latestTarget, system) = (resolvedTarget, resolvedSystem)
        case .abort(let earlyResult):
            return earlyResult
        }

        let outcome = await send(message, system: system, target: latestTarget)
        note(outcome, for: latestTarget)
        switch outcome {
        case .success(let title):
            if Task.isCancelled { return .rejectedOrCancelled }
            return title.map(AITitleGenerationResult.generated) ?? .unavailableOrFailed
        case .failure:
            return Task.isCancelled ? .rejectedOrCancelled : .unavailableOrFailed
        case .cancelled:
            return .rejectedOrCancelled
        }
    }

    private enum Outcome: Sendable {
        case success(String?)
        case failure(AIHTTPError?)
        /// The caller gave up; that says nothing about the endpoint's health.
        case cancelled
    }

    private func send(_ message: String, system: String, target: ResolvedTarget) async -> Outcome {
        do {
            let title: String?
            switch target {
            case .http(let endpoint):
                title = try await client.complete(
                    system: system,
                    user: message,
                    endpoint: endpoint,
                    maxOutputTokens: endpoint.maxOutputTokens ?? AIHTTPClient.Options.title.maxOutputTokens
                )
            case .acp(let agent, let model):
                title = try await acpGenerator(agent, model, system, message)
            }
            guard !Task.isCancelled else { return .cancelled }
            return .success(title)
        } catch let error as AIHTTPError {
            return Task.isCancelled ? .cancelled : .failure(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .failure(nil)
        }
    }

    /// A different endpoint, CLI model, or API key means the user changed configuration: forget breaker state.
    private func noteTarget(_ target: ResolvedTarget) {
        guard !sameConfiguration(currentTarget, target) else { return }
        consecutiveFailures = 0
        pausedUntil = nil
        authBlocked = false
        rejectAllSlotWaiters(with: .rejected)
    }

    private func sameConfiguration(_ lhs: ResolvedTarget?, _ rhs: ResolvedTarget) -> Bool {
        guard let lhs else { return false }
        switch (lhs, rhs) {
        case (.http(let left), .http(let right)):
            return left.kind == right.kind
                && left.baseURL == right.baseURL
                && left.model == right.model
                && left.apiKey == right.apiKey
        case (.acp(let leftAgent, let leftModel), .acp(let rightAgent, let rightModel)):
            return leftAgent == rightAgent && leftModel == rightModel
        case (.http, .acp), (.acp, .http):
            return false
        }
    }

    private func note(_ outcome: Outcome, for target: ResolvedTarget) {
        guard sameConfiguration(currentTarget, target) else { return }
        switch outcome {
        case .cancelled:
            break
        case .success:
            consecutiveFailures = 0
            authBlocked = false
        case .failure(.emptyOutput), .failure(.truncatedOutput):
            // Empty or reasoning-exhausted model output on one prompt does not mean the endpoint is down.
            break
        case .failure(.httpStatus(401, _)), .failure(.httpStatus(403, _)):
            authBlocked = true
            consecutiveFailures += 1
            rejectAllSlotWaiters(with: .paused)
        case .failure:
            consecutiveFailures += 1
            if consecutiveFailures >= limits.consecutiveFailuresBeforePause {
                pausedUntil = clock.now + limits.pauseDuration
                tailWaitWindow = min(limits.pauseDuration / 2, .seconds(5))
                consecutiveFailures = 0
                rejectAllSlotWaiters(with: .paused)
            }
        }
    }

    private func rejectAllSlotWaiters(with reason: SlotResume) {
        let pending = slotWaiters
        slotWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: reason)
        }
    }

    private func isPaused(at instant: ContinuousClock.Instant) -> Bool {
        if let pausedUntil, instant < pausedUntil { return true }
        return authBlocked
    }

    /// Waits out a nearly-finished pause before taking a request slot; cancelling the task ends the wait.
    private func waitUntilResolved(_ target: ResolvedTarget) async -> GateOutcome {
        while true {
            guard !Task.isCancelled, sameConfiguration(currentTarget, target) else { return .aborted }
            switch gate() {
            case .ready: return .ready
            case .wait:
                try? await Task.sleep(for: limits.pollInterval)
            case .blocked:
                // Give up immediately rather than poll through a freshly started pause or a failed sign-in.
                return .paused
            }
        }
    }

    private func gate() -> Gate {
        let now = clock.now
        if let pausedUntil {
            guard now < pausedUntil else { return .ready }
            return pausedUntil - now <= tailWaitWindow ? .wait : .blocked
        }
        return authBlocked ? .blocked : .ready
    }

    private enum Gate {
        case ready
        case wait
        case blocked
    }

    /// Takes one of the in-flight slots. Both automatic and forced requests wait in the
    /// bounded queue (`limits.maxQueueDepth`); explicit `priority: true` requests jump ahead
    /// of non-priority background waiters in FIFO priority order.
    private func acquireSlot(_ target: ResolvedTarget, priority: Bool) async -> SlotAcquireOutcome {
        guard !Task.isCancelled, sameConfiguration(currentTarget, target) else {
            return .rejectedOrCancelled
        }
        guard !isPaused(at: clock.now) else { return .paused }
        if inFlight < limits.maxInFlight {
            inFlight += 1
            return .acquired
        }
        if slotWaiters.count >= limits.maxQueueDepth {
            if priority, let evictIndex = slotWaiters.lastIndex(where: { !$0.priority }) {
                let evicted = slotWaiters.remove(at: evictIndex)
                evicted.continuation.resume(returning: .rejected)
            } else {
                return .rejectedOrCancelled
            }
        }
        let waiterID = UUID()
        let resume: SlotResume = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .rejected)
                } else if priority {
                    let index = slotWaiters.firstIndex(where: { !$0.priority }) ?? slotWaiters.endIndex
                    slotWaiters.insert(
                        SlotWaiter(id: waiterID, priority: true, continuation: continuation),
                        at: index
                    )
                } else {
                    slotWaiters.append(
                        SlotWaiter(id: waiterID, priority: false, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(waiterID) }
        }
        switch resume {
        case .rejected:
            return .rejectedOrCancelled
        case .paused:
            return .paused
        case .granted:
            guard !Task.isCancelled, sameConfiguration(currentTarget, target) else {
                releaseSlot()
                return .rejectedOrCancelled
            }
            guard !isPaused(at: clock.now) else {
                releaseSlot()
                return .paused
            }
            return .acquired
        }
    }

    private func cancelSlotWaiter(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = slotWaiters.remove(at: index)
        waiter.continuation.resume(returning: .rejected)
    }

    private func releaseSlot() {
        while !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            next.continuation.resume(returning: .granted)
            return
        }
        inFlight = max(0, inFlight - 1)
    }

    private func acquirePrepareTurn() async {
        if !preparing {
            preparing = true
            return
        }
        await withCheckedContinuation { continuation in
            prepareWaiters.append(continuation)
        }
    }

    private func releasePrepareTurn() {
        if !prepareWaiters.isEmpty {
            let next = prepareWaiters.removeFirst()
            next.resume()
            return
        }
        preparing = false
    }
}
