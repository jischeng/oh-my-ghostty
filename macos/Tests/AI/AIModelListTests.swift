import Foundation
import Testing
@testable import Ghostty

struct AIModelListTests {
    private static func endpoint(_ kind: AIEndpointProtocol, _ base: String, key: String? = "test-key") -> AIEndpoint {
        AIEndpoint(kind: kind, baseURL: URL(string: base)!, model: "", apiKey: key)
    }

    @Test func openAIListIsAGetUnderTheSameV1RuleWithBearerAuth() async throws {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.json(["object": "list", "data": [["id": "gpt-a"], ["id": "gpt-b"]]]),
                    AITestData.response(200))
        }
        let models = try await client.models(endpoint: Self.endpoint(.openAI, "https://api.example.com"))

        #expect(models == ["gpt-a", "gpt-b"])
        let request = try #require(recorder.all.first)
        #expect(recorder.all.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 15)

        // A base URL that already has a path is used as it is.
        #expect(try AIHTTPClient.modelListURL(for: Self.endpoint(.openAI, "https://proxy.example.com/openai"))
            .absoluteString == "https://proxy.example.com/openai/models")
        #expect(try AIHTTPClient.modelListURL(for: Self.endpoint(.openAI, "http://localhost:11434/v1"))
            .absoluteString == "http://localhost:11434/v1/models")
    }

    @Test func anthropicListUsesTheChatHeadersAndAsksForOnePage() async throws {
        let recorder = AIRequestRecorder()
        let client = AIHTTPClient { request in
            recorder.record(request)
            let data: [[String: Any]] = [["id": "claude-a", "type": "model"], ["id": "claude-b", "type": "model"]]
            return (AITestData.json(["data": data, "has_more": false]), AITestData.response(200))
        }
        let direct = Self.endpoint(.anthropic, "https://api.anthropic.com")
        #expect(try await client.models(endpoint: direct) == ["claude-a", "claude-b"])

        let request = try #require(recorder.all.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        // The same exceptions as the chat request: a /v1 base is not doubled, a proxy also gets Bearer.
        let proxied = try AIHTTPClient.modelListRequest(for: Self.endpoint(.anthropic, "https://proxy.example.com/v1"))
        #expect(proxied.url.absoluteString == "https://proxy.example.com/v1/models?limit=1000")
        #expect(proxied.method == "GET")
        #expect(proxied.body.isEmpty)
        #expect(proxied.headers["Authorization"] == "Bearer test-key")
        #expect(proxied.headers["x-api-key"] == "test-key")
        let keyless = try AIHTTPClient.modelListRequest(for: Self.endpoint(.anthropic, "https://proxy.example.com",
                                                                           key: nil))
        #expect(keyless.headers == ["anthropic-version": "2023-06-01"])
    }

    @Test func listParsingAcceptsTheCommonShapesAndCleansTheIDs() throws {
        func parse(_ object: Any) throws -> [String] {
            try AIHTTPClient.parseModelList(JSONSerialization.data(withJSONObject: object))
        }
        let mixed: [Any] = [["id": " a "], ["id": "a"], ["id": ""], ["name": "by-name"], "bare", 7, ["id": "bad\nid"]]
        #expect(try parse(["data": mixed]) == ["a", "by-name", "bare"])
        #expect(try parse(["models": [["name": "m1"], ["id": "m2"]]]) == ["m1", "m2"])
        #expect(try parse(["x", "y"]) == ["x", "y"])
        #expect(try parse(["data": [Any]()]).isEmpty)

        #expect(throws: AIHTTPError.malformedResponse) { try parse(["error": "nope"]) }
        #expect(throws: AIHTTPError.malformedResponse) {
            try AIHTTPClient.parseModelList(Data("<html>".utf8))
        }
    }

    @Test func theNumberOfListedModelsIsCapped() throws {
        let many = (0..<(AIHTTPClient.maxListedModels + 50)).map { ["id": "model-\($0)"] }
        let body = try JSONSerialization.data(withJSONObject: ["data": many])
        let parsed = try AIHTTPClient.parseModelList(body)
        #expect(parsed.count == AIHTTPClient.maxListedModels)
        #expect(parsed.first == "model-0")
        #expect(try AIHTTPClient.parseModelList(body, limit: 3) == ["model-0", "model-1", "model-2"])
    }

    @Test func listErrorsAreReportedWithoutRetry() async {
        let recorder = AIRequestRecorder()
        let unauthorized = AIHTTPClient { request in
            recorder.record(request)
            return (AITestData.json(["error": "bad key"]), AITestData.response(401))
        }
        await #expect(throws: AIHTTPError.httpStatus(401, detail: #"{"error":"bad key"}"#)) {
            try await unauthorized.models(endpoint: Self.endpoint(.openAI, "https://api.example.com"))
        }
        #expect(recorder.all.count == 1)

        let missing = AIHTTPClient { _ in (Data(), AITestData.response(404)) }
        await #expect(throws: AIHTTPError.httpStatus(404, detail: nil)) {
            try await missing.models(endpoint: Self.endpoint(.anthropic, "https://api.example.com"))
        }

        let insecure = AIHTTPClient { request in
            recorder.record(request)
            return (Data(), AITestData.response(200))
        }
        await #expect(throws: AIHTTPError.invalidEndpoint(.insecureRemoteHost)) {
            try await insecure.models(endpoint: Self.endpoint(.openAI, "http://api.example.com"))
        }
        #expect(recorder.all.count == 1)
    }

    @Test func anOversizedListIsRefusedButALargeOneIsRead() async throws {
        #expect(AIHTTPClient.Options.modelList.maxResponseBytes > AIHTTPClient.maxResponseBytes)
        let oversized = AIHTTPClient { _ in
            (Data(count: AIHTTPClient.Options.modelList.maxResponseBytes + 1), AITestData.response(200))
        }
        await #expect(throws: AIHTTPError.responseTooLarge) {
            try await oversized.models(endpoint: Self.endpoint(.openAI, "https://api.example.com"))
        }

        // Bigger than a title response, still inside the list budget.
        let padding = String(repeating: "x", count: AIHTTPClient.maxResponseBytes)
        let large = AIHTTPClient { _ in
            (AITestData.json(["data": [["id": "kept", "description": padding]]]), AITestData.response(200))
        }
        #expect(try await large.models(endpoint: Self.endpoint(.openAI, "https://api.example.com")) == ["kept"])
    }
}
