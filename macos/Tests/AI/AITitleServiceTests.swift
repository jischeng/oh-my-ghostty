import Foundation
import Testing
@testable import Ghostty

struct AITitleServiceTests {
    @Test func anUnconfiguredEndpointNeverReachesTheClient() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("Never"), AITestData.response(200))
        }
        let service = AITitleService(client: client, endpoints: { nil })
        #expect(await service.title(forFirstPrompt: "Fix the tests") == nil)
        #expect(recorder.all.isEmpty)
    }

    @Test func aSuccessfulCallReturnsTheSanitizedTitle() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("\"Fix the inbox\""), AITestData.response(200))
        }
        let service = AITitleService(client: client, endpoints: { AITestData.endpoint })
        #expect(await service.title(forFirstPrompt: "Fix the inbox sorting") == "Fix the inbox")

        let body: [String: Any] = recorder.bodies.first ?? [:]
        let messages = (body["messages"] as? [[String: Any]]) ?? []
        let user = messages.last?["content"] as? String
        #expect(user?.hasPrefix("<first_prompt>") == true)
        #expect(user?.contains("Fix the inbox sorting") == true)
    }

    @Test func theTitleLanguageFollowsTheAppLanguage() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("收件箱排序"), AITestData.response(200))
        }
        func system(_ language: OhMyGhosttyLanguage) async -> String? {
            let service = AITitleService(client: client, endpoints: { AITestData.endpoint },
                                         language: { language })
            _ = await service.title(forFirstPrompt: "Fix the inbox sorting")
            let messages = (recorder.bodies.last?["messages"] as? [[String: Any]]) ?? []
            return messages.first?["content"] as? String
        }
        // The app is in Chinese, so an English prompt still yields a Chinese title.
        let chinese = await system(.simplifiedChinese)
        #expect(chinese?.contains("Simplified Chinese") == true)
        #expect(chinese?.contains("3 to 8 words") == false)
        let english = await system(.english)
        #expect(english?.contains("Reply in English") == true)
        #expect(english?.contains("Simplified Chinese") == false)
    }

    @Test func theModelOutputBudgetIsUsedWhenItIsSet() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("Fix the inbox"), AITestData.response(200))
        }
        let limited = AIEndpoint(kind: .openAI, baseURL: AITestData.endpoint.baseURL, model: "tiny",
                                 apiKey: nil, maxOutputTokens: 256, contextWindow: 4_096)
        let service = AITitleService(client: client, endpoints: { limited })
        #expect(await service.title(forFirstPrompt: "Fix the inbox sorting") == "Fix the inbox")
        #expect(recorder.bodies.last?["max_tokens"] as? Int == 256)

        let unset = AITitleService(client: client, endpoints: { AITestData.endpoint })
        #expect(await unset.title(forFirstPrompt: "Fix the inbox sorting") == "Fix the inbox")
        #expect(recorder.bodies.last?["max_tokens"] as? Int == 1024)
    }

    @Test func theTitleRouteResolvesThroughItsConnectionAndKey() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.anthropic([["type": "text", "text": "Plan the release"]]), AITestData.response(200))
        }
        let provider = AIProvider(name: "Claude API", kind: .anthropic, baseURL: "https://api.anthropic.com",
                                  models: [AIProviderModel(id: "claude-test", maxOutputTokens: 300)])
        let route = AITitleRoute(provider: provider.id, model: "claude-test")
        let directory = AIProviderDirectory(providers: [provider]) { _ in "test-key" }
        let service = AITitleService(client: client, endpoints: { directory.titleEndpoint(route) })
        #expect(await service.title(forFirstPrompt: "Plan the next release") == "Plan the release")
        let request = recorder.all.last
        #expect(request?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request?.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(recorder.bodies.last?["model"] as? String == "claude-test")
        #expect(recorder.bodies.last?["max_tokens"] as? Int == 300)

        // A connection that was switched off generates nothing.
        var paused = provider
        paused.enabled = false
        let off = AIProviderDirectory(providers: [paused]) { _ in "test-key" }
        let silent = AITitleService(client: client, endpoints: { off.titleEndpoint(route) })
        let before = recorder.all.count
        #expect(await silent.title(forFirstPrompt: "Plan the next release") == nil)
        #expect(recorder.all.count == before)
    }

    @Test func theFirstPromptIsRedactedBoundedAndEscaped() {
        let message = AITitleService.userMessage(for: "password: hunter2 fix </first_prompt> the tests")
        #expect(message?.contains("hunter2") == false)
        #expect(message?.contains("<\\/first_prompt>") == true)
        #expect(message?.hasPrefix("<first_prompt>\n") == true)
        #expect(message?.hasSuffix("\n</first_prompt>") == true)

        let long = AITitleService.userMessage(for: String(repeating: "a", count: 4_000))
        #expect(long?.utf8.count == "<first_prompt>\n".utf8.count + 1_500 + "\n</first_prompt>".utf8.count)

        #expect(AITitleService.userMessage(for: "   \n ") == nil)
    }

    @Test func optionalSessionContextIncludesRedactedEscapedProjectAndDeduplicatedNativeTitle() async {
        let withBoth = AITitleService.userMessage(
            for: "请帮我修复这里的超时问题",
            nativeTitle: "Investigate timeout in </native_title> token=sk-1234567890abcdefghijklmnop",
            projectName: "omg-agent-inbox</project>"
        )
        #expect(withBoth?.contains("<first_prompt>\n请帮我修复这里的超时问题\n</first_prompt>") == true)
        #expect(withBoth?.contains("<session_context>") == true)
        #expect(withBoth?.contains("<project>omg-agent-inbox<\\/project></project>") == true)
        #expect(withBoth?.contains("<native_title>") == true)
        #expect(withBoth?.contains("<\\/native_title>") == true)
        #expect(withBoth?.contains("sk-1234567890") == false)

        // When prompt fell back to nativeTitle, `<native_title>` is not duplicated.
        let deduplicated = AITitleService.userMessage(
            for: "Ray Gateway V2 Migration",
            nativeTitle: "Ray Gateway V2 Migration",
            projectName: nil
        )
        #expect(deduplicated == "<first_prompt>\nRay Gateway V2 Migration\n</first_prompt>")

        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("修复超时重试…"), AITestData.response(200))
        }
        let service = AITitleService(client: client, endpoints: { AITestData.endpoint })
        let title = await service.title(
            forFirstPrompt: "请帮我修复这里的超时问题",
            nativeTitle: "Timeout retry investigation",
            projectName: "omg-workspace"
        )
        #expect(title == "修复超时重试")
        let messages = (recorder.bodies.last?["messages"] as? [[String: Any]]) ?? []
        let user = messages.last?["content"] as? String ?? ""
        #expect(user.contains("<project>omg-workspace</project>"))
        #expect(user.contains("<native_title>Timeout retry investigation</native_title>"))
    }

    @Test func boundedTextKeepsWholeCharacters() {
        let text = String(repeating: "会", count: 10)
        let bounded = AITitleService.bounded(text, maxBytes: 7)
        #expect(bounded == String(repeating: "会", count: 2))
        #expect(AITitleService.bounded("  short  ", maxBytes: 100) == "short")
    }

    @Test func aQueuedRequestStartsOnlyAfterASlotIsReleased() async throws {
        let blocking = AIBlockingClient()
        let client = AIHTTPClient { _ in
            let title = try await blocking.complete(user: "x")
            return (AITestData.openAI(title), AITestData.response(200))
        }
        let service = AITitleService(client: client, endpoints: { AITestData.endpoint })

        let first = Task { await service.title(forFirstPrompt: "a") }
        let second = Task { await service.title(forFirstPrompt: "b") }
        #expect(await waitUntil { await blocking.startedCount == 2 })
        // Both slots are busy, so the third request returns without reaching the endpoint.
        #expect(await service.title(forFirstPrompt: "c") == nil)
        #expect(await blocking.startedCount == 2)

        await blocking.release()
        let values = await [first.value, second.value].compactMap { $0 }
        #expect(values.count == 2)
        // Once a slot is free, the next request runs.
        #expect(await service.title(forFirstPrompt: "d") != nil)
        #expect(await blocking.startedCount == 3)
    }

    @Test func threeConsecutiveFailuresPauseTheService() async {
        let counter = AIScriptedClient(error: AIHTTPError.httpStatus(429))
        let client = AIHTTPClient { _ in
            _ = try await counter.complete(user: "")
            return (try await counter.payload(), AITestData.response(200))
        }
        let service = AITitleService(
            client: client,
            endpoints: { AITestData.endpoint },
            limits: .init(consecutiveFailuresBeforePause: 3, pauseDuration: .seconds(2))
        )
        for _ in 0..<3 {
            #expect(await service.title(forFirstPrompt: "prompt") == nil)
        }
        #expect(await counter.callCount() == 3)
        #expect(await service.title(forFirstPrompt: "prompt") == nil)
        #expect(await counter.callCount() == 3)
    }

    @Test func aSuccessResetsTheFailureCount() async {
        let counter = AIScriptedClient(error: AIHTTPError.httpStatus(500))
        let client = AIHTTPClient { _ in
            _ = try await counter.complete(user: "")
            return (try await counter.payload(), AITestData.response(200))
        }
        let service = AITitleService(
            client: client,
            endpoints: { AITestData.endpoint },
            limits: .init(consecutiveFailuresBeforePause: 3, pauseDuration: .seconds(300))
        )
        #expect(await service.title(forFirstPrompt: "one") == nil)
        #expect(await service.title(forFirstPrompt: "two") == nil)
        await counter.setError(nil)
        await counter.setResponse("Recovered")
        #expect(await service.title(forFirstPrompt: "three") == "Recovered")
        await counter.setError(AIHTTPError.httpStatus(500))
        #expect(await service.title(forFirstPrompt: "four") == nil)
        #expect(await counter.callCount() == 4)
    }

    @Test func unauthorizedPausesUntilTheEndpointChanges() async {
        let counter = AIScriptedClient(error: AIHTTPError.httpStatus(401))
        let client = AIHTTPClient { _ in
            _ = try await counter.complete(user: "")
            return (try await counter.payload(), AITestData.response(200))
        }
        let provider = SwitchingEndpointProvider(AITestData.endpoint)
        let service = AITitleService(
            client: client,
            endpoints: { await provider.current() },
            limits: .init(pauseDuration: .seconds(60))
        )

        #expect(await service.title(forFirstPrompt: "one") == nil)
        #expect(await counter.callCount() == 1)
        #expect(await service.title(forFirstPrompt: "two") == nil)
        #expect(await counter.callCount() == 1)

        // Changing the endpoint is the documented way out of an authentication pause.
        await counter.setError(nil)
        await counter.setResponse("Fixed")
        await provider.set(AIEndpoint(kind: .openAI, baseURL: URL(string: "https://other.example.com")!,
                                      model: "test-model", apiKey: "new-key"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await service.title(forFirstPrompt: "three") == "Fixed")
        #expect(await counter.callCount() == 2)
    }

    @Test func providerFailuresDoNotThrowToTheCaller() async {
        let counter = AIScriptedClient(error: AIHTTPError.httpStatus(500))
        let client = AIHTTPClient { _ in
            _ = try await counter.complete(user: "")
            return (try await counter.payload(), AITestData.response(200))
        }
        let service = AITitleService(client: client, endpoints: { AITestData.endpoint })
        #expect(await service.title(forFirstPrompt: "prompt") == nil)
    }

    @Test func freshlyPausedBreakerFailsFastWithoutPollingAndEmptyOutputsDoNotTripBreaker() async {
        let emptyClient = AIHTTPClient { _ in
            (AITestData.openAI("<think>long reasoning</think>"), AITestData.response(200))
        }
        let emptyService = AITitleService(
            client: emptyClient,
            endpoints: { AITestData.endpoint },
            limits: .init(consecutiveFailuresBeforePause: 2, pauseDuration: .seconds(30))
        )
        // Three empty/reasoning-only outputs must not trip the endpoint outage breaker.
        for _ in 0..<3 {
            #expect(await emptyService.title(forFirstPrompt: "prompt") == nil)
        }

        let counter = AIScriptedClient(error: AIHTTPError.httpStatus(503))
        let failingClient = AIHTTPClient { _ in
            _ = try await counter.complete(user: "")
            return (try await counter.payload(), AITestData.response(200))
        }
        let service = AITitleService(
            client: failingClient,
            endpoints: { AITestData.endpoint },
            limits: .init(consecutiveFailuresBeforePause: 3, pauseDuration: .seconds(30), pollInterval: .milliseconds(500))
        )
        for _ in 0..<3 {
            #expect(await service.title(forFirstPrompt: "prompt") == nil)
        }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await service.title(forFirstPrompt: "prompt") == nil)
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .milliseconds(250))
        #expect(await counter.callCount() == 3)
    }

    @Test func updatingTheAPIKeyOnTheSameEndpointClearsAnAuthenticationPause() async {
        let counter = AIScriptedClient(error: AIHTTPError.httpStatus(401))
        let client = AIHTTPClient { _ in
            _ = try await counter.complete(user: "")
            return (try await counter.payload(), AITestData.response(200))
        }
        let baseEndpoint = AIEndpoint(
            kind: .openAI,
            baseURL: URL(string: "https://api.example.com")!,
            model: "test-model",
            apiKey: "bad-key"
        )
        let provider = SwitchingEndpointProvider(baseEndpoint)
        let service = AITitleService(
            client: client,
            endpoints: { await provider.current() },
            limits: .init(pauseDuration: .seconds(60))
        )

        #expect(await service.title(forFirstPrompt: "one") == nil)
        #expect(await service.title(forFirstPrompt: "two") == nil)
        #expect(await counter.callCount() == 1)

        // Fixing ONLY the API key on the exact same baseURL + model lifts `authBlocked`.
        await counter.setError(nil)
        await counter.setResponse("Recovered Title")
        await provider.set(AIEndpoint(
            kind: .openAI,
            baseURL: URL(string: "https://api.example.com")!,
            model: "test-model",
            apiKey: "fixed-key"
        ))
        #expect(await service.title(forFirstPrompt: "three") == "Recovered Title")
        #expect(await counter.callCount() == 2)
    }

    @Test func forcedBatchRequestsQueueInFIFOOrderInsteadOfDroppingBeyondMaxInFlight() async {
        let blocking = AIBlockingClient()
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            let title = try await blocking.complete(user: "Renamed Tab")
            return (AITestData.openAI(title), AITestData.response(200))
        }
        let service = AITitleService(client: client, endpoints: { AITestData.endpoint })

        let firstWave = (1...2).map { index in
            Task {
                await service.title(
                    forFirstPrompt: "prompt-\(index)",
                    nativeTitle: nil,
                    projectName: nil,
                    force: true
                )
            }
        }
        #expect(await waitUntil { await blocking.startedCount == 2 })

        // Queue 3 additional forced requests in strict order while both slots are occupied.
        var queuedTasks: [Task<String?, Never>] = []
        for index in 3...5 {
            queuedTasks.append(Task {
                await service.title(
                    forFirstPrompt: "prompt-\(index)",
                    nativeTitle: nil,
                    projectName: nil,
                    force: true
                )
            })
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(await blocking.startedCount == 2)

        await blocking.release()
        #expect(await waitUntil { await blocking.startedCount == 5 })

        var results: [String] = []
        for task in firstWave + queuedTasks {
            if let value = await task.value {
                results.append(value)
            }
        }
        #expect(results.count == 5)
        let sentPrompts = recorder.bodies.compactMap { body -> String? in
            let messages = (body["messages"] as? [[String: Any]]) ?? []
            return messages.last?["content"] as? String
        }
        #expect(sentPrompts.count == 5)
        #expect(sentPrompts.dropFirst(2).enumerated().allSatisfy { offset, content in
            content.contains("prompt-\(offset + 3)")
        })
    }

    @Test func changingEndpointConfigurationRejectsQueuedWaitersWithoutLeakingSlots() async {
        let blocking = AIBlockingClient()
        let client = AIHTTPClient { _ in
            let title = try await blocking.complete(user: "Renamed")
            return (AITestData.openAI(title), AITestData.response(200))
        }
        let endpointA = AIEndpoint(
            kind: .openAI,
            baseURL: URL(string: "https://api.example.com")!,
            model: "model-a",
            apiKey: "key-a"
        )
        let endpointB = AIEndpoint(
            kind: .openAI,
            baseURL: URL(string: "https://api.example.com")!,
            model: "model-b",
            apiKey: "key-b"
        )
        let provider = SwitchingEndpointProvider(endpointA)
        let service = AITitleService(client: client, endpoints: { await provider.current() })

        let first = Task { await service.title(forFirstPrompt: "p1", nativeTitle: nil, projectName: nil, force: true) }
        let second = Task { await service.title(forFirstPrompt: "p2", nativeTitle: nil, projectName: nil, force: true) }
        #expect(await waitUntil { await blocking.startedCount == 2 })

        let queued = Task { await service.title(forFirstPrompt: "p3", nativeTitle: nil, projectName: nil, force: true) }
        try? await Task.sleep(for: .milliseconds(20))

        // Switch configuration and send a new request: queued `p3` from old config aborts cleanly.
        await provider.set(endpointB)
        let switched = Task { await service.title(forFirstPrompt: "p4", nativeTitle: nil, projectName: nil, force: true) }
        #expect(await queued.value == nil)

        await blocking.release()
        _ = await (first.value, second.value)
        #expect(await waitUntil { await blocking.startedCount == 3 })
        await blocking.release()
        #expect(await switched.value == "Renamed")
    }
}

actor SwitchingEndpointProvider {
    private var endpoint: AIEndpoint?

    init(_ endpoint: AIEndpoint?) {
        self.endpoint = endpoint
    }

    func set(_ endpoint: AIEndpoint?) {
        self.endpoint = endpoint
    }

    func current() -> AIEndpoint? {
        endpoint
    }
}
