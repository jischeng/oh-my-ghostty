import Foundation

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
}

/// Generates conversation titles with a bounded background channel: at most two
/// requests in flight, FIFO queueing for explicit/batch renames, and a breaker
/// that pauses after repeated endpoint failures.
actor AITitleService: AITitleGenerating {
    /// Resolves the tab-title model from settings and the credential store; nil disables generation.
    typealias EndpointProvider = @Sendable () async -> AIEndpoint?
    typealias ForcedEndpointProvider = @Sendable (_ force: Bool) async -> AIEndpoint?
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
    private let endpoints: ForcedEndpointProvider
    private let language: LanguageProvider
    private let limits: Limits
    private let clock = ContinuousClock()

    private struct SlotWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var inFlight = 0
    private var slotWaiters: [SlotWaiter] = []
    private var consecutiveFailures = 0
    private var pausedUntil: ContinuousClock.Instant?
    /// Maximum remaining pause window a caller sits through before giving up.
    private var tailWaitWindow: Duration = .zero
    private var authBlocked = false
    private var currentEndpoint: AIEndpoint?

    init(
        client: AIHTTPClient = AIHTTPClient(),
        endpoints: @escaping EndpointProvider,
        language: @escaping LanguageProvider = AITitleService.configuredLanguage,
        limits: Limits = .default
    ) {
        self.client = client
        self.endpoints = { _ in await endpoints() }
        self.language = language
        self.limits = limits
    }

    init(
        client: AIHTTPClient = AIHTTPClient(),
        forcedEndpoints: @escaping ForcedEndpointProvider = AITitleService.configuredEndpoint(force:),
        language: @escaping LanguageProvider = AITitleService.configuredLanguage,
        limits: Limits = .default
    ) {
        self.client = client
        self.endpoints = forcedEndpoints
        self.language = language
        self.limits = limits
    }

    /// Reads the model chosen for tab titles (`ai.routes.title`) with its API connection
    /// and key, outside the settings actor. No choice, or a disabled connection, is nil.
    @Sendable
    nonisolated static func configuredEndpoint() async -> AIEndpoint? {
        await configuredEndpoint(force: false)
    }

    /// Explicit manual renames (`force: true`) may use `ai.routes.title` even when
    /// automatic background naming is set to `.native`.
    @Sendable
    nonisolated static func configuredEndpoint(force: Bool) async -> AIEndpoint? {
        await MainActor.run {
            let settings = OhMyGhosttySettings.shared
            if force {
                guard settings.agentSessionTitleMode != .off else { return nil }
            } else {
                guard settings.agentSessionTitleMode == .generate else { return nil }
            }
            return AIProviderDirectory(providers: settings.aiProviders, credentials: .shared)
                .titleEndpoint(settings.aiTitleRoute)
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
        guard !Task.isCancelled, let endpoint = await endpoints(force) else { return nil }
        noteEndpoint(endpoint)
        currentEndpoint = endpoint
        guard await waitUntilResolved(endpoint),
              let message = Self.userMessage(
                  for: prompt,
                  nativeTitle: nativeTitle,
                  projectName: projectName,
                  maxBytes: limits.maxPromptBytes
              ),
              await acquireSlot(endpoint, waitIfBusy: force) else { return nil }
        defer { releaseSlot() }

        let system = AIHTTPClient.systemPrompt(language: await language())
        let outcome = await send(message, system: system, endpoint: endpoint)
        note(outcome, for: endpoint)
        switch outcome {
        case .success(let title): return title
        case .failure, .cancelled: return nil
        }
    }

    private enum Outcome: Sendable {
        case success(String?)
        case failure(AIHTTPError?)
        /// The caller gave up; that says nothing about the endpoint's health.
        case cancelled
    }

    private func send(_ message: String, system: String, endpoint: AIEndpoint) async -> Outcome {
        do {
            let title = try await client.complete(
                system: system,
                user: message,
                endpoint: endpoint,
                maxOutputTokens: endpoint.maxOutputTokens ?? AIHTTPClient.Options.title.maxOutputTokens
            )
            guard !Task.isCancelled else { return .success(nil) }
            return .success(title)
        } catch let error as AIHTTPError {
            return .failure(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(nil)
        }
    }

    /// A different endpoint or API key means the user changed the configuration: forget the breaker state.
    private func noteEndpoint(_ endpoint: AIEndpoint) {
        guard !sameConfiguration(currentEndpoint, endpoint) else { return }
        consecutiveFailures = 0
        pausedUntil = nil
        authBlocked = false
    }

    private func sameConfiguration(_ lhs: AIEndpoint?, _ rhs: AIEndpoint) -> Bool {
        guard let lhs else { return false }
        return lhs.kind == rhs.kind
            && lhs.baseURL == rhs.baseURL
            && lhs.model == rhs.model
            && lhs.apiKey == rhs.apiKey
    }

    private func note(_ outcome: Outcome, for endpoint: AIEndpoint) {
        guard sameConfiguration(currentEndpoint, endpoint) else { return }
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
        case .failure:
            consecutiveFailures += 1
            if consecutiveFailures >= limits.consecutiveFailuresBeforePause {
                pausedUntil = clock.now + limits.pauseDuration
                tailWaitWindow = min(limits.pauseDuration / 2, .seconds(5))
                consecutiveFailures = 0
            }
        }
    }

    private func isPaused(at instant: ContinuousClock.Instant) -> Bool {
        if let pausedUntil, instant < pausedUntil { return true }
        return authBlocked
    }

    /// Waits out a nearly-finished pause before taking a request slot; cancelling the task ends the wait.
    private func waitUntilResolved(_ endpoint: AIEndpoint) async -> Bool {
        while true {
            guard !Task.isCancelled, sameConfiguration(currentEndpoint, endpoint) else { return false }
            switch gate() {
            case .ready: return true
            case .wait:
                try? await Task.sleep(for: limits.pollInterval)
            case .blocked:
                // Give up immediately rather than poll through a freshly started pause or a failed sign-in.
                return false
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

    /// Takes one of the in-flight slots. Automatic background requests shed immediately when
    /// busy, whereas explicit/batch forced renames wait in FIFO order for a free slot.
    private func acquireSlot(_ endpoint: AIEndpoint, waitIfBusy: Bool) async -> Bool {
        guard !Task.isCancelled, sameConfiguration(currentEndpoint, endpoint),
              !isPaused(at: clock.now) else { return false }
        if inFlight < limits.maxInFlight {
            inFlight += 1
            return true
        }
        guard waitIfBusy, slotWaiters.count < limits.maxQueueDepth else { return false }
        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    slotWaiters.append(SlotWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(waiterID) }
        }
        guard granted else { return false }
        guard !Task.isCancelled, sameConfiguration(currentEndpoint, endpoint),
              !isPaused(at: clock.now) else {
            releaseSlot()
            return false
        }
        return true
    }

    private func cancelSlotWaiter(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = slotWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseSlot() {
        while !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            next.continuation.resume(returning: true)
            return
        }
        inFlight = max(0, inFlight - 1)
    }
}
