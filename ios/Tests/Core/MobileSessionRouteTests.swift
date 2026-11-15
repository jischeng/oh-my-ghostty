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

    func testAttachableEndedStateAllowsLiveAndPostRebootLostSessionsOnly() throws {
        XCTAssertTrue(MobileSessionRoute.isAttachableEndedState(nil))
        XCTAssertTrue(MobileSessionRoute.isAttachableEndedState("lost"))
        XCTAssertFalse(MobileSessionRoute.isAttachableEndedState("explicit_close"))
        XCTAssertFalse(MobileSessionRoute.isAttachableEndedState("process_exited"))
        XCTAssertFalse(MobileSessionRoute.isAttachableEndedState("detached_timeout"))

        let ep = String(repeating: "a", count: 64)
        let sid = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
        let gen1 = String(repeating: "0", count: 32)
        let gen2 = String(repeating: "f", count: 32)
        let route = try XCTUnwrap(MobileSessionRoute("\(ep)/\(sid)/\(gen1)"))
        XCTAssertEqual(route.replacingGeneration(gen2), "\(ep)/\(sid)/\(gen2)")
    }

    func testRecentTerminalCacheRekeysResurrectedSessionWithoutDuplicateCreation() {
        final class FakeScreen {}
        let ep = String(repeating: "a", count: 64)
        let sid = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
        let otherSid = "88888888-9999-aaaa-bbbb-cccccccccccc"
        let oldRoute = "\(ep)/\(sid)/\(String(repeating: "1", count: 32))"
        let newRoute = "\(ep)/\(sid)/\(String(repeating: "2", count: 32))"
        let otherRoute = "\(ep)/\(otherSid)/\(String(repeating: "3", count: 32))"

        var cache = MobileRecentTerminalCache<FakeScreen>(maxCount: 2)
        let screenA = FakeScreen()
        let screenB = FakeScreen()

        XCTAssertTrue(cache.recordOpen(screenA, forKey: oldRoute).isEmpty)
        XCTAssertTrue(cache.recordOpen(screenB, forKey: otherRoute).isEmpty)
        XCTAssertEqual(cache.keys, [oldRoute, otherRoute])

        // Resurrecting screenA (`oldRoute` -> `newRoute`) re-keys in place and preserves LRU order.
        let migration = cache.adoptResurrectedGeneration(
            from: oldRoute,
            to: newRoute,
            activeScreen: screenA
        )
        XCTAssertTrue(migration.rekeyed === screenA)
        XCTAssertTrue(migration.evicted.isEmpty)
        XCTAssertNil(cache.screen(forKey: oldRoute))
        XCTAssertTrue(cache.screen(forKey: newRoute) === screenA)
        XCTAssertEqual(cache.keys, [newRoute, otherRoute])

        // Returning Home and tapping the resurrected row hits the cached screen (zero duplicate VC!).
        XCTAssertTrue(cache.screen(forKey: newRoute) === screenA)

        // Duplicate collision: if `newRoute` somehow held a stale parked screen, re-keying evicts the stale one.
        let staleDuplicate = FakeScreen()
        var collisionCache = MobileRecentTerminalCache<FakeScreen>(maxCount: 2)
        _ = collisionCache.recordOpen(screenA, forKey: oldRoute)
        _ = collisionCache.recordOpen(staleDuplicate, forKey: newRoute)
        let collision = collisionCache.adoptResurrectedGeneration(
            from: oldRoute,
            to: newRoute,
            activeScreen: screenA
        )
        XCTAssertTrue(collision.rekeyed === screenA)
        XCTAssertEqual(collision.evicted.count, 1)
        XCTAssertTrue(collision.evicted.first === staleDuplicate)
        XCTAssertEqual(collisionCache.keys, [newRoute])

        // Memory-warning eviction keeps only the active screen.
        let memoryEvicted = cache.evictInactive(keeping: screenA)
        XCTAssertEqual(memoryEvicted.count, 1)
        XCTAssertTrue(memoryEvicted.first === screenB)
        XCTAssertEqual(cache.keys, [newRoute])
    }

    func testAttachmentResolutionHandlesResurrectionBeforeJoinNormalReconnectAndEndedSession() throws {
        let ep = String(repeating: "b", count: 64)
        let sid = "11111111-2222-3333-4444-555555555555"
        let oldGen = String(repeating: "a", count: 32)
        let newGen = String(repeating: "c", count: 32)
        let route = try XCTUnwrap(MobileSessionRoute("\(ep)/\(sid)/\(oldGen)"))

        // 1. Once attached (`'S'` applied), subsequent `'L'` pushes are ignored.
        XCTAssertEqual(
            route.resolveAttachment(
                currentGeneration: oldGen,
                isAttached: true,
                inFlightOpenGeneration: nil,
                candidates: [.init(id: sid, generation: newGen, ended: nil)]
            ),
            .alreadyAttached
        )

        // 2. Normal live reconnect: `onOpen` already sent `'U'` for `oldGen` (`inFlightOpenGeneration == oldGen`),
        // so `'L'` keeps the in-flight open instead of sending a duplicate `'U'`.
        XCTAssertEqual(
            route.resolveAttachment(
                currentGeneration: oldGen,
                isAttached: false,
                inFlightOpenGeneration: oldGen,
                candidates: [.init(id: sid, generation: oldGen, ended: nil)]
            ),
            .keepInFlight
        )

        // 3. Reconnect race before `'J'`: `omgd` resurrected `"lost"` session on disk to `newGen`,
        // socket dropped before `'J'` reached iOS -> `'L'` adopts `newGen` and opens cleanly.
        XCTAssertEqual(
            route.resolveAttachment(
                currentGeneration: oldGen,
                isAttached: false,
                inFlightOpenGeneration: nil,
                candidates: [
                    .init(id: "99999999-9999-9999-9999-999999999999", generation: oldGen, ended: nil),
                    .init(id: sid, generation: newGen, ended: nil),
                ]
            ),
            .open(index: 1, adoptedGeneration: newGen)
        )

        // 4. Malformed non-hex generation or non-attachable ended state returns `.notRunning`.
        XCTAssertEqual(
            route.resolveAttachment(
                currentGeneration: oldGen,
                isAttached: false,
                inFlightOpenGeneration: nil,
                candidates: [.init(id: sid, generation: "not-a-valid-hex-generation", ended: nil)]
            ),
            .notRunning
        )
        XCTAssertEqual(
            route.resolveAttachment(
                currentGeneration: oldGen,
                isAttached: false,
                inFlightOpenGeneration: nil,
                candidates: [.init(id: sid, generation: newGen, ended: "process_exited")]
            ),
            .notRunning
        )
    }
}
