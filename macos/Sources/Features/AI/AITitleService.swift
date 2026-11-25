import Foundation

/// The seam stream B uses: nil while no endpoint is configured, generation is paused,
/// or the endpoint failed. Never throws to the caller.
protocol AITitleGenerating: Sendable {
    func title(forFirstPrompt prompt: String) async -> String?
}

/// Generates conversation titles with a bounded background channel: at most two
/// requests in flight, a short queue, and a breaker that pauses after repeated failures.
actor AITitleService: AITitleGenerating {
    /// Resolves the tab-title model from settings and the credential store; nil disables generation.
    typealias EndpointProvider = @Sendable () async -> AIEndpoint?
    /// The language the title is written in: the app's display language.
    typealias LanguageProvider = @Sendable () async -> OhMyGhosttyLanguage

    struct Limits: Sendable {
        var maxInFlight = 2
        var maxPromptBytes = 1_500
        var consecutiveFailuresBeforePause = 3
        var pauseDuration: Duration = .seconds(300)
        var pollInterval: Duration = .milliseconds(500)

        static let `default` = Limits()
    }

    static let shared = AITitleService()

    private let client: AIHTTPClient
    private let endpoints: EndpointProvider
    private let language: LanguageProvider
    private let limits: Limits
    private let clock = ContinuousClock()

    private var inFlight = 0
    private var consecutiveFailures = 0
    private var pausedUntil: ContinuousClock.Instant?
    /// How much of a pause the service refuses to sit through before giving up.
    private var blockedFor: Duration = .zero
    private var authBlocked = false
    private var currentEndpoint: AIEndpoint?

    init(
        client: AIHTTPClient = AIHTTPClient(),
        endpoints: @escaping EndpointProvider = AITitleService.configuredEndpoint,
        language: @escaping LanguageProvider = AITitleService.configuredLanguage,
        limits: Limits = .default
    ) {
        self.client = client
        self.endpoints = endpoints
        self.language = language
        self.limits = limits
    }

    /// Reads the model chosen for tab titles (`ai.routes.title`) with its API connection
    /// and key, outside the settings actor. No choice, or a disabled connection, is nil.
    @Sendable
    nonisolated static func configuredEndpoint() async -> AIEndpoint? {
        await MainActor.run {
            let settings = OhMyGhosttySettings.shared
            guard settings.agentSessionTitleMode == .generate else { return nil }
            return AIProviderDirectory(providers: settings.aiProviders, credentials: .shared)
                .titleEndpoint(settings.aiTitleRoute)
        }
    }

    /// The Settings display language, read on the main actor like the endpoint.
    @Sendable
    nonisolated static func configuredLanguage() async -> OhMyGhosttyLanguage {
        await MainActor.run { OhMyGhosttySettings.shared.language }
    }

    /// Redacts, bounds and tags the first prompt so the endpoint only ever sees quoted text.
    static func userMessage(for prompt: String, maxBytes: Int = Limits.default.maxPromptBytes) -> String? {
        let redacted = AISecretRedactor.redact(prompt)
        let content = bounded(redacted, maxBytes: maxBytes)
            .replacingOccurrences(of: "</first_prompt>", with: "<\\/first_prompt>", options: .caseInsensitive)
        guard !content.isEmpty else { return nil }
        return "<first_prompt>\n\(content)\n</first_prompt>"
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
        guard !Task.isCancelled, let endpoint = await endpoints() else { return nil }
        noteEndpoint(endpoint)
        currentEndpoint = endpoint
        guard await waitUntilResolved(endpoint),
              let message = Self.userMessage(for: prompt, maxBytes: limits.maxPromptBytes),
              acquireSlot(endpoint) else { return nil }
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

    /// A different endpoint means the user changed the configuration: forget the breaker state.
    /// The key is compared separately so a rotating token does not lift an authentication pause.
    private func noteEndpoint(_ endpoint: AIEndpoint) {
        guard !sameConfiguration(currentEndpoint, endpoint) else { return }
        consecutiveFailures = 0
        pausedUntil = nil
        authBlocked = false
    }

    private func sameConfiguration(_ lhs: AIEndpoint?, _ rhs: AIEndpoint) -> Bool {
        guard let lhs else { return false }
        return lhs.kind == rhs.kind && lhs.baseURL == rhs.baseURL && lhs.model == rhs.model
    }

    private func note(_ outcome: Outcome, for endpoint: AIEndpoint) {
        guard sameConfiguration(currentEndpoint, endpoint) else { return }
        switch outcome {
        case .cancelled:
            break
        case .success:
            consecutiveFailures = 0
            authBlocked = false
        case .failure(.httpStatus(401, _)), .failure(.httpStatus(403, _)):
            authBlocked = true
            consecutiveFailures += 1
        case .failure:
            consecutiveFailures += 1
            if consecutiveFailures >= limits.consecutiveFailuresBeforePause {
                pausedUntil = clock.now + limits.pauseDuration
                blockedFor = limits.pauseDuration / 2
                consecutiveFailures = 0
            }
        }
    }

    private func isPaused(at instant: ContinuousClock.Instant) -> Bool {
        if let pausedUntil, instant < pausedUntil { return true }
        return authBlocked
    }

    /// Waits out a pause before taking a request slot; cancelling the task ends the wait.
    private func waitUntilResolved(_ endpoint: AIEndpoint) async -> Bool {
        while true {
            guard !Task.isCancelled, sameConfiguration(currentEndpoint, endpoint) else { return false }
            switch gate() {
            case .ready: return true
            case .wait:
                try? await Task.sleep(for: limits.pollInterval)
            case .blocked:
                // Give up rather than poll through a freshly started pause or a failed sign-in.
                return false
            }
        }
    }

    private func gate() -> Gate {
        let now = clock.now
        if let pausedUntil {
            guard now < pausedUntil else { return .ready }
            return pausedUntil - now > blockedFor ? .wait : .blocked
        }
        return authBlocked ? .blocked : .ready
    }

    private enum Gate {
        case ready
        case wait
        case blocked
    }

    /// Takes one of the in-flight slots. With both slots busy the caller gives up instead of
    /// queueing, which keeps a cancelled title request from holding capacity.
    private func acquireSlot(_ endpoint: AIEndpoint) -> Bool {
        guard !Task.isCancelled, sameConfiguration(currentEndpoint, endpoint),
              !isPaused(at: clock.now), inFlight < limits.maxInFlight else { return false }
        inFlight += 1
        return true
    }

    private func releaseSlot() {
        inFlight = max(0, inFlight - 1)
    }
}
