import Darwin
import Foundation

/// How agent tabs get a conversation title.
enum AgentSessionTitleMode: String, CaseIterable, Sendable {
    case off
    case native
    case generate
}

enum AIEndpointProtocol: String, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic
}

enum AIEndpointError: Error, Equatable, Sendable {
    case empty
    case invalidURL
    case unsupportedScheme
    case credentialsInURL
    case queryNotAllowed
    /// Plain `http://` to a host that is not loopback, private or link-local.
    case insecureRemoteHost
}

struct AIEndpoint: Equatable, Sendable {
    let kind: AIEndpointProtocol
    let baseURL: URL
    let model: String
    let apiKey: String?
    /// Output budget requested for this model, in tokens; nil uses the caller's default.
    let maxOutputTokens: UInt?
    /// Size of the model's context window, in tokens; nil when unknown.
    let contextWindow: Int?

    init(
        kind: AIEndpointProtocol,
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        maxOutputTokens: UInt? = nil,
        contextWindow: Int? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.maxOutputTokens = maxOutputTokens
        self.contextWindow = contextWindow
    }

    /// The endpoint described by user-entered values, or nil while it is incomplete or invalid.
    static func configured(
        kind: AIEndpointProtocol,
        baseURL: String,
        model: String,
        apiKey: String?,
        maxOutputTokens: UInt? = nil,
        contextWindow: Int? = nil
    ) -> AIEndpoint? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let url = try? validatedBaseURL(baseURL) else { return nil }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIEndpoint(kind: kind, baseURL: url, model: model, apiKey: key?.isEmpty == false ? key : nil,
                          maxOutputTokens: maxOutputTokens, contextWindow: contextWindow)
    }

    /// Validates a user-entered base URL. A pasted request URL is cut back to its base.
    static func validatedBaseURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIEndpointError.empty }
        guard let url = URL(string: trimmed) else { throw AIEndpointError.invalidURL }
        return try normalizedBaseURL(url)
    }

    static func normalizedBaseURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AIEndpointError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AIEndpointError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw AIEndpointError.credentialsInURL
        }
        guard components.query == nil, components.fragment == nil else {
            throw AIEndpointError.queryNotAllowed
        }
        guard let host = components.host, !host.isEmpty else { throw AIEndpointError.invalidURL }
        guard scheme == "https" || isLocalHost(host) else { throw AIEndpointError.insecureRemoteHost }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/messages"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = path
        guard let normalized = components.url else { throw AIEndpointError.invalidURL }
        return normalized
    }

    /// Loopback, private-range and link-local hosts: the only ones reachable over plain HTTP.
    static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if let zone = name.firstIndex(of: "%") { name = String(name[..<zone]) }
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return false }

        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return isLocalIPv4(withUnsafeBytes(of: &v4) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isLocalIPv4(Array(bytes.suffix(4)))
            }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        }
        if name.contains(":") { return false }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        // A single-label name resolves on the local network only. Numeric labels
        // are excluded: the resolver reads them as packed IPv4 addresses.
        return !name.contains(".") && name.first?.isLetter == true
    }

    private static func isLocalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
