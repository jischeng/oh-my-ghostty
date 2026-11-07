import Foundation
import XCTest
@testable import OMGMobileCore

final class RuntimeAgentStateTests: XCTestCase {
    private func frame(_ records: [[String: String]], revision: UInt64 = 1,
                       pending: [[String: String]]? = nil, position: UInt64 = 12) throws -> RuntimeFrame {
        var snapshot: [String: Any] = ["version": 1, "revision": revision, "records": records]
        if let pending { snapshot["pending"] = pending }
        return RuntimeFrame(71, position, try JSONSerialization.data(withJSONObject: snapshot))
    }

    private func hook(_ agent: String, _ state: String) -> [String: String] {
        ["id": "omg-agent-\(agent)-42",
         "metadata": "type=app;omg_agent=\(agent);omg_state=\(state)"]
    }

    func testFourDailyAgentsUseTheExistingHookStates() throws {
        for (agent, name) in [("codex", "Codex"), ("claude", "Claude Code"),
                              ("pi", "Pi"), ("antigravity", "Antigravity")] {
            for (wire, expected) in [
                ("working", MobileAgentActivity.State.working),
                ("needsAttention", .needsAttention), ("done", .done), ("idle", .idle),
            ] {
                var state = RuntimeAgentState()
                try state.consume(frame([hook(agent, wire)]), at: 12)
                XCTAssertEqual(state.activity?.displayName, name)
                XCTAssertEqual(state.activity?.state, expected)
            }
        }
    }

    func testNativePermissionAndMessageArePresentationOnly() throws {
        var state = RuntimeAgentState()
        let text = Data("Run the test?".utf8).base64EncodedString()
        try state.consume(frame([["id": "omg-program-status",
            "metadata": "state=blocked:app=claude:id=one:kind=permission:msg=\(text):progress=25"]]), at: 12)
        XCTAssertEqual(state.activity?.attention, "permission")
        XCTAssertEqual(state.activity?.message, "Run the test?")
        XCTAssertEqual(state.activity?.progress, 0.25)
        XCTAssertEqual(state.activity?.state, .needsAttention)
    }

    func testCommittedStateSurvivesAnIncompleteReplacementAndEmptySnapshotClearsIt() throws {
        var state = RuntimeAgentState()
        try state.consume(frame([hook("pi", "done")], pending: [hook("codex", "working")]), at: 12)
        XCTAssertEqual(state.activity?.agentID, "pi")
        try state.consume(frame([], revision: 2), at: 12)
        XCTAssertNil(state.activity)
    }

    func testOutOfOrderSnapshotDoesNotReplaceNewerState() throws {
        var state = RuntimeAgentState()
        try state.consume(frame([hook("codex", "working")], revision: 3), at: 12)
        try state.consume(frame([hook("codex", "done")], revision: 2), at: 12)
        XCTAssertEqual(state.activity?.state, .working)
        XCTAssertEqual(state.revision, 3)
    }

    func testWrongWatermarkCannotApplyAnActivitySnapshot() throws {
        var state = RuntimeAgentState()
        XCTAssertThrowsError(try state.consume(frame([hook("pi", "working")]), at: 11))
        XCTAssertThrowsError(try state.consume(frame([hook("pi", "working")]), at: nil))
        XCTAssertNil(state.activity)
    }

    func testAttentionWinsOverBusyAndCompletionWithoutConflatingDoneAndBlocked() throws {
        var state = RuntimeAgentState()
        try state.consume(frame([hook("codex", "needsAttention"), hook("pi", "working"),
                                 hook("claude", "done")]), at: 12)
        XCTAssertEqual(state.activity?.agentID, "codex")
        XCTAssertEqual(state.activity?.state, .needsAttention)
        try state.consume(frame([hook("pi", "done")], revision: 2), at: 12)
        XCTAssertEqual(state.activity?.state, .done)
    }

    func testMalformedAndOversizedSnapshotsCannotBecomeDisplayedState() throws {
        var state = RuntimeAgentState()
        XCTAssertThrowsError(try state.consume(frame(Array(repeating: hook("pi", "idle"), count: 65)), at: 12))
        XCTAssertThrowsError(try state.consume(frame([["id": "omg-agent-pi-42",
            "metadata": "type=app;omg_agent=pi;omg_state=working\u{1b}"]]), at: 12))
        XCTAssertThrowsError(try state.consume(RuntimeFrame(71, 12, Data(repeating: 32, count: 2_097_153)), at: 12))
        XCTAssertNil(state.activity)
    }

    func testLiveNativeUpdatesReplaceAndClearExactlyTheReportedRequest() throws {
        var state = RuntimeAgentState()
        try state.consume(frame([hook("pi", "done")]), at: 12)
        state.consumeContext(ended: false, id: "omg-program-status",
            metadata: "state=working:app=codex:id=parent/child")
        XCTAssertEqual(state.activity?.agentID, "codex")
        state.consumeContext(ended: false, id: "omg-program-status", metadata: "state=clear:id=other")
        XCTAssertEqual(state.activity?.agentID, "codex")
        state.consumeContext(ended: false, id: "omg-program-status", metadata: "state=clear:id=parent")
        XCTAssertEqual(state.activity?.agentID, "pi")
        state.consumeContext(ended: true, id: "omg-agent-pi-42", metadata: "")
        XCTAssertNil(state.activity)
        state.consumeContext(ended: false, id: "omg-program-status",
            metadata: "state=working:app=codex:id=another/child")
        state.consumeContext(ended: true, id: "omg-program-status", metadata: "")
        XCTAssertNil(state.activity)
    }

    func testLiveTransactionAndRemoteExitDoNotLeaveAStaleAttentionCard() {
        var state = RuntimeAgentState()
        state.consumeContext(ended: false, id: "omg-agent-sync", metadata: "begin")
        state.consumeContext(ended: false, id: "omg-agent-pi-42",
            metadata: "type=app;omg_agent=pi;omg_scope=remote;omg_state=needsAttention")
        XCTAssertNil(state.activity)
        state.consumeContext(ended: false, id: "omg-agent-sync", metadata: "end")
        XCTAssertEqual(state.activity?.state, .needsAttention)
        state.consumeContext(ended: false, id: "omg-ssh-inline-current", metadata: "type=remote")
        state.consumeContext(ended: true, id: "omg-ssh-inline-old", metadata: "")
        XCTAssertEqual(state.activity?.state, .needsAttention)
        state.consumeContext(ended: true, id: "omg-ssh-inline-current", metadata: "")
        XCTAssertNil(state.activity)
    }
}
