import Foundation

/// Extra OMG operations multiplex over a persistent authenticated `/control`
/// WebSocket per endpoint, using `_request` identities so roster pushes and
/// concurrent RPC replies never collide and reconnecting automatically on drop.
@MainActor
final class OMGControl {
    private struct EndpointKey: Hashable {
        let url: URL
        let token: String?
    }

    private static var sharedPool: [EndpointKey: OMGControl] = [:]

    private let transport: OMGControlTransport
    private let ownsTransport: Bool

    init(_ endpoint: DeviceEndpoint) {
        self.transport = OMGControlTransport(baseURL: endpoint.url, token: endpoint.token)
        self.ownsTransport = true
    }

    private init(shared endpoint: DeviceEndpoint) {
        self.transport = OMGControlTransport(baseURL: endpoint.url, token: endpoint.token)
        self.ownsTransport = false
    }

    deinit {
        guard ownsTransport else { return }
        let transport = self.transport
        Task { await transport.close() }
    }

    static func shared(for endpoint: DeviceEndpoint) -> OMGControl {
        let key = EndpointKey(url: endpoint.url, token: endpoint.token)
        if let cached = sharedPool[key] {
            return cached
        }
        let client = OMGControl(shared: endpoint)
        sharedPool[key] = client
        return client
    }

    func close() async {
        await transport.close()
    }

    func call(_ fields: [String: Any]) async throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: fields)
        let replyData = try await transport.callJSONData(requestData)
        return try JSONSerialization.jsonObject(with: replyData) as? [String: Any] ?? [:]
    }
}
