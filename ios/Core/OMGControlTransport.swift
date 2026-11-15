import Foundation

/// Abstraction over a single `/control` WebSocket connection so unit tests can
/// exercise concurrent RPC multiplexing, push-frame filtering, and reconnects
/// deterministically while production uses `URLSessionWebSocketTask`.
public protocol OMGControlWebSocket: AnyObject, Sendable {
    func resume()
    func sendText(_ text: String) async throws
    func receiveData() async throws -> Data
    func cancelGoingAway()
}

public final class URLSessionOMGControlWebSocket: OMGControlWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(_ task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func resume() {
        task.resume()
    }

    public func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receiveData() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case .data(let value):
            return value
        case .string(let value):
            return Data(value.utf8)
        @unknown default:
            return Data()
        }
    }

    public func cancelGoingAway() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

private struct ReusedSocketDroppedError: Error {}

/// Actor-serialized multiplexer for OMG `/control` RPC requests over a single
/// persistent WebSocket connection with `_request` correlation and automatic
/// reconnect when an idle/dropped connection closes.
public actor OMGControlTransport {
    private struct PendingCall {
        let continuation: CheckedContinuation<Data, Error>
        let wasReusedSocket: Bool
        let allowSocketDropRetry: Bool
        let isIdempotent: Bool
        var didSend: Bool
    }

    private static let idempotentTypes: Set<String> = [
        "workspaces",
        "hosts",
        "directories",
        "files",
        "readFile",
        "ping",
    ]

    private let controlURL: URL
    private let token: String?
    private let timeoutSeconds: Double
    private let ownedSession: URLSession?
    private let makeSocket: @Sendable (URLRequest) -> any OMGControlWebSocket

    private var activeSocket: (any OMGControlWebSocket)?
    private var activeGeneration: UInt64 = 0
    private var socketHasBecomeReady = false
    private var receiveLoopTask: Task<Void, Never>?
    private var pending: [UUID: PendingCall] = [:]
    private var isClosed = false
    public private(set) var connectionCount = 0

    public init(
        baseURL: URL,
        token: String?,
        timeoutSeconds: Double = 20,
        makeSocket: (@Sendable (URLRequest) -> any OMGControlWebSocket)? = nil
    ) {
        self.controlURL = baseURL.appendingPathComponent("control")
        self.token = token
        self.timeoutSeconds = timeoutSeconds
        if let makeSocket {
            self.ownedSession = nil
            self.makeSocket = makeSocket
        } else {
            let session = URLSession(configuration: .ephemeral)
            self.ownedSession = session
            self.makeSocket = { request in
                URLSessionOMGControlWebSocket(session.webSocketTask(with: request))
            }
        }
    }

    deinit {
        receiveLoopTask?.cancel()
        activeSocket?.cancelGoingAway()
        ownedSession?.invalidateAndCancel()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let error = URLError(.cancelled)
        tearDownCurrentSocket(error: error, allowRetry: false)
        ownedSession?.invalidateAndCancel()
    }

    public func callJSONData(_ requestObjectData: Data) async throws -> Data {
        let replyData: Data
        do {
            replyData = try await attemptCall(
                requestObjectData: requestObjectData,
                allowSocketDropRetry: true
            )
        } catch is ReusedSocketDroppedError {
            replyData = try await attemptCall(
                requestObjectData: requestObjectData,
                allowSocketDropRetry: false
            )
        }
        if let result = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
           result["t"] as? String == "error" {
            throw NSError(
                domain: "OMG",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: result["message"] as? String ?? "Request failed",
                ]
            )
        }
        return replyData
    }

    private func attemptCall(
        requestObjectData: Data,
        allowSocketDropRetry: Bool
    ) async throws -> Data {
        guard !isClosed else {
            throw URLError(.cancelled)
        }
        guard var fields = try JSONSerialization.jsonObject(with: requestObjectData) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let opType = fields["t"] as? String ?? ""
        let isIdempotent = Self.idempotentTypes.contains(opType)
        let requestID = UUID()
        fields["_request"] = requestID.uuidString
        let payload = try JSONSerialization.data(withJSONObject: fields)
        guard let wireText = String(data: payload, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let wasReusedSocket = (activeSocket != nil && socketHasBecomeReady)
        let (socket, generation) = ensureConnected()
        let timeoutSeconds = self.timeoutSeconds
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            await self?.timeoutRequest(requestID, generation: generation)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pending[requestID] = PendingCall(
                    continuation: continuation,
                    wasReusedSocket: wasReusedSocket,
                    allowSocketDropRetry: allowSocketDropRetry,
                    isIdempotent: isIdempotent,
                    didSend: false
                )
                Task { [weak self] in
                    do {
                        try await socket.sendText(wireText)
                        await self?.markSent(requestID)
                    } catch {
                        await self?.handleSocketFailure(generation: generation, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(requestID)
            }
        }
    }

    private func ensureConnected() -> (any OMGControlWebSocket, UInt64) {
        if let existing = activeSocket {
            return (existing, activeGeneration)
        }
        var request = URLRequest(url: controlURL)
        request.timeoutInterval = timeoutSeconds
        if let token {
            request.setValue("omg.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        activeGeneration &+= 1
        let generation = activeGeneration
        socketHasBecomeReady = false
        connectionCount += 1
        let socket = makeSocket(request)
        activeSocket = socket
        socket.resume()
        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await socket.receiveData()
                    guard let self else { return }
                    let keepRunning = await self.handleIncomingFrame(data, generation: generation)
                    if !keepRunning { return }
                } catch {
                    await self?.handleSocketFailure(generation: generation, error: error)
                    return
                }
            }
        }
        return (socket, generation)
    }

    private func markSent(_ requestID: UUID) {
        pending[requestID]?.didSend = true
    }

    private func handleIncomingFrame(_ data: Data, generation: UInt64) -> Bool {
        guard activeGeneration == generation else { return false }
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        socketHasBecomeReady = true
        guard let reqString = object["_request"] as? String,
              let reqID = UUID(uuidString: reqString) else {
            // Unsolicited server push (e.g. roster update) has no `_request` field.
            return true
        }
        if let entry = pending.removeValue(forKey: reqID) {
            entry.continuation.resume(returning: data)
        }
        return true
    }

    private func cancelRequest(_ requestID: UUID) {
        if let entry = pending.removeValue(forKey: requestID) {
            entry.continuation.resume(throwing: CancellationError())
        }
    }

    private func timeoutRequest(_ requestID: UUID, generation: UInt64) {
        guard activeGeneration == generation,
              let entry = pending.removeValue(forKey: requestID) else { return }
        entry.continuation.resume(throwing: URLError(.timedOut))
        tearDownCurrentSocket(error: URLError(.timedOut), allowRetry: false)
    }

    private func handleSocketFailure(generation: UInt64, error: Error) {
        guard activeGeneration == generation else { return }
        tearDownCurrentSocket(error: error, allowRetry: true)
    }

    private func tearDownCurrentSocket(error: Error, allowRetry: Bool) {
        activeGeneration &+= 1
        socketHasBecomeReady = false
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        activeSocket?.cancelGoingAway()
        activeSocket = nil

        let drained = pending
        pending.removeAll()
        for (_, entry) in drained {
            if allowRetry,
               entry.allowSocketDropRetry,
               entry.wasReusedSocket,
               (!entry.didSend || entry.isIdempotent) {
                entry.continuation.resume(throwing: ReusedSocketDroppedError())
            } else {
                entry.continuation.resume(throwing: error)
            }
        }
    }
}
