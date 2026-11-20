import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct AgentTAPStatusTests {
    @Test func parseValidTAPFieldsStatusesAndAgentAliases() throws {
        let parsed = try #require(AgentTAPStatus.parse(
            "CodeAgent=Claude Code;SessionId=sess_01.a-b;Status=running;TaskProgress=45%;Title=Refactor parser;ProjectFolder=/etc/shadow"
        ))
        #expect(parsed.agent == .claude)
        #expect(parsed.sessionID == "sess_01.a-b")
        #expect(parsed.state == .working)
        #expect(parsed.attention == nil)
        #expect(parsed.taskProgress == "45%")
        #expect(parsed.progress == 0.45)
        #expect(parsed.title == "Refactor parser")

        let awaitingInput = try #require(AgentTAPStatus.parse(
            "CodeAgent=Codex;Status=awaiting-input;TaskProgress=3/4"
        ))
        #expect(awaitingInput.agent == .codex)
        #expect(awaitingInput.state == .needsAttention)
        #expect(awaitingInput.attention == .question)
        #expect(awaitingInput.progress == 0.75)

        let awaitingApproval = try #require(AgentTAPStatus.parse(
            "CodeAgent=agy;Status=awaiting-approval"
        ))
        #expect(awaitingApproval.agent == .antigravity)
        #expect(awaitingApproval.state == .needsAttention)
        #expect(awaitingApproval.attention == .permission)

        let idle = try #require(AgentTAPStatus.parse("CodeAgent=Cursor Agent;Status=idle"))
        #expect(idle.agent == .cursor)
        #expect(idle.state == .idle)

        let error = try #require(AgentTAPStatus.parse("CodeAgent=OpenCode;Status=error"))
        #expect(error.agent == .opencode)
        #expect(error.state == .error)

        let fallback = try #require(AgentTAPStatus.parse("Status=running", fallbackAgent: .claude))
        #expect(fallback.agent == .claude)
        #expect(fallback.state == .working)
    }

    @Test func rejectMalformedOversizedAndUnsafeTAPPayloads() {
        // Oversized (> 4096 bytes)
        let hugeTitle = String(repeating: "a", count: 4100)
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;Title=\(hugeTitle)") == nil)

        // Control characters
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;Title=bad\u{0007}bell") == nil)
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;Title=bad\nline") == nil)

        // Strict SessionId validation: [A-Za-z0-9._-], no leading '-', <= 128 bytes
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;SessionId=-flag") == nil)
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;SessionId=../escape") == nil)
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;SessionId=bad id") == nil)
        let longID = String(repeating: "x", count: 129)
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=running;SessionId=\(longID)") == nil)

        // Unknown status or missing status or unknown explicit agent
        #expect(AgentTAPStatus.parse("CodeAgent=Claude;Status=bogus") == nil)
        #expect(AgentTAPStatus.parse("CodeAgent=Claude") == nil)
        #expect(AgentTAPStatus.parse("CodeAgent=UnknownFutureAgent;Status=running") == nil)
    }

    @Test func sameAgentOSC7501WinsStateAndAttentionWhileTAPEnrichesMetadata() {
        var status = AgentProgramStatus()
        #expect(status.consumeTAP(
            "CodeAgent=Claude;SessionId=conv-42;Status=awaiting-approval;TaskProgress=60%;Title=Review diff;ProjectFolder=/tmp/untrusted"
        ) == true)
        #expect(status.consume("state=working:app=claude") == true)

        let activity = status.activity
        #expect(activity?.source == "claude")
        #expect(activity?.state == .working)
        #expect(activity?.attentionKind == nil)
        #expect(activity?.message == "Review diff")
        #expect(activity?.progress == 0.60)
        #expect(status.activeSessionID == "conv-42")
        #expect(status.activeTaskProgress == "60%")
        #expect(status.activeTAPTitle == "Review diff")

        // When OSC 7501 supplies its own msg, TAP Title enriches detail instead of overwriting msg.
        #expect(status.consume("state=blocked:app=claude:kind=permission:msg=QWx3YXlzIGFsbG93") == true)
        #expect(status.activity?.state == .needsAttention)
        #expect(status.activity?.attentionKind == .permission)
        #expect(status.activity?.message == "Always allow")
        #expect(status.activity?.detail == "Review diff")
        #expect(status.activeSessionID == "conv-42")
    }

    @Test func tapOnlyAgentDrivesTier1AndArbitratesWithTier2Hooks() {
        var status = AgentProgramStatus()
        #expect(status.consumeTAP(
            "CodeAgent=Codex;SessionId=cx-7;Status=running;Title=Running tests;TaskProgress=50%"
        ) == true)
        #expect(status.activity?.source == "codex")
        #expect(status.activity?.state == .working)
        #expect(status.activity?.message == "Running tests")
        #expect(status.activity?.progress == 0.5)
        #expect(status.activeSessionID == "cx-7")

        // Tier 2 Hook `needsAttention` surfaces over generic Tier 1 TAP `working` on same agent.
        let hookAttention = TabActivity(
            source: "codex",
            state: .needsAttention,
            attentionKind: .permission,
            label: "Codex",
            message: "Approve command",
            detail: nil,
            progress: nil,
            icon: nil
        )
        let combined = AgentProgramStatus.preferredActivity(
            program: status.activity,
            fallback: hookAttention
        )
        #expect(combined?.state == .needsAttention)
        #expect(combined?.attentionKind == .permission)

        // TAP `error` acknowledges to `idle`.
        #expect(status.consumeTAP("CodeAgent=Codex;Status=error") == true)
        #expect(status.activity?.state == .error)
        #expect(status.acknowledge() == true)
        #expect(status.activity?.state == .idle)
    }

    @Test func terminalControllerConsumesOSC26AndSnapshotReplay() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)

        // Direct OSC 26 delivery via `omg-osc26` context signal.
        surface.contextSignal = .init(
            action: .start,
            id: "omg-osc26",
            metadata: "CodeAgent=Claude;SessionId=sess-ctrl-1;Status=running;Title=Checking tests;ProjectFolder=/untrusted/cwd"
        )
        #expect(controller.agentActivities[surface.id]?.source == "claude")
        #expect(controller.agentActivities[surface.id]?.state == .working)
        #expect(controller.agentActivities[surface.id]?.message == "Checking tests")

        // Replay over `omg-agent-sync` transaction preserves OSC 26 TAP state.
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "mode=restore")
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        surface.contextSignal = .init(
            action: .start,
            id: "omg-osc26",
            metadata: "CodeAgent=Codex;SessionId=sess-sync-2;Status=awaiting-approval;Title=Run build"
        )
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")

        #expect(controller.agentActivities[surface.id]?.source == "codex")
        #expect(controller.agentActivities[surface.id]?.state == .needsAttention)
        #expect(controller.agentActivities[surface.id]?.attentionKind == .permission)
        #expect(controller.agentActivities[surface.id]?.message == "Run build")
    }
}
