import Combine
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentConversationTitleCoordinatorTests {
    typealias Coordinator = AgentConversationTitleCoordinator
    typealias Seed = AgentHistoryStore.TitleSeed

    /// Answers each read of the session store in turn, then keeps giving `rest`.
    private actor Seeds {
        private var scripted: [Seed?]
        private let rest: Seed?
        private(set) var targets: [Coordinator.Target] = []

        init(_ scripted: [Seed?] = [], rest: Seed? = nil) {
            self.scripted = scripted
            self.rest = rest
        }

        func next(_ target: Coordinator.Target) -> Seed? {
            targets.append(target)
            return scripted.isEmpty ? rest : scripted.removeFirst()
        }
    }

    private actor Generator: AITitleGenerating {
        private let result: String?
        private(set) var prompts: [String] = []

        init(_ result: String?) { self.result = result }

        func title(forFirstPrompt prompt: String) async -> String? {
            prompts.append(prompt)
            return result
        }
    }

    private final class Delays: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Duration] = []

        func append(_ delay: Duration) {
            lock.lock()
            recorded.append(delay)
            lock.unlock()
        }

        var all: [Duration] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    @MainActor
    private final class Fixture {
        let store = AgentConversationTitleStore()
        let seeds: Seeds
        let generator: Generator
        let delays = Delays()
        var mode: AgentSessionTitleMode
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        private(set) var coordinator: Coordinator!
        let owner = UUID()
        let target = Coordinator.Target(
            agent: .claude, conversationID: AgentConversationID("0f0e0d0c-1111-4222-8333-444455556666")!,
            remoteHost: nil
        )

        init(seeds: Seeds, generated: String? = nil, mode: AgentSessionTitleMode = .generate,
             sleep: Coordinator.Sleep? = nil) {
            self.seeds = seeds
            self.generator = Generator(generated)
            self.mode = mode
            let delays = self.delays
            coordinator = Coordinator(
                store: store,
                generator: generator,
                loadSeed: { await seeds.next($0) },
                mode: { [unowned self] in self.mode },
                sleep: sleep ?? { delay in
                    delays.append(delay)
                    try Task.checkCancellation()
                },
                now: { [unowned self] in self.now }
            )
        }

        var record: AgentConversationTitleRecord? {
            store.record(agent: target.agent, conversationID: target.conversationID)
        }

        func request(_ trigger: Coordinator.Trigger, owner: UUID? = nil) {
            coordinator.request(target, trigger: trigger, owner: owner ?? self.owner)
        }
    }

    private let prompt = "Fix the flaky login test\nIt fails about once in ten runs on CI."

    @Test func theAgentsOwnTitleWinsAndEndsTheRetries() async {
        let fixture = Fixture(seeds: Seeds([
            nil,
            Seed(native: nil, firstPrompt: prompt),
            Seed(native: "Stabilise login", firstPrompt: prompt),
        ]), generated: "Never used")
        var sources: [AgentConversationTitleSource] = []
        let changes = fixture.store.titleChanges.sink { _ in
            if let source = fixture.record?.source { sources.append(source) }
        }
        defer { changes.cancel() }

        fixture.request(.working)
        #expect(fixture.coordinator.inFlightCount == 1)
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.record?.title == "Stabilise login")
        #expect(fixture.record?.source == .native)
        // The opening prompt stood in until the Agent named the conversation.
        #expect(sources == [.prompt, .native])
        // The transcript did not exist at the first prompt; the read backed off.
        #expect(fixture.delays.all == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(await fixture.seeds.targets.count == 3)
        #expect(await fixture.generator.prompts.isEmpty)
        #expect(fixture.coordinator.inFlightCount == 0)

        // With the Agent's title stored, nothing is read again.
        fixture.request(.working)
        fixture.request(.bound)
        fixture.request(.done)
        #expect(fixture.coordinator.inFlightCount == 0)
        #expect(await fixture.seeds.targets.count == 3)
    }

    @Test func theOpeningPromptIsSummarisedOnceWhenTheAgentNamesNothing() async {
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: nil, firstPrompt: prompt)), generated: "Flaky login test")
        var titles: [String] = []
        let changes = fixture.store.titleChanges.sink { _ in
            if let title = fixture.record?.title { titles.append(title) }
        }
        defer { changes.cancel() }

        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()

        #expect(titles == ["Fix the flaky login test", "Flaky login test"])
        #expect(fixture.record?.source == .generated)
        // The Agent got two further looks to name the conversation first.
        #expect(await fixture.seeds.targets.count == 3)
        // Only the opening prompt is sent, whole rather than cut to a tab's width.
        #expect(await fixture.generator.prompts == [prompt])

        // A generated title is never generated again, on a turn or after a relaunch.
        fixture.request(.working)
        fixture.request(.bound)
        #expect(fixture.coordinator.inFlightCount == 0)
        // The first completed turn looks once more for the Agent's own title.
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 4)
        #expect(await fixture.generator.prompts.count == 1)
        #expect(fixture.record?.title == "Flaky login test")
    }

    @Test func aCompletedTurnUpgradesToTheAgentsTitle() async {
        let fixture = Fixture(seeds: Seeds([Seed(native: "Stabilise login", firstPrompt: prompt)]),
                              generated: "Never used")
        fixture.store.set("Flaky login test", source: .generated, agent: fixture.target.agent,
                          conversationID: fixture.target.conversationID)
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.title == "Stabilise login")
        #expect(fixture.record?.source == .native)
        // The second look does not wait.
        #expect(fixture.delays.all.isEmpty)
        #expect(await fixture.generator.prompts.isEmpty)
    }

    @Test func nativeModeKeepsThePromptAndSettles() async {
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: nil, firstPrompt: prompt)),
                              generated: "Never used", mode: .native)
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.source == .prompt)
        #expect(fixture.record?.title == "Fix the flaky login test")
        #expect(await fixture.generator.prompts.isEmpty)
        #expect(await fixture.seeds.targets.count == 3)

        // A transcript with a prompt and no name is not read again every turn.
        fixture.request(.working)
        #expect(fixture.coordinator.inFlightCount == 0)
        fixture.now = fixture.now.addingTimeInterval(11 * 60)
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 6)

        // Once the user allows it, the next look summarises the prompt.
        fixture.mode = .generate
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts == [prompt])
        #expect(fixture.record?.source == .generated)
    }

    @Test func anUnconfiguredEndpointLeavesThePrompt() async {
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: nil, firstPrompt: prompt)), generated: nil)
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts == [prompt])
        #expect(fixture.record?.source == .prompt)
    }

    @Test func offModeReadsNothing() async {
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: "Stabilise login", firstPrompt: prompt)), mode: .off)
        fixture.request(.bound)
        fixture.request(.working)
        fixture.request(.done)
        #expect(fixture.coordinator.inFlightCount == 0)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.isEmpty)
        #expect(fixture.record == nil)
    }

    @Test func aBoundConversationIsReadOnceAndATurnRetries() async {
        let fixture = Fixture(seeds: Seeds())
        // A restored or resumed tab: its transcript is there or it is not.
        fixture.request(.bound)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 1)
        #expect(fixture.delays.all == [.seconds(1)])
        // A turn that just started can be ahead of its transcript.
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 1 + Coordinator.defaultRetryDelays.count)
        #expect(fixture.record == nil)
        #expect(await fixture.generator.prompts.isEmpty)
    }

    /// With scripted seeds every test above passed while no real tab ever got
    /// a title: the app's loader ignored transcripts older than a few minutes.
    @Test func aRestoredConversationIsTitledFromATranscriptWrittenDaysAgo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-title-coordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        let file = root.appendingPathComponent("-repo/\(id).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"/repo","message":{"role":"user","content":"Fix the flaky login test"}}"#,
            #"{"type":"ai-title","aiTitle":"Stabilise login","sessionId":"\#(id)"}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-9 * 86_400)], ofItemAtPath: file.path
        )
        let store = AgentConversationTitleStore()
        let coordinator = Coordinator(
            store: store,
            generator: Generator(nil),
            // The app's own loader, pointed at this store, with its default window.
            loadSeed: { target in
                await AgentHistoryStore.titleSeed(
                    agent: target.agent, conversationID: target.conversationID,
                    remoteHost: target.remoteHost, rootURLs: [.claude: root]
                )
            },
            mode: { .native },
            sleep: { _ in }
        )
        let conversation = try #require(AgentConversationID(id))
        // A restored tab: bound, idle, read once.
        coordinator.request(.init(agent: .claude, conversationID: conversation, remoteHost: nil),
                            trigger: .bound, owner: UUID())
        await coordinator.waitUntilIdle()
        let record = store.record(agent: .claude, conversationID: conversation)
        #expect(record?.title == "Stabilise login")
        #expect(record?.source == .native)
    }

    @Test func oneReadServesEveryTabAndStopsWithTheLastOne() async {
        // The read never gets past its first wait unless it is cancelled.
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: "Stabilise login", firstPrompt: prompt)),
                              sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        let first = UUID()
        let second = UUID()
        fixture.request(.working, owner: first)
        fixture.request(.working, owner: second)
        fixture.request(.bound, owner: second)
        #expect(fixture.coordinator.inFlightCount == 1)

        fixture.coordinator.release(owner: first)
        #expect(fixture.coordinator.inFlightCount == 1)
        fixture.coordinator.release(owner: UUID())
        #expect(fixture.coordinator.inFlightCount == 1)
        fixture.coordinator.release(owner: second)
        #expect(fixture.coordinator.inFlightCount == 0)

        await fixture.coordinator.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.seeds.targets.isEmpty)
        #expect(fixture.record == nil)
    }

    @Test func aTurnThatEndsDuringTheReadStillGetsItsSecondLook() async {
        let fixture = Fixture(seeds: Seeds([
            Seed(native: nil, firstPrompt: prompt),
            Seed(native: nil, firstPrompt: prompt),
            Seed(native: nil, firstPrompt: prompt),
            Seed(native: "Stabilise login", firstPrompt: prompt),
        ]), mode: .native)
        fixture.request(.working)
        // A short turn finishes before the first read has run.
        fixture.request(.done)
        #expect(fixture.coordinator.inFlightCount == 1)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 4)
        #expect(fixture.record?.title == "Stabilise login")
        #expect(fixture.record?.source == .native)
    }

    @Test func remoteConversationsAreReadFromTheirHost() async {
        let seeds = Seeds(rest: Seed(native: "Deploy fix", firstPrompt: nil))
        let fixture = Fixture(seeds: seeds)
        let remote = Coordinator.Target(
            agent: .codex, conversationID: AgentConversationID("remote-conversation")!, remoteHost: "build-box"
        )
        fixture.coordinator.request(remote, trigger: .bound, owner: fixture.owner)
        fixture.request(.bound)
        #expect(fixture.coordinator.inFlightCount == 2)
        await fixture.coordinator.waitUntilIdle()
        #expect(Set(await seeds.targets.map(\.remoteHost)) == ["build-box", nil])
        let record = fixture.store.record(agent: .codex, conversationID: remote.conversationID)
        #expect(record?.title == "Deploy fix")
        #expect(record?.remoteHost == "build-box")
    }

    @Test func aPaneStateMapsToWhatItAsksFor() {
        #expect(AgentConversationTitleTracker.trigger(for: .working, newlyBound: false) == .working)
        #expect(AgentConversationTitleTracker.trigger(for: .done, newlyBound: false) == .done)
        #expect(AgentConversationTitleTracker.trigger(for: .idle, newlyBound: false) == nil)
        #expect(AgentConversationTitleTracker.trigger(for: .needsAttention, newlyBound: false) == nil)
        #expect(AgentConversationTitleTracker.trigger(for: nil, newlyBound: false) == nil)
        // A conversation a pane just became bound to is looked up whatever the Agent is doing.
        #expect(AgentConversationTitleTracker.trigger(for: nil, newlyBound: true) == .bound)
        #expect(AgentConversationTitleTracker.trigger(for: .idle, newlyBound: true) == .bound)
        #expect(AgentConversationTitleTracker.trigger(for: .working, newlyBound: true) == .working)
        #expect(AgentConversationTitleTracker.trigger(for: .done, newlyBound: true) == .done)
    }
}
