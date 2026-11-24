import Foundation
@testable import Ghostty

/// Thread-safe request recorder for the injected `AIHTTPClient` transport.
final class AIRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var bodies: [[String: Any]] {
        all.compactMap { request in
            request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }
    }
}

enum AITestData {
    static let endpoint = AIEndpoint(
        kind: .openAI,
        baseURL: URL(string: "https://api.example.com")!,
        model: "test-model",
        apiKey: "test-key"
    )

    static func response(_ status: Int, url: URL = endpoint.baseURL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func openAI(_ content: Any?, finishReason: String? = "stop") -> Data {
        var message: [String: Any] = [:]
        if content != nil { message["content"] = content }
        let finish: Any = finishReason ?? NSNull()
        return json([
            "choices": [[
                "message": message,
                "finish_reason": finish,
            ]],
        ])
    }

    static func anthropic(_ blocks: [[String: Any]], stopReason: String? = "end_turn") -> Data {
        let stop: Any = stopReason ?? NSNull()
        return json(["content": blocks, "stop_reason": stop])
    }
}

/// Client fake for `AITitleService` tests. Records calls and throws `error` when set.
actor AIScriptedClient {
    private var response: String?
    private(set) var error: Error?
    private(set) var calls: [String] = []

    init(response: String? = "Plan the release", error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func setError(_ error: Error?) {
        self.error = error
    }

    func setResponse(_ text: String?) {
        self.response = text
    }

    func complete(user: String) throws -> String? {
        calls.append(user)
        if let error { throw error }
        return response
    }

    func callCount() -> Int {
        calls.count
    }

    /// The wire body the transport should return for the current scripted response.
    func payload() throws -> Data {
        if let error { throw error }
        return AITestData.openAI(response ?? "")
    }
}

/// Client fake that parks every call until it is released, for concurrency-limit tests.
actor AIBlockingClient {
    private(set) var started = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func complete(user: String) async throws -> String? {
        started += 1
        guard !released else { return user }
        await withCheckedContinuation { parked.append($0) }
        return user
    }

    var startedCount: Int { started }
    var isParked: Bool { !parked.isEmpty }

    /// Lets every parked call finish; later calls return without waiting.
    func release() {
        released = true
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

/// Polls until `condition` holds; actor state changes arrive on another executor.
func waitUntil(
    timeout: Duration = .seconds(2),
    poll: Duration = .milliseconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return await condition()
}
