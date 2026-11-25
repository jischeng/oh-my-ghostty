import AppKit
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
        struct Call: Equatable, Sendable {
            let prompt: String
            let nativeTitle: String?
            let projectName: String?
        }

        private let result: String?
        private let gate: (@Sendable () async -> Void)?
        private(set) var prompts: [String] = []
        private(set) var calls: [Call] = []

        init(_ result: String?, gate: (@Sendable () async -> Void)? = nil) {
            self.result = result
            self.gate = gate
        }

        func title(forFirstPrompt prompt: String) async -> String? {
            await title(forFirstPrompt: prompt, nativeTitle: nil, projectName: nil)
        }

        func title(
            forFirstPrompt prompt: String,
            nativeTitle: String?,
            projectName: String?
        ) async -> String? {
            prompts.append(prompt)
            calls.append(.init(prompt: prompt, nativeTitle: nativeTitle, projectName: projectName))
            if let gate {
                await gate()
            }
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
        var alwaysUseAI: Bool
        var language: OhMyGhosttyLanguage
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        private(set) var coordinator: Coordinator!
        let owner = UUID()
        let target = Coordinator.Target(
            agent: .claude, conversationID: AgentConversationID("0f0e0d0c-1111-4222-8333-444455556666")!,
            remoteHost: nil
        )

        init(seeds: Seeds, generated: String? = nil, mode: AgentSessionTitleMode = .generate,
             alwaysUseAI: Bool = false,
             language: OhMyGhosttyLanguage = .english,
             sleep: Coordinator.Sleep? = nil) {
            self.seeds = seeds
            self.generator = Generator(generated)
            self.mode = mode
            self.alwaysUseAI = alwaysUseAI
            self.language = language
            let delays = self.delays
            coordinator = Coordinator(
                store: store,
                generator: generator,
                loadSeed: { await seeds.next($0) },
                mode: { [unowned self] in self.mode },
                alwaysUseAI: { [unowned self] in self.alwaysUseAI },
                language: { [unowned self] in self.language },
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

        func request(
            _ trigger: Coordinator.Trigger,
            owner: UUID? = nil,
            allowsGeneration: Bool = true,
            force: Bool = false,
            manualTabID: UUID? = nil
        ) {
            coordinator.request(
                target,
                trigger: trigger,
                owner: owner ?? self.owner,
                allowsGeneration: allowsGeneration,
                force: force,
                manualTabID: manualTabID
            )
        }
    }

    private let prompt = "Fix the flaky login test\nIt fails about once in ten runs on CI."

    @Test func theAgentsOwnTitleWinsWithoutFlashingPromptAndUpdatesOnLaterRenames() async {
        let fixture = Fixture(seeds: Seeds([
            nil,
            Seed(native: nil, firstPrompt: prompt),
            Seed(native: "Stabilise login", firstPrompt: prompt),
            Seed(native: "Stabilise login", firstPrompt: prompt),
            Seed(native: "Renamed on turn two", firstPrompt: prompt),
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
        // No raw prompt stand-in flashed before the Agent's title arrived.
        #expect(sources == [.native])
        #expect(fixture.delays.all == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(await fixture.seeds.targets.count == 3)
        #expect(await fixture.generator.prompts.isEmpty)
        #expect(fixture.coordinator.inFlightCount == 0)

        // Bound and working turns do not re-scan a natively titled conversation.
        fixture.request(.working)
        fixture.request(.bound)
        #expect(fixture.coordinator.inFlightCount == 0)
        #expect(await fixture.seeds.targets.count == 3)

        // Every completed turn checks once immediately so `/rename` on turn 2+ updates live.
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.title == "Stabilise login")
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.title == "Renamed on turn two")
        #expect(await fixture.seeds.targets.count == 5)
    }

    @Test func theOpeningPromptIsSummarisedOnceWithoutRawPromptFlash() async {
        let fixture = Fixture(
            seeds: Seeds([
                Seed(native: nil, firstPrompt: prompt),
                Seed(native: nil, firstPrompt: prompt),
                Seed(native: nil, firstPrompt: prompt),
                Seed(native: nil, firstPrompt: prompt),
                Seed(native: "Custom /rename title", firstPrompt: prompt),
            ], rest: Seed(native: "Custom /rename title", firstPrompt: prompt)),
            generated: "Flaky login test"
        )
        var titles: [String] = []
        let changes = fixture.store.titleChanges.sink { _ in
            if let title = fixture.record?.title { titles.append(title) }
        }
        defer { changes.cancel() }

        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()

        #expect(titles == ["Flaky login test"])
        #expect(fixture.record?.source == .generated)
        #expect(await fixture.seeds.targets.count == 3)
        #expect(await fixture.generator.prompts == [prompt])

        // A generated title is never regenerated on subsequent turns.
        fixture.request(.working)
        fixture.request(.bound)
        #expect(fixture.coordinator.inFlightCount == 0)
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts.count == 1)
        #expect(fixture.record?.title == "Flaky login test")

        // A later turn where the user ran `/rename` still upgrades to `.native`.
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts.count == 1)
        #expect(fixture.record?.title == "Custom /rename title")
        #expect(fixture.record?.source == .native)
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
        #expect(fixture.delays.all.isEmpty)
        #expect(await fixture.generator.prompts.isEmpty)
    }

    @Test func nativeModeSanitisesThePromptFallbackAndUpgradesWhenGenerateEnabled() async {
        let decoratedPrompt = "Title: **Fix the flaky login test across CI runners**\nSecond line."
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: nil, firstPrompt: decoratedPrompt)),
                              generated: "Login flake", mode: .native)
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.source == .prompt)
        #expect(fixture.record?.title == AITitleSanitizer.sanitize(decoratedPrompt))
        #expect(await fixture.generator.prompts.isEmpty)
        #expect(await fixture.seeds.targets.count == 3)

        // A transcript with a prompt and no name is not read again every turn.
        fixture.request(.working)
        #expect(fixture.coordinator.inFlightCount == 0)
        fixture.now = fixture.now.addingTimeInterval(11 * 60)
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 4)

        // Once the user enables generation, even a `.bound` check upgrades `.prompt` -> `.generated`.
        fixture.mode = .generate
        fixture.request(.bound)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts == [decoratedPrompt])
        #expect(fixture.record?.source == .generated)
        #expect(fixture.record?.title == "Login flake")
    }

    @Test func manualOverrideSkipsLLMGenerationUntilCleared() async {
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: nil, firstPrompt: prompt)),
                              generated: "Flaky login test", mode: .generate)
        fixture.request(.working, allowsGeneration: false)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts.isEmpty)
        #expect(fixture.record?.source == .prompt)
        #expect(fixture.record?.title == AITitleSanitizer.sanitize(prompt))

        // Clearing `titleOverride` re-requests with `allowsGeneration: true` and summarises once.
        fixture.request(.bound, allowsGeneration: true)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts == [prompt])
        #expect(fixture.record?.source == .generated)
        #expect(fixture.record?.title == "Flaky login test")
    }

    @Test func anUnconfiguredEndpointFallsBackToSanitisedPrompt() async {
        let fixture = Fixture(seeds: Seeds(rest: Seed(native: nil, firstPrompt: prompt)), generated: nil)
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts == [prompt])
        #expect(fixture.record?.source == .prompt)
        #expect(fixture.record?.title == AITitleSanitizer.sanitize(prompt))
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
        fixture.request(.bound)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 1)
        #expect(fixture.delays.all == [.seconds(1)])
        fixture.request(.working)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.seeds.targets.count == 1 + Coordinator.defaultRetryDelays.count)
        #expect(fixture.record == nil)
        #expect(await fixture.generator.prompts.isEmpty)
    }

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
        coordinator.request(.init(agent: .claude, conversationID: conversation, remoteHost: nil),
                            trigger: .bound, owner: UUID())
        await coordinator.waitUntilIdle()
        let record = store.record(agent: .claude, conversationID: conversation)
        #expect(record?.title == "Stabilise login")
        #expect(record?.source == .native)
    }

    @Test func oneReadServesEveryTabAndStopsWithTheLastOne() async {
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
        #expect(AgentConversationTitleTracker.trigger(for: nil, newlyBound: true) == .bound)
        #expect(AgentConversationTitleTracker.trigger(for: .idle, newlyBound: true) == .bound)
        #expect(AgentConversationTitleTracker.trigger(for: .working, newlyBound: true) == .working)
        #expect(AgentConversationTitleTracker.trigger(for: .done, newlyBound: true) == .done)
    }

    @Test func chineseGenerateModeUpgradesEnglishOnlyNativeTitleAndKeepsChineseNative() async {
        // English-only native title with firstPrompt -> invokes generator using firstPrompt.
        let withPrompt = Fixture(
            seeds: Seeds(rest: Seed(native: "Ray Gateway V2 Migration", firstPrompt: "Migrate Ray gateway to V2")),
            generated: "Ray 网关 V2 迁移",
            mode: .generate,
            language: .simplifiedChinese
        )
        withPrompt.request(.working)
        await withPrompt.coordinator.waitUntilIdle()
        #expect(await withPrompt.generator.prompts == ["Migrate Ray gateway to V2"])
        #expect(withPrompt.record?.source == .generated)
        #expect(withPrompt.record?.title == "Ray 网关 V2 迁移")

        // Subsequent completed turns keep the Chinese generated title without re-calling the endpoint.
        withPrompt.request(.done)
        await withPrompt.coordinator.waitUntilIdle()
        #expect(await withPrompt.generator.prompts.count == 1)
        #expect(withPrompt.record?.source == .generated)
        #expect(withPrompt.record?.title == "Ray 网关 V2 迁移")

        // English-only native title without firstPrompt -> invokes generator using native title itself.
        let nativeOnly = Fixture(
            seeds: Seeds(rest: Seed(native: "Ray Gateway V2 Migration", firstPrompt: nil)),
            generated: "Ray 网关迁移",
            mode: .generate,
            language: .simplifiedChinese
        )
        nativeOnly.request(.bound)
        await nativeOnly.coordinator.waitUntilIdle()
        #expect(await nativeOnly.generator.prompts == ["Ray Gateway V2 Migration"])
        #expect(nativeOnly.record?.source == .generated)
        #expect(nativeOnly.record?.title == "Ray 网关迁移")

        // Already-Chinese native title is preserved untouched without calling the generator.
        let chineseNative = Fixture(
            seeds: Seeds(rest: Seed(native: "修复网关健康检查", firstPrompt: "Fix health check")),
            generated: "不应被调用",
            mode: .generate,
            language: .simplifiedChinese
        )
        chineseNative.request(.working)
        await chineseNative.coordinator.waitUntilIdle()
        #expect(await chineseNative.generator.prompts.isEmpty)
        #expect(chineseNative.record?.source == .native)
        #expect(chineseNative.record?.title == "修复网关健康检查")

        // An existing cached English-only native record upgrades on `.bound` when Chinese + generate is active.
        let cachedUpgrade = Fixture(
            seeds: Seeds(rest: Seed(native: "Checking Group Chat Message", firstPrompt: nil)),
            generated: "排查群聊消息",
            mode: .generate,
            language: .simplifiedChinese
        )
        cachedUpgrade.store.set(
            "Checking Group Chat Message",
            source: .native,
            agent: cachedUpgrade.target.agent,
            conversationID: cachedUpgrade.target.conversationID
        )
        cachedUpgrade.request(.bound)
        await cachedUpgrade.coordinator.waitUntilIdle()
        #expect(await cachedUpgrade.generator.prompts == ["Checking Group Chat Message"])
        #expect(cachedUpgrade.record?.source == .generated)
        #expect(cachedUpgrade.record?.title == "排查群聊消息")
    }

    @Test func autoRenameTabAndWorkspaceTabsRespectManualOverridesAndForceRegeneration() async throws {
        let workspaceFixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { workspaceFixture.close() }

        let manualTab = try workspaceFixture.tab()
        let eligibleTab = try workspaceFixture.tab()
        let plainTab = try workspaceFixture.tab()

        let manualSurface = try #require(manualTab.surfaceTree.first)
        let eligibleSurface = try #require(eligibleTab.surfaceTree.first)
        let manualConversation = try #require(AgentConversationID("11111111-2222-4333-8444-555555555555"))
        let eligibleConversation = try #require(AgentConversationID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))

        manualTab.adoptAgentResumeDescriptor(
            .init(agent: .codex, conversationID: manualConversation, scope: .local, workingDirectory: "/repo"),
            for: manualSurface
        )
        eligibleTab.adoptAgentResumeDescriptor(
            .init(agent: .codex, conversationID: eligibleConversation, scope: .local, workingDirectory: "/repo"),
            for: eligibleSurface
        )

        let store = AgentConversationTitleStore()
        // Pre-populate eligible tab with an existing Chinese `.generated` title so
        // normal background evaluation skips it and only a forced rename updates it.
        store.set("旧中文标题", source: .generated, agent: .codex, conversationID: eligibleConversation)
        store.set("Manual Tab Cached", source: .native, agent: .codex, conversationID: manualConversation)

        let seeds = Seeds(rest: Seed(native: "Ray Gateway V2 Migration", firstPrompt: "Migrate Ray gateway"))
        let generator = Generator("Ray 网关 V2 迁移")
        let coordinator = Coordinator(
            store: store,
            generator: generator,
            loadSeed: { await seeds.next($0) },
            mode: { .generate },
            language: { .simplifiedChinese },
            sleep: { _ in }
        )

        manualTab.titleOverride = "Pinned Tab"
        manualTab.startAgentConversationTitleTracking(coordinator: coordinator)
        eligibleTab.startAgentConversationTitleTracking(coordinator: coordinator)
        plainTab.startAgentConversationTitleTracking(coordinator: coordinator)
        await coordinator.waitUntilIdle()

        // Batch workspace rename skips tabs with explicit manual `titleOverride` and renames eligible Agent tabs.
        TerminalController.autoRenameWorkspaceTabs([manualTab, eligibleTab, plainTab])
        await coordinator.waitUntilIdle()

        #expect(manualTab.titleOverride == "Pinned Tab")
        #expect(store.title(agent: .codex, conversationID: manualConversation) == "Manual Tab Cached")
        #expect(store.title(agent: .codex, conversationID: eligibleConversation) == "Ray 网关 V2 迁移")
        #expect(store.record(agent: .codex, conversationID: eligibleConversation)?.source == .generated)

        // Direct single-tab forced rename clears `titleOverride` and forces regeneration.
        manualTab.autoRenameTab(force: true)
        await coordinator.waitUntilIdle()

        #expect(manualTab.titleOverride == nil)
        #expect(store.title(agent: .codex, conversationID: manualConversation) == "Ray 网关 V2 迁移")
        #expect(store.record(agent: .codex, conversationID: manualConversation)?.source == .generated)
    }

    @Test func alwaysUseAIShortensLongNativeTitlesAndRespectsManualOverride() async {
        let longChineseNative = "请帮我把整个项目里的所有定时任务都重构一下并且补充完整的单元测试和文档说明"
        let firstPrompt = "重构定时任务并补充单元测试"

        // Default (`alwaysUseAI == false`) keeps a Chinese native title without calling AI.
        let defaultFixture = Fixture(
            seeds: Seeds(rest: Seed(native: longChineseNative, firstPrompt: firstPrompt)),
            generated: "重构定时任务",
            mode: .generate,
            alwaysUseAI: false,
            language: .simplifiedChinese
        )
        defaultFixture.coordinator.request(defaultFixture.target, trigger: .bound, owner: defaultFixture.owner)
        await defaultFixture.coordinator.waitUntilIdle()
        #expect(defaultFixture.store.title(agent: .claude, conversationID: defaultFixture.target.conversationID)
            == longChineseNative)
        #expect(defaultFixture.store.record(agent: .claude, conversationID: defaultFixture.target.conversationID)?.source
            == .native)
        #expect(await defaultFixture.generator.prompts.isEmpty)

        // When `alwaysUseAI` is enabled, even a Chinese native title is shortened via AI (preferring `firstPrompt`)
        // and replaces `.native` with `.generated`.
        defaultFixture.alwaysUseAI = true
        defaultFixture.coordinator.request(defaultFixture.target, trigger: .bound, owner: defaultFixture.owner)
        await defaultFixture.coordinator.waitUntilIdle()
        #expect(defaultFixture.store.title(agent: .claude, conversationID: defaultFixture.target.conversationID)
            == "重构定时任务")
        #expect(defaultFixture.store.record(agent: .claude, conversationID: defaultFixture.target.conversationID)?.source
            == .generated)
        #expect(await defaultFixture.generator.prompts == [firstPrompt])

        // A subsequent `.done` turn keeps the `.generated` title without regenerating or reverting to `.native`.
        defaultFixture.coordinator.request(defaultFixture.target, trigger: .done, owner: defaultFixture.owner)
        await defaultFixture.coordinator.waitUntilIdle()
        #expect(defaultFixture.store.title(agent: .claude, conversationID: defaultFixture.target.conversationID)
            == "重构定时任务")
        #expect(defaultFixture.store.record(agent: .claude, conversationID: defaultFixture.target.conversationID)?.source
            == .generated)
        #expect(await defaultFixture.generator.prompts == [firstPrompt])

        // Without `firstPrompt`, `alwaysUseAI` falls back to passing `native` to the AI generator.
        let nativeOnlyFixture = Fixture(
            seeds: Seeds(rest: Seed(native: longChineseNative, firstPrompt: nil)),
            generated: "定时任务重构",
            mode: .generate,
            alwaysUseAI: true,
            language: .english
        )
        nativeOnlyFixture.coordinator.request(nativeOnlyFixture.target, trigger: .bound, owner: nativeOnlyFixture.owner)
        await nativeOnlyFixture.coordinator.waitUntilIdle()
        #expect(nativeOnlyFixture.store.title(agent: .claude, conversationID: nativeOnlyFixture.target.conversationID)
            == "定时任务重构")
        #expect(await nativeOnlyFixture.generator.prompts == [longChineseNative])

        // Manual override (`allowsGeneration: false`) still skips AI generation even when `alwaysUseAI` is enabled.
        let manualFixture = Fixture(
            seeds: Seeds(rest: Seed(native: longChineseNative, firstPrompt: firstPrompt)),
            generated: "不应被调用",
            mode: .generate,
            alwaysUseAI: true,
            language: .simplifiedChinese
        )
        manualFixture.coordinator.request(
            manualFixture.target,
            trigger: .bound,
            owner: manualFixture.owner,
            allowsGeneration: false
        )
        await manualFixture.coordinator.waitUntilIdle()
        #expect(await manualFixture.generator.prompts.isEmpty)
        #expect(manualFixture.store.record(agent: .claude, conversationID: manualFixture.target.conversationID)?.source
            == .native)

        // Direct store rule: `.generated` replaces `.native` only when `allowGeneratedOverNative` is true.
        let store = AgentConversationTitleStore()
        #expect(store.set(longChineseNative, source: .native, agent: .claude, conversationID: defaultFixture.target.conversationID))
        #expect(!store.set("定时任务重构", source: .generated, agent: .claude, conversationID: defaultFixture.target.conversationID))
        #expect(store.set(
            "定时任务重构",
            source: .generated,
            agent: .claude,
            conversationID: defaultFixture.target.conversationID,
            allowGeneratedOverNative: true
        ))
        #expect(store.title(agent: .claude, conversationID: defaultFixture.target.conversationID) == "定时任务重构")
        #expect(store.record(agent: .claude, conversationID: defaultFixture.target.conversationID)?.source == .generated)
    }

    @Test func inFlightGenerationCoalescesDuplicateTriggersAndPublishesRenamingState() async throws {
        actor Gate {
            private var continuations: [CheckedContinuation<Void, Never>] = []
            private(set) var enteredCount = 0

            func wait() async {
                enteredCount += 1
                await withCheckedContinuation { continuations.append($0) }
            }

            func releaseAll() {
                let pending = continuations
                continuations.removeAll()
                for continuation in pending { continuation.resume() }
            }
        }

        let workspaceFixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { workspaceFixture.close() }
        let tab = try workspaceFixture.tab()
        let surface = try #require(tab.surfaceTree.first)
        let conversation = try #require(AgentConversationID("77777777-8888-4999-8aaa-bbbbbbbbbbbb"))
        tab.adoptAgentResumeDescriptor(
            .init(
                agent: .claude,
                conversationID: conversation,
                scope: .local,
                workingDirectory: "/Users/dev/code/omg-workspace"
            ),
            for: surface
        )

        let gate = Gate()
        let store = AgentConversationTitleStore()
        let seeds = Seeds(rest: Seed(
            native: "Please help me investigate why inbox title rename truncates with dots",
            firstPrompt: "排查收件箱标题自动重命名出现省略号的原因"
        ))
        let generator = Generator("收件箱标题防截断") {
            await gate.wait()
        }
        let coordinator = Coordinator(
            store: store,
            generator: generator,
            loadSeed: { await seeds.next($0) },
            mode: { .generate },
            alwaysUseAI: { true },
            language: { .simplifiedChinese },
            sleep: { _ in }
        )

        tab.startAgentConversationTitleTracking(coordinator: coordinator)
        for _ in 0..<50 where await gate.enteredCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.enteredCount == 1)

        let key = AgentConversationTitleStore.Key(agent: .claude, conversationID: conversation)
        #expect(coordinator.generatingTargets == [key])
        #expect(coordinator.manualRenamingTabIDs.isEmpty)
        #expect(tab.isGeneratingTabTitle)
        #expect(!tab.isManualRenamingTab)

        // While automatic generation is ALREADY in flight, triggering manual `autoRenameTab` and
        // `autoRenameWorkspaceTabs` coalesces into the existing flight instead of spawning duplicate LLM calls!
        tab.autoRenameTab(force: true)
        TerminalController.autoRenameWorkspaceTabs([tab])
        coordinator.request(
            .init(agent: .claude, conversationID: conversation, remoteHost: nil),
            trigger: .working,
            owner: UUID()
        )
        #expect(coordinator.inFlightCount == 1)
        #expect(coordinator.generatingTargets == [key])
        #expect(coordinator.manualRenamingTabIDs == [tab.tabSessionID])
        #expect(tab.isGeneratingTabTitle)
        #expect(tab.isManualRenamingTab)

        await gate.releaseAll()
        await coordinator.waitUntilIdle()

        #expect(coordinator.generatingTargets.isEmpty)
        #expect(coordinator.manualRenamingTabIDs.isEmpty)
        #expect(!tab.isGeneratingTabTitle)
        #expect(!tab.isManualRenamingTab)
        let recordedCalls = await generator.calls
        #expect(recordedCalls == [
            .init(
                prompt: "排查收件箱标题自动重命名出现省略号的原因",
                nativeTitle: "Please help me investigate why inbox title rename truncates with dots",
                projectName: "omg-workspace"
            ),
        ])
        #expect(store.title(agent: .claude, conversationID: conversation) == "收件箱标题防截断")
        #expect(store.record(agent: .claude, conversationID: conversation)?.source == .generated)
    }

    @Test func forcedGeneratedTitleSurvivesSubsequentDoneTurnsUntilGenuineCLIRename() async {
        let rawLongAITitle = "请帮我把整个项目里的所有定时任务都重构一下并且补充完整的单元测试"
        let seeds = Seeds([
            Seed(native: rawLongAITitle, firstPrompt: "重构定时任务"),
            Seed(native: rawLongAITitle, firstPrompt: "重构定时任务"),
            Seed(native: "手动 /rename 后的新标题", firstPrompt: "重构定时任务"),
        ], rest: Seed(native: "手动 /rename 后的新标题", firstPrompt: "重构定时任务"))

        // Even with `alwaysUseAI == false`, a manual forced rename (`force: true`) records the
        // superseded native title so later `.done` turns neither re-invoke AI nor revert to `rawLongAITitle`.
        let fixture = Fixture(
            seeds: seeds,
            generated: "重构定时任务",
            mode: .generate,
            alwaysUseAI: false,
            language: .simplifiedChinese
        )
        fixture.request(.done, force: true, manualTabID: UUID())
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.title == "重构定时任务")
        #expect(fixture.record?.source == .generated)
        #expect(await fixture.generator.prompts.count == 1)

        fixture.request(.working)
        #expect(fixture.coordinator.inFlightCount == 0)

        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.title == "重构定时任务")
        #expect(fixture.record?.source == .generated)
        #expect(await fixture.generator.prompts.count == 1)

        // When the user later runs `/rename` in the CLI (`native` changes), `.done` upgrades to `.native`.
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.record?.title == "手动 /rename 后的新标题")
        #expect(fixture.record?.source == .native)
        #expect(await fixture.generator.prompts.count == 1)

        // ASCII-only `.generated` title in Chinese mode (e.g. "OAuth2 PKCE") also never loops on `.done`.
        let asciiChinese = Fixture(
            seeds: Seeds(rest: Seed(native: "Implement OAuth2 PKCE flow", firstPrompt: "Implement OAuth2 PKCE")),
            generated: "OAuth2 PKCE",
            mode: .generate,
            alwaysUseAI: false,
            language: .simplifiedChinese
        )
        asciiChinese.request(.working)
        await asciiChinese.coordinator.waitUntilIdle()
        #expect(asciiChinese.record?.title == "OAuth2 PKCE")
        #expect(await asciiChinese.generator.prompts.count == 1)

        asciiChinese.request(.done)
        await asciiChinese.coordinator.waitUntilIdle()
        #expect(asciiChinese.record?.title == "OAuth2 PKCE")
        #expect(await asciiChinese.generator.prompts.count == 1)
    }

    @Test func plainNonAgentTabPreservesManualTitleOverrideAndDisablesAutoRenameMenuItem() throws {
        let savedMode = OhMyGhosttySettings.shared.agentSessionTitleMode
        OhMyGhosttySettings.shared.agentSessionTitleMode = .generate
        defer { OhMyGhosttySettings.shared.agentSessionTitleMode = savedMode }

        let workspaceFixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { workspaceFixture.close() }
        let plainTab = try workspaceFixture.tab()
        let agentTab = try workspaceFixture.tab()
        let agentSurface = try #require(agentTab.surfaceTree.first)
        let conversation = try #require(AgentConversationID("abababab-cdcd-4efe-8123-456789abcdef"))
        agentTab.adoptAgentResumeDescriptor(
            .init(agent: .claude, conversationID: conversation, scope: .local, workingDirectory: "/repo"),
            for: agentSurface
        )

        #expect(!plainTab.canAutoRenameTab)
        #expect(agentTab.canAutoRenameTab)

        plainTab.titleOverride = "My Dev Shell"
        plainTab.autoRenameTab(force: true)
        #expect(plainTab.titleOverride == "My Dev Shell")

        let strings = ChromeStrings.current
        let plainMenu = NativeTabContextMenu.make(for: plainTab, host: plainTab)
        let plainItem = try #require(plainMenu.items.first { $0.title == strings.autoRenameTab })
        #expect(!plainItem.isEnabled)

        let agentMenu = NativeTabContextMenu.make(for: agentTab, host: agentTab)
        let agentItem = try #require(agentMenu.items.first { $0.title == strings.autoRenameTab })
        #expect(agentItem.isEnabled)
    }

    @Test func promptFallbackRedactsSecretsAndFailedForcedRenameNeverClobbersGeneratedTitle() async {
        let secretPrompt = "Fix deploy auth with api_key=sk-1234567890abcdefghijklmnop"
        let unconfigured = Fixture(
            seeds: Seeds(rest: Seed(native: nil, firstPrompt: secretPrompt)),
            generated: nil,
            mode: .generate
        )
        unconfigured.request(.working)
        await unconfigured.coordinator.waitUntilIdle()
        let storedFallback = unconfigured.record?.title ?? ""
        #expect(unconfigured.record?.source == .prompt)
        #expect(!storedFallback.contains("sk-1234567890"))

        // An existing `.generated` title survives a failed forced rename (`generated: nil`)
        // and is never fed back into the generator when `seed == nil` (offline SSH host).
        let offline = Fixture(
            seeds: Seeds([
                Seed(native: "Verbose native sentence that was already shortened", firstPrompt: secretPrompt),
                nil,
            ], rest: nil),
            generated: nil,
            mode: .generate
        )
        offline.store.set(
            "精简短标题",
            source: .generated,
            agent: offline.target.agent,
            conversationID: offline.target.conversationID,
            force: true,
            supersededNativeTitle: "Verbose native sentence that was already shortened"
        )
        offline.request(.done, force: true, manualTabID: UUID())
        await offline.coordinator.waitUntilIdle()
        #expect(offline.record?.title == "精简短标题")
        #expect(offline.record?.source == .generated)
        #expect(await offline.generator.prompts.count == 1)

        // Second forced rename with `seed == nil` does not send `"精简短标题"` back to the LLM.
        offline.request(.done, force: true, manualTabID: UUID())
        await offline.coordinator.waitUntilIdle()
        #expect(await offline.generator.prompts.count == 1)
        #expect(offline.record?.title == "精简短标题")
    }

    @Test func explicitUserCLIRenameSurvivesAlwaysUseAIAndLanguageSwitchInvalidatesSettledState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-cli-rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-9999-4888-8777-666655554444"
        let file = root.appendingPathComponent("-repo/\(id).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"/repo","message":{"role":"user","content":"Refactor auth"}}"#,
            #"{"type":"ai-title","aiTitle":"Auto title","sessionId":"\#(id)"}"#,
            #"{"type":"custom-title","customTitle":"My Explicit CLI Name","sessionId":"\#(id)"}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let conversation = try #require(AgentConversationID(id))
        let seed = try #require(await AgentHistoryStore.titleSeed(
            agent: .claude,
            conversationID: conversation,
            rootURLs: [.claude: root]
        ))
        #expect(seed.native == "My Explicit CLI Name")
        #expect(seed.isUserRenamed)

        let fixture = Fixture(
            seeds: Seeds(rest: seed),
            generated: "不应覆盖手动重命名",
            mode: .generate,
            alwaysUseAI: true,
            language: .simplifiedChinese
        )
        fixture.store.set(
            "旧生成标题",
            source: .generated,
            agent: fixture.target.agent,
            conversationID: fixture.target.conversationID,
            force: true
        )
        fixture.request(.done)
        await fixture.coordinator.waitUntilIdle()
        #expect(await fixture.generator.prompts.isEmpty)
        #expect(fixture.record?.title == "My Explicit CLI Name")
        #expect(fixture.record?.source == .native)

        // Language switch invalidates `settledAt` so an English generated title can localize to Chinese.
        let langFixture = Fixture(
            seeds: Seeds(rest: Seed(native: "Investigate flaky CI", firstPrompt: "Investigate flaky CI")),
            generated: "排查 CI 偶现失败",
            mode: .generate,
            alwaysUseAI: false,
            language: .english
        )
        langFixture.store.set(
            "Flaky CI check",
            source: .generated,
            agent: langFixture.target.agent,
            conversationID: langFixture.target.conversationID,
            force: true
        )
        langFixture.language = .simplifiedChinese
        langFixture.coordinator.invalidateSettledState()
        langFixture.request(.done)
        await langFixture.coordinator.waitUntilIdle()
        #expect(langFixture.record?.title == "排查 CI 偶现失败")
    }
}
