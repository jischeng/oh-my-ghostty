import XCTest
@testable import OMGMobileCore

final class MobileSessionRouteTests: XCTestCase {
    private let endpoint = String(repeating: "a", count: 64)
    private let session = "12345678-1234-1234-1234-123456789abc"
    private let generation = String(repeating: "b", count: 32)

    func testRowIdentityPreservesTheExactSessionAndGeneration() {
        let route = MobileSessionRoute("\(endpoint)/\(session)/\(generation)")
        XCTAssertEqual(route?.endpointID, endpoint)
        XCTAssertEqual(route?.sessionID, session)
        XCTAssertEqual(route?.generation, generation)
    }

    func testMissingGenerationCannotBecomeAnAttachmentToTheLatestProcess() {
        XCTAssertNil(MobileSessionRoute("\(endpoint)/\(session)"))
        XCTAssertNil(MobileSessionRoute("\(endpoint)/\(session)/"))
    }

    func testMalformedAndPathLikeIdentitiesAreRejected() {
        for value in [
            "../\(session)/\(generation)", "\(endpoint)/../\(generation)",
            "\(endpoint)/\(session)/\(generation)/extra", "\(endpoint)/\(session)/invalid",
            "/\(session)/\(generation)",
        ] {
            XCTAssertNil(MobileSessionRoute(value))
        }
    }

    func testMobileSessionIconUsesCloudForRemoteSSHShellsAndProjects() {
        XCTAssertEqual(MobileSessionIcon.fallbackSystemSymbol(agent: "terminal", remoteHost: nil), "terminal")
        XCTAssertEqual(MobileSessionIcon.fallbackSystemSymbol(agent: "terminal", remoteHost: "  "), "terminal")
        XCTAssertEqual(MobileSessionIcon.fallbackSystemSymbol(agent: "terminal", remoteHost: "cloud"), "cloud")
        XCTAssertEqual(MobileSessionIcon.fallbackSystemSymbol(agent: "unknown-agent", remoteHost: "cloud"), "sparkles")

        XCTAssertFalse(MobileSessionIcon.isRemoteSSHProject(deviceAlias: nil, sessionRemoteHosts: []))
        XCTAssertFalse(MobileSessionIcon.isRemoteSSHProject(deviceAlias: nil, sessionRemoteHosts: ["cloud", nil]))
        XCTAssertTrue(MobileSessionIcon.isRemoteSSHProject(deviceAlias: "cloud", sessionRemoteHosts: []))
        XCTAssertTrue(MobileSessionIcon.isRemoteSSHProject(deviceAlias: nil, sessionRemoteHosts: ["cloud", "devbox"]))
    }

    func testAllNineteenMobileAgentsAndAliasesResolveCanonicalDescriptors() {
        XCTAssertEqual(MobileSessionIcon.allAgents.count, 19)
        for descriptor in MobileSessionIcon.allAgents {
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertTrue(descriptor.vectorIcon != nil || descriptor.assetIcon != nil, "Missing icon for \(descriptor.id)")
            XCTAssertEqual(MobileSessionIcon.agentDescriptor(for: descriptor.id), descriptor)
            XCTAssertEqual(MobileSessionIcon.normalizeAgentID(descriptor.id), descriptor.id)
        }
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("agy"), "antigravity")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("jetski"), "antigravity")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("qodercli"), "qoder")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("oh-my-pi"), "omp")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("aider-chat"), "aider")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("cursor-agent"), "cursor")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("kimi-code"), "kimi")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("qwen-code"), "qwen")
        XCTAssertEqual(MobileSessionIcon.normalizeAgentID("gh-copilot"), "copilot")
    }
}
