import Foundation
import Testing
@testable import OMGMobileCore

private final class MockOMGControlWebSocket: OMGControlWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var incomingQueue: [Result<Data, Error>] = []
    private var waitingReceiver: CheckedContinuation<Data, Error>?
    private var isClosed = false
    private let onSend: @Sendable (MockOMGControlWebSocket, String) throws -> Void

    private(set) var resumed = false
    private(set) var cancelled = false
    private(set) var sentTexts: [String] = []

    init(onSend: @escaping @Sendable (MockOMGControlWebSocket, String) throws -> Void) {
        self.onSend = onSend
    }

    func resume() {
        lock.lock()
        resumed = true
        lock.unlock()
    }

    func sendText(_ text: String) async throws {
        try lock.withLock {
            if isClosed {
                throw URLError(.networkConnectionLost)
            }
            sentTexts.append(text)
        }
        try onSend(self, text)
    }

    func receiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Data, Error>? = lock.withLock {
                if !incomingQueue.isEmpty {
                    return incomingQueue.removeFirst()
                }
                if isClosed {
                    return .failure(URLError(.networkConnectionLost))
                }
                waitingReceiver = continuation
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    func cancelGoingAway() {
        lock.lock()
        cancelled = true
        isClosed = true
        let waiter = waitingReceiver
        waitingReceiver = nil
        lock.unlock()
        waiter?.resume(throwing: URLError(.cancelled))
    }

    func pushServerJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        enqueue(.success(data))
    }

    func simulateDrop(_ error: Error = URLError(.networkConnectionLost)) {
        lock.lock()
        isClosed = true
        let waiter = waitingReceiver
        waitingReceiver = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    private func enqueue(_ item: Result<Data, Error>) {
        lock.lock()
        if let waiter = waitingReceiver {
            waitingReceiver = nil
            lock.unlock()
            waiter.resume(with: item)
            return
        }
        incomingQueue.append(item)
        lock.unlock()
    }
}

struct OMGControlTransportTests {
    private final class SocketRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [MockOMGControlWebSocket] = []
        private var requests: [URLRequest] = []

        func record(socket: MockOMGControlWebSocket, request: URLRequest) {
            lock.withLock {
                sockets.append(socket)
                requests.append(request)
            }
        }

        func snapshot() -> (Int, URLRequest, MockOMGControlWebSocket) {
            lock.withLock {
                (sockets.count, requests[0], sockets[0])
            }
        }
    }

    @Test func multiplexesConcurrentCallsIgnoresRosterPushesAndReconnectsOnDrop() async throws {
        let recorder = SocketRecorder()

        let transport = OMGControlTransport(
            baseURL: URL(string: "ws://192.168.1.10:8791")!,
            token: "test-secret-token"
        ) { request in
            let socket = MockOMGControlWebSocket { sock, rawText in
                guard let data = rawText.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqID = obj["_request"] as? String,
                      let op = obj["t"] as? String else {
                    return
                }
                // Interleave an unsolicited roster broadcast (no `_request`) before every reply.
                sock.pushServerJSON([
                    "t": "roster",
                    "sessions": [["id": "abc"]],
                ])
                if op == "failMe" {
                    sock.pushServerJSON([
                        "t": "error",
                        "message": "Synthetic RPC error",
                        "_request": reqID,
                    ])
                } else {
                    sock.pushServerJSON([
                        "t": "ok",
                        "echo": op,
                        "path": obj["path"] as? String ?? "/",
                        "_request": reqID,
                    ])
                }
            }
            recorder.record(socket: socket, request: request)
            return socket
        }

        @Sendable func call(_ fields: [String: Any]) async throws -> [String: Any] {
            let reqData = try JSONSerialization.data(withJSONObject: fields)
            let replyData = try await transport.callJSONData(reqData)
            return try JSONSerialization.jsonObject(with: replyData) as? [String: Any] ?? [:]
        }

        // 1. Three concurrent RPCs share ONE persistent `/control` WebSocket!
        async let r1 = call(["t": "workspaces"])
        async let r2 = call(["t": "hosts"])
        async let r3 = call(["t": "directories", "path": "/Users/test"])
        let (workspacesReply, hostsReply, dirsReply) = try await (r1, r2, r3)

        #expect(workspacesReply["echo"] as? String == "workspaces")
        #expect(hostsReply["echo"] as? String == "hosts")
        #expect(dirsReply["echo"] as? String == "directories")
        #expect(dirsReply["path"] as? String == "/Users/test")
        #expect(await transport.connectionCount == 1)

        let (socketCount, firstRequest, firstSocket) = recorder.snapshot()
        #expect(socketCount == 1)
        #expect(firstRequest.url?.absoluteString == "ws://192.168.1.10:8791/control")
        #expect(firstRequest.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "omg.test-secret-token")

        // 2. Application-level error reply throws for that RPC while keeping the persistent socket alive!
        await #expect(throws: NSError.self) {
            _ = try await call(["t": "failMe"])
        }
        let followUp = try await call(["t": "hosts"])
        #expect(followUp["echo"] as? String == "hosts")
        #expect(await transport.connectionCount == 1)

        // 3. Simulate idle WebSocket drop -> next RPC automatically reconnects on a fresh WebSocket!
        firstSocket.simulateDrop()
        try await Task.sleep(for: .milliseconds(30))

        let afterDrop = try await call(["t": "workspaces"])
        #expect(afterDrop["echo"] as? String == "workspaces")
        #expect(await transport.connectionCount == 2)

        await transport.close()
    }
}
