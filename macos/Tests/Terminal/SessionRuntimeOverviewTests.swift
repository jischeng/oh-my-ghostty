import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SessionRuntimeOverviewTests {
    private func report(error: Bool = false) throws -> SessionRuntimeOverviewReport {
        let failures = error ? #"{"host":"offline","message":"unavailable"}"# : ""
        return try JSONDecoder().decode(SessionRuntimeOverviewReport.self, from: Data("""
        {"sessions":[{"endpoint_id":"fixture","host":"This Mac","revision":"old",
        "id":"11111111-1111-4111-8111-111111111111","generation":"generation",
        "created_at":1,"updated_at":2,"pid":42,"ended":null,"resume":null,"cwd":"/tmp"}],
        "errors":[\(failures)],"closed":0}
        """.utf8))
    }
    @Test func incompleteInventoryDisablesBulkCloseAndCompleteInventoryRefreshesAfterClose() async throws {
        var closes = 0
        var incomplete = true
        let model = SessionRuntimeOverviewModel { close in
            if close { closes += 1 }
            return try report(error: incomplete)
        }
        model.refresh()
        try await waitForAppKit { !model.busy }
        #expect(model.runningCount == 1 && !model.canCloseAll)
        model.closeAll()
        #expect(closes == 0)
        incomplete = false
        model.refresh()
        try await waitForAppKit { !model.busy }
        #expect(model.canCloseAll)
        model.closeAll()
        try await waitForAppKit { !model.busy }
        #expect(closes == 1)
    }
    @Test func cancelledRefreshDoesNotPublishLateInventory() async throws {
        let model = SessionRuntimeOverviewModel { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return try report()
        }
        model.refresh()
        model.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!model.busy && model.report.sessions.isEmpty)
    }

    @Test func backgroundStoreGatesTimerToActiveSubscribersAndResolvesTargetedPIDs() {
        let store = SessionRuntimeBackgroundStore(enabledInTests: true)
        #expect(!store.isPollingTimerRunning)

        let firstObserver = store.beginUIObservation()
        #expect(store.isPollingTimerRunning)
        let secondObserver = store.beginUIObservation()
        #expect(store.isPollingTimerRunning)

        store.endUIObservation(firstObserver)
        #expect(store.isPollingTimerRunning)
        store.endUIObservation(secondObserver)
        #expect(!store.isPollingTimerRunning)

        let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
        let destinations = SessionRuntimeBackgroundStore.activeSSHDestinations(forLeaderPIDs: [currentPID])
        #expect(destinations[currentPID] == nil)
    }

    @Test func localLostSessionsAreAttachableAndClosableInOverviewModel() async throws {
        let decoded = try JSONDecoder().decode(SessionRuntimeOverviewReport.self, from: Data("""
        {"sessions":[
          {"endpoint_id":"local","host":"This Mac","revision":"rev",
           "id":"22222222-2222-4222-8222-222222222222","generation":"gen1",
           "created_at":1,"updated_at":2,"pid":null,"ended":"lost","resume":null,"cwd":"/tmp/project"},
          {"endpoint_id":"remote","host":"cloud","revision":"rev",
           "id":"33333333-3333-4333-8333-333333333333","generation":"gen2",
           "created_at":1,"updated_at":2,"pid":null,"ended":"lost","resume":null,"cwd":"/tmp/remote"}
        ],"errors":[],"closed":0}
        """.utf8))

        #expect(decoded.sessions.count == 2)
        #expect(decoded.sessions[0].isLocalEndpoint)
        #expect(decoded.sessions[0].isAttachable)
        #expect(decoded.sessions[0].isClosable)
        #expect(!decoded.sessions[1].isLocalEndpoint)
        #expect(!decoded.sessions[1].isAttachable)
        #expect(!decoded.sessions[1].isClosable)

        var closeCount = 0
        let model = SessionRuntimeOverviewModel { close in
            if close { closeCount += 1 }
            return decoded
        }
        model.refresh()
        try await waitForAppKit { !model.busy }
        #expect(model.runningCount == 0)
        #expect(model.closableCount == 1)
        #expect(model.canCloseAll)
        model.closeAll()
        try await waitForAppKit { !model.busy }
        #expect(closeCount == 1)
    }

    @Test func openSelectedSynthesizesLocalDescriptorForOlderRevisionAndMobileCreatedLocalSessions() async throws {
        let catalog = SessionRuntimeCatalog(url: nil)
        let newerLocal = SessionRuntimeDescriptor(
            connection: nil,
            revision: "rev-2026-new",
            policy: .init()
        )
        catalog.remember(newerLocal)
        #expect(catalog.endpoints.count == 1)

        let decoded = try JSONDecoder().decode(SessionRuntimeOverviewReport.self, from: Data("""
        {"sessions":[
          {"endpoint_id":"unrecorded-prior-local-sha256","host":"This Mac","revision":"rev-2026-old",
           "id":"44444444-4444-4444-8444-444444444444","generation":"gen-old",
           "created_at":10,"updated_at":20,"pid":null,"ended":"lost","resume":null,"cwd":"/tmp/prior"},
          {"endpoint_id":"unrecorded-mobile-local-sha256","host":"This Mac","revision":"rev-mobile-1",
           "id":"55555555-5555-4555-8555-555555555555","generation":"gen-mobile",
           "created_at":11,"updated_at":21,"pid":777,"ended":null,"resume":null,"cwd":"/tmp/mobile"},
          {"endpoint_id":"unrecorded-remote-sha256","host":"prod-box","revision":"rev-2026-old",
           "id":"66666666-6666-4666-8666-666666666666","generation":"gen-remote",
           "created_at":12,"updated_at":22,"pid":888,"ended":null,"resume":null,"cwd":"/tmp/remote"},
          {"endpoint_id":"invalid-local-rev","host":"This Mac","revision":"../bad-rev",
           "id":"77777777-7777-4777-8777-777777777777","generation":"gen-bad",
           "created_at":13,"updated_at":23,"pid":999,"ended":null,"resume":null,"cwd":"/tmp/bad"}
        ],"errors":[],"closed":0}
        """.utf8))

        let customPolicy = SessionRuntimePolicy(detachedTTLSeconds: 7_200, closeOnAgentDone: true)
        let model = SessionRuntimeOverviewModel { _ in decoded }
        var openedCalls: [(SessionRuntimeCatalogSession, SessionRuntimeDescriptor)] = []
        let controller = OverviewController(
            model: model,
            catalog: catalog,
            policyProvider: { customPolicy },
            openHandler: { session, descriptor in
                openedCalls.append((session, descriptor))
            }
        )
        _ = controller.view
        model.refresh()
        try await waitForAppKit { !model.busy }

        // 1. Prior-revision post-reboot ("lost") local session whose endpointID was evicted by `rev-2026-new`.
        controller.selectRow(0)
        #expect(controller.isOpenButtonEnabled)
        controller.openSelected()
        #expect(openedCalls.count == 1)
        #expect(openedCalls.first?.0.id == "44444444-4444-4444-8444-444444444444")
        #expect(openedCalls.first?.1 == SessionRuntimeDescriptor(
            connection: nil,
            revision: "rev-2026-old",
            policy: customPolicy
        ))

        // 2. Mobile-created local session when `catalog.endpoints` has zero endpoints recorded at all.
        let emptyCatalog = SessionRuntimeCatalog(url: nil)
        #expect(emptyCatalog.endpoints.isEmpty)
        let mobileDescriptor = decoded.sessions[1].resolvedDescriptor(
            in: emptyCatalog.endpoints,
            policy: customPolicy
        )
        #expect(mobileDescriptor == SessionRuntimeDescriptor(
            connection: nil,
            revision: "rev-mobile-1",
            policy: customPolicy
        ))
        controller.selectRow(1)
        #expect(controller.isOpenButtonEnabled)
        controller.openSelected()
        #expect(openedCalls.count == 2)
        #expect(openedCalls.last?.0.id == "55555555-5555-4555-8555-555555555555")
        #expect(openedCalls.last?.1.revision == "rev-mobile-1")
        #expect(openedCalls.last?.1.isLocal == true)

        // 3. Unrecorded remote session is never synthesized as a local descriptor.
        controller.selectRow(2)
        controller.openSelected()
        #expect(openedCalls.count == 2)

        // 4. Malformed revision strings are rejected safely.
        controller.selectRow(3)
        controller.openSelected()
        #expect(openedCalls.count == 2)
    }
}
