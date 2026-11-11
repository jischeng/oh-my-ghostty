import Foundation

/// Extra OMG operations share the authenticated control endpoint, with request
/// identities so roster pushes cannot be mistaken for an operation's reply.
@MainActor
final class OMGControl {
    private var tasks: [UUID: URLSessionWebSocketTask] = [:]
    private let session = URLSession(configuration: .ephemeral)
    private let endpoint: DeviceEndpoint

    init(_ endpoint: DeviceEndpoint) { self.endpoint = endpoint }
    deinit { session.invalidateAndCancel() }

    func call(_ fields: [String: Any]) async throws -> [String: Any] {
        let id = UUID()
        var request = URLRequest(url: endpoint.url.appendingPathComponent("control"))
        request.timeoutInterval = 20
        if let token = endpoint.token { request.setValue("omg.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        let socket = session.webSocketTask(with: request)
        tasks[id] = socket
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil); tasks[id] = nil }
        var fields = fields
        fields["_request"] = id.uuidString
        let payload = try JSONSerialization.data(withJSONObject: fields)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await socket.send(.string(text))
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while true {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       object["_request"] as? String == id.uuidString { return data }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                socket.cancel(with: .goingAway, reason: nil)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            let data = try await group.next()!
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if result["t"] as? String == "error" {
                throw NSError(domain: "OMG", code: 1, userInfo: [NSLocalizedDescriptionKey: result["message"] as? String ?? "Request failed"])
            }
            return result
        }
    }
}
