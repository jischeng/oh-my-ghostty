import Foundation
import Testing
@testable import Ghostty

struct AIEndpointTests {
    @Test func baseURLsNormalizeTrailingSlashesAndPastedRequestPaths() throws {
        let cases = [
            "https://api.example.com": "https://api.example.com",
            "https://api.example.com/": "https://api.example.com",
            "  https://api.example.com///  ": "https://api.example.com",
            "https://api.example.com/v1/": "https://api.example.com/v1",
            "https://api.example.com/v1/chat/completions": "https://api.example.com/v1",
            "https://api.example.com/chat/completions/": "https://api.example.com",
            "https://api.example.com/v1/messages": "https://api.example.com/v1",
            "HTTPS://API.EXAMPLE.COM/v1": "https://api.example.com/v1",
        ]
        for (input, expected) in cases {
            #expect(try AIEndpoint.validatedBaseURL(input).absoluteString == expected, "\(input)")
        }
    }

    @Test func baseURLsRejectUnsupportedShapes() {
        #expect(throws: AIEndpointError.empty) { try AIEndpoint.validatedBaseURL("   ") }
        #expect(throws: AIEndpointError.unsupportedScheme) {
            try AIEndpoint.validatedBaseURL("ftp://api.example.com")
        }
        #expect(throws: AIEndpointError.credentialsInURL) {
            try AIEndpoint.validatedBaseURL("https://user:secret@api.example.com")
        }
        #expect(throws: AIEndpointError.queryNotAllowed) {
            try AIEndpoint.validatedBaseURL("https://api.example.com/?key=1")
        }
        #expect(throws: AIEndpointError.self) { try AIEndpoint.validatedBaseURL("not a url") }
    }

    @Test func plainHTTPIsLimitedToLocalHosts() throws {
        for host in ["http://127.0.0.1", "http://localhost", "http://localhost:11434", "http://10.1.2.3",
                     "http://192.168.0.10", "http://172.16.0.1", "http://172.31.255.1", "http://169.254.1.1",
                     "http://[::1]", "http://my-mac.local", "http://devbox"] {
            #expect(try AIEndpoint.validatedBaseURL("\(host)/v1").scheme == "http", "\(host)")
        }
        #expect(AIEndpoint.isLocalHost("::1"))
        #expect(AIEndpoint.isLocalHost("fe80::1%en0"))
        #expect(AIEndpoint.isLocalHost("fd00:ec2::254"))
        #expect(!AIEndpoint.isLocalHost("2606:4700::1111"))
        for host in ["api.example.com", "8.8.8.8", "172.32.0.1", "134744072", "example.com.local.evil"] {
            #expect(!AIEndpoint.isLocalHost(host), "\(host)")
            #expect(throws: AIEndpointError.insecureRemoteHost) {
                try AIEndpoint.validatedBaseURL("http://\(host)")
            }
        }
        #expect(try AIEndpoint.validatedBaseURL("https://api.example.com").scheme == "https")
    }

    @Test func requestURLsFollowEachWireProtocol() throws {
        let base = URL(string: "https://api.example.com")!
        #expect(try AIHTTPClient.requestURL(for: AIEndpoint(kind: .openAI, baseURL: base, model: "m"))
            .absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(try AIHTTPClient.requestURL(for: AIEndpoint(kind: .openAI,
                                                           baseURL: URL(string: "https://api.example.com/v1")!,
                                                           model: "m"))
            .absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(try AIHTTPClient.requestURL(for: AIEndpoint(kind: .openAI,
                                                           baseURL: URL(string: "https://proxy.example.com/openai")!,
                                                           model: "m"))
            .absoluteString == "https://proxy.example.com/openai/chat/completions")
        #expect(try AIHTTPClient.requestURL(for: AIEndpoint(kind: .anthropic, baseURL: base, model: "m"))
            .absoluteString == "https://api.example.com/v1/messages")
        #expect(try AIHTTPClient.requestURL(for: AIEndpoint(kind: .anthropic,
                                                           baseURL: URL(string: "https://api.example.com/v1")!,
                                                           model: "m"))
            .absoluteString == "https://api.example.com/v1/messages")
    }

    @Test func configuredEndpointNeedsURLAndModel() {
        #expect(AIEndpoint.configured(kind: .openAI, baseURL: "", model: "gpt", apiKey: nil) == nil)
        #expect(AIEndpoint.configured(kind: .openAI, baseURL: "https://api.example.com", model: "  ", apiKey: nil) == nil)
        #expect(AIEndpoint.configured(kind: .openAI, baseURL: "http://example.com", model: "gpt", apiKey: nil) == nil)
        let endpoint = AIEndpoint.configured(kind: .openAI, baseURL: "https://api.example.com/",
                                             model: " gpt ", apiKey: "  ")
        #expect(endpoint?.baseURL.absoluteString == "https://api.example.com")
        #expect(endpoint?.model == "gpt")
        #expect(endpoint?.apiKey == nil)
        let keyed = AIEndpoint.configured(kind: .anthropic, baseURL: "https://api.example.com",
                                          model: "claude", apiKey: " key ")
        #expect(keyed?.apiKey == "key")
    }
}
