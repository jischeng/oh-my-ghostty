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
