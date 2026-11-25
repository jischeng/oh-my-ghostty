import Foundation
import Testing
@testable import Ghostty

struct AIHTTPClientTests {
    @Test func openAIRequestCarriesBearerAuthAndTheChatBody() async throws {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("Ship the inbox"), AITestData.response(200))
        }
        let title = try await client.complete(system: "sys", user: "user", endpoint: AITestData.endpoint)

        #expect(title == "Ship the inbox")
        let request = try #require(recorder.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 15)
        let body = try #require(recorder.bodies.first)
        #expect(body["model"] as? String == "test-model")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["temperature"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.first?["content"] as? String == "sys")
        #expect(messages.last?["content"] as? String == "user")
    }

    @Test func anthropicRequestUsesItsHeadersAndMessagesShape() async throws {
        let recorder = AIRequestRecorder()
        let endpoint = AIEndpoint(kind: .anthropic,
                                  baseURL: URL(string: "https://api.anthropic.com")!,
                                  model: "claude-test", apiKey: "sk-ant-test")
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.anthropic([["type": "text", "text": "Plan"]]), AITestData.response(200))
        }
        #expect(try await client.complete(user: "user", endpoint: endpoint) == "Plan")

        let request = try #require(recorder.all.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(recorder.bodies.first)
        #expect(body["model"] as? String == "claude-test")
        #expect(body["system"] as? String == AIHTTPClient.systemPrompt)
        #expect(body["max_tokens"] as? Int == 1024)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
    }

    @Test func aProxiedAnthropicHostAlsoReceivesABearerHeader() async throws {
        let recorder = AIRequestRecorder()
        let endpoint = AIEndpoint(kind: .anthropic,
                                  baseURL: URL(string: "https://proxy.example.com")!,
                                  model: "claude-test", apiKey: "proxy-key")
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.anthropic([["type": "text", "text": "Plan"]]), AITestData.response(200))
        }
        _ = try await client.complete(user: "user", endpoint: endpoint)
        let request = try #require(recorder.all.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer proxy-key")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "proxy-key")
    }

    @Test func emptyKeySendsNoAuthorizationHeader() async throws {
        let recorder = AIRequestRecorder()
        let endpoint = AIEndpoint(kind: .openAI,
                                  baseURL: URL(string: "http://localhost:11434")!,
                                  model: "local", apiKey: nil)
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("Local title"), AITestData.response(200))
        }
        _ = try await client.complete(user: "user", endpoint: endpoint)
        #expect(try AIHTTPClient.request(for: endpoint, user: "user").headers["Authorization"] == nil)
        #expect(try AIHTTPClient.request(for: endpoint, user: "user").headers["x-api-key"] == nil)
    }

    @Test func maxTokensIsRetriedOnceWithTheCompletionFieldAndRemembered() async throws {
        let recorder = AIRequestRecorder()
        let rejection = AITestData.json(["error": ["message": "Unsupported parameter: 'max_tokens' is not supported. Use 'max_completion_tokens' instead."]])
        let client = AIHTTPClient { request in
            recorder.record(request)
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            if body["max_completion_tokens"] != nil {
                return (AITestData.openAI("Retried title"), AITestData.response(200))
            }
            return (rejection, AITestData.response(400))
        }

        #expect(try await client.complete(user: "first", endpoint: AITestData.endpoint) == "Retried title")
        #expect(recorder.bodies.count == 2)
        #expect(recorder.bodies.first?["max_tokens"] != nil)
        #expect(recorder.bodies.last?["max_completion_tokens"] != nil)
        #expect(recorder.bodies.last?["max_tokens"] == nil)

        // The endpoint's preference is remembered for the same base URL and model.
        #expect(try await client.complete(user: "second", endpoint: AITestData.endpoint) == "Retried title")
        #expect(recorder.bodies.count == 3)
        #expect(recorder.bodies.last?["max_completion_tokens"] != nil)
    }

    @Test func otherClientErrorsAreNotRetried() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.json(["error": "bad model"]), AITestData.response(400))
        }
        await #expect(throws: AIHTTPError.httpStatus(400, detail: #"{"error":"bad model"}"#)) {
            try await client.complete(user: "user", endpoint: AITestData.endpoint)
        }
        #expect(recorder.all.count == 1)
        await #expect(throws: AIHTTPError.httpStatus(429, detail: nil)) {
            let limited = AIHTTPClient { request in
                recorder.record(request)
                return (Data(), AITestData.response(429))
            }
            _ = try await limited.complete(user: "user", endpoint: AITestData.endpoint)
        }
        #expect(recorder.all.count == 2)
    }

    @Test func openAIContentAsTextPartsIsJoined() async throws {
        let parts: [[String: Any]] = [
            ["type": "text", "text": "Inbox "],
            ["type": "reasoning", "text": "ignored"],
            ["type": "text", "text": "polish"],
        ]
        let client = AIHTTPClient { _ in
            (AITestData.openAI(parts), AITestData.response(200))
        }
        #expect(try await client.complete(user: "user", endpoint: AITestData.endpoint) == "Inbox polish")
    }

    @Test func reasoningContentIsIgnored() async throws {
        let body = AITestData.json([
            "choices": [[
                "message": ["content": "Real title", "reasoning_content": "a long private chain"],
                "finish_reason": "stop",
            ]],
        ])
        let client = AIHTTPClient { _ in (body, AITestData.response(200)) }
        #expect(try await client.complete(user: "user", endpoint: AITestData.endpoint) == "Real title")
    }

    @Test func onlyTextBlocksAreJoinedFromAnthropicResponses() async throws {
        let body = AITestData.anthropic([
            ["type": "thinking", "thinking": "internal"],
            ["type": "text", "text": "Polish "],
            ["type": "text", "text": "the inbox"],
        ])
        let client = AIHTTPClient { _ in (body, AITestData.response(200)) }
        let endpoint = AIEndpoint(kind: .anthropic, baseURL: URL(string: "https://api.example.com")!,
                                  model: "claude-test", apiKey: "k")
        #expect(try await client.complete(user: "user", endpoint: endpoint) == "Polish the inbox")
    }

    @Test func thinkBlocksAreStrippedAndUnterminatedOnesAreEmpty() async throws {
        let closed = AIHTTPClient { _ in
            (AITestData.openAI("<think>weighing options</think>Name the tab"), AITestData.response(200))
        }
        #expect(try await closed.complete(user: "user", endpoint: AITestData.endpoint) == "Name the tab")

        let unterminated = AIHTTPClient { _ in
            (AITestData.openAI("<think>still thinking"), AITestData.response(200))
        }
        await #expect(throws: AIHTTPError.emptyOutput) {
            try await unterminated.complete(user: "user", endpoint: AITestData.endpoint)
        }
        #expect(AIHTTPClient.strippingThinkBlocks("<THINK>x</THINK>Title") == "Title")
        #expect(AIHTTPClient.strippingThinkBlocks("Title <think>open") == "Title")
    }

    @Test func emptyTextWithALengthStopIsAnExplicitTruncation() async {
        let openAI = AIHTTPClient { _ in
            (AITestData.openAI(nil, finishReason: "length"), AITestData.response(200))
        }
        await #expect(throws: AIHTTPError.truncatedOutput) {
            try await openAI.complete(user: "user", endpoint: AITestData.endpoint)
        }
        let anthropicBody = AITestData.anthropic([["type": "thinking", "thinking": "spent it"]],
                                                 stopReason: "max_tokens")
        let anthropic = AIHTTPClient { _ in (anthropicBody, AITestData.response(200)) }
        let endpoint = AIEndpoint(kind: .anthropic, baseURL: URL(string: "https://api.example.com")!,
                                  model: "claude-test", apiKey: nil)
        await #expect(throws: AIHTTPError.truncatedOutput) {
            try await anthropic.complete(user: "user", endpoint: endpoint)
        }
    }

    @Test func emptyTextWithoutTruncationIsAnEmptyOutputError() async {
        let client = AIHTTPClient { _ in (AITestData.openAI("   "), AITestData.response(200)) }
        await #expect(throws: AIHTTPError.emptyOutput) {
            try await client.complete(user: "user", endpoint: AITestData.endpoint)
        }
    }

    @Test func malformedAndOversizedBodiesFail() async {
        let malformed = AIHTTPClient { _ in (Data("not json".utf8), AITestData.response(200)) }
        await #expect(throws: AIHTTPError.malformedResponse) {
            try await malformed.complete(user: "user", endpoint: AITestData.endpoint)
        }
        let noChoices = AIHTTPClient { _ in (AITestData.json(["choices": []]), AITestData.response(200)) }
        await #expect(throws: AIHTTPError.malformedResponse) {
            try await noChoices.complete(user: "user", endpoint: AITestData.endpoint)
        }
        let oversized = AIHTTPClient { _ in
            (Data(count: AIHTTPClient.maxResponseBytes + 1), AITestData.response(200))
        }
        await #expect(throws: AIHTTPError.responseTooLarge) {
            try await oversized.complete(user: "user", endpoint: AITestData.endpoint)
        }
    }

    @Test func transportFailuresPropagateToTheService() async {
        struct Offline: Error {}
        let client = AIHTTPClient { _ in throw Offline() }
        await #expect(throws: Offline.self) {
            try await client.complete(user: "user", endpoint: AITestData.endpoint)
        }
    }

    @Test func generateReturnsTheRawTextWithItsOwnBudget() async throws {
        let recorder = AIRequestRecorder()
        let message = "feat: add the inbox\n\n- keep \"quotes\" and a second line"
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("<think>plan</think>" + message), AITestData.response(200))
        }
        let completion = try await client.generate(system: "sys", user: "user", endpoint: AITestData.endpoint,
                                                   options: .message)
        // Nothing of the title clean-up applies: quotes, markdown and line breaks survive.
        #expect(completion == AIHTTPClient.Completion(text: message, truncated: false))
        let request = try #require(recorder.all.first)
        #expect(request.timeoutInterval == 75)
        #expect(recorder.bodies.first?["max_tokens"] as? Int == 4096)
        #expect(AIHTTPClient.Options.message.resourceTimeout == 90)
        #expect(AIHTTPClient.Options.title == AIHTTPClient.Options())
        #expect(AIHTTPClient.Options.title.requestTimeout == 15)
        #expect(AIHTTPClient.Options.title.resourceTimeout == 20)

        var custom = AIHTTPClient.Options.message
        custom.maxOutputTokens = 321
        custom.requestTimeout = 7
        _ = try await client.generate(system: "sys", user: "user", endpoint: AITestData.endpoint, options: custom)
        #expect(recorder.all.last?.timeoutInterval == 7)
        #expect(recorder.bodies.last?["max_tokens"] as? Int == 321)
    }

    @Test func generateReportsACutOffAnswerAndHonoursItsResponseCap() async throws {
        let cut = AIHTTPClient { _ in
            (AITestData.openAI("feat: half a mess", finishReason: "length"), AITestData.response(200))
        }
        let completion = try await cut.generate(system: "s", user: "u", endpoint: AITestData.endpoint,
                                                options: .message)
        #expect(completion.truncated)
        #expect(completion.text == "feat: half a mess")

        // Larger than a title response is fine for a message, up to the message cap.
        let body = String(repeating: "a", count: AIHTTPClient.maxResponseBytes + 10)
        let long = AIHTTPClient { _ in (AITestData.openAI(body), AITestData.response(200)) }
        #expect(try await long.generate(system: "s", user: "u", endpoint: AITestData.endpoint,
                                        options: .message).text == body)
        await #expect(throws: AIHTTPError.responseTooLarge) {
            try await long.complete(user: "u", endpoint: AITestData.endpoint)
        }
    }

    @Test func aCancelledTaskNeverReachesTheEndpoint() async {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("Never"), AITestData.response(200))
        }
        let task = Task {
            // Wait for the cancellation below before asking.
            while !Task.isCancelled { await Task.yield() }
            return try await client.generate(system: "s", user: "u", endpoint: AITestData.endpoint,
                                             options: .message)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.all.isEmpty)
    }

    @Test func aPlainHTTPRemoteEndpointIsRefusedBeforeAnyRequest() async {
        let recorder = AIRequestRecorder()
        let endpoint = AIEndpoint(kind: .openAI, baseURL: URL(string: "http://api.example.com")!,
                                  model: "m", apiKey: nil)
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.openAI("Nope"), AITestData.response(200))
        }
        await #expect(throws: AIHTTPError.invalidEndpoint(.insecureRemoteHost)) {
            try await client.complete(user: "user", endpoint: endpoint)
        }
        #expect(recorder.all.isEmpty)
    }

    @Test func systemPromptEnforcesConciseEllipsisFreeSelfContainedTitles() {
        let chinese = AIHTTPClient.systemPrompt(language: .simplifiedChinese)
        let english = AIHTTPClient.systemPrompt(language: .english)

        #expect(chinese.contains("Reply in Simplified Chinese"))
        #expect(english.contains("Reply in English"))
        for prompt in [chinese, english] {
            #expect(prompt.contains("4–10 Chinese characters"))
            #expect(prompt.contains("2–4 English words"))
            #expect(prompt.contains("Never use ellipses"))
            #expect(prompt.contains("never cut off mid-phrase"))
            #expect(prompt.contains("shorthand"))
            #expect(!prompt.localizedCaseInsensitiveContains("antigravity"))
            #expect(!prompt.localizedCaseInsensitiveContains("claude-mem"))
        }
    }
}
