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
}
