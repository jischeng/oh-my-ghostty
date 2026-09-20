import Foundation
import Testing
@testable import Ghostty

struct GitCommitAITests {
    private actor Calls {
        var values: [String] = []
        func record(_ value: String) { values.append(value) }
    }

    @Test func batchAddNormalizesDeduplicatesAndPersistsOrder() throws {
        let initial = GitCommitAIRoute.adding(agent: .pi, models: [" p/one ", "p/two", "p/one", "", "bad\0id"], to: [])
        #expect(initial.map(\.model) == ["p/one", "p/two"])
        let routes = GitCommitAIRoute.adding(agent: .claude, models: ["sonnet", "opus"], to: initial)
        #expect(GitCommitAIRoute.decode(GitCommitAIRoute.encode(routes)) == routes)
        #expect(GitCommitAIRoute.decode("invalid").isEmpty)
    }

    @Test func duplicateIDsAreRepaired() {
        let id = UUID()
        let routes = [GitCommitAIRoute(id: id, agent: .pi, model: "a/b"),
                      GitCommitAIRoute(id: id, agent: .pi, model: "a/c")]
        let decoded = GitCommitAIRoute.decode(GitCommitAIRoute.encode(routes))
        #expect(decoded.count == 2)
        #expect(Set(decoded.map(\.id)).count == 2)
    }

    @Test func fallbackIsSequentialAndStopsAtFirstSuccess() async throws {
        let calls = Calls()
        let routes = GitCommitAIRoute.adding(agent: .pi, models: ["first", "second", "third"], to: [])
        let service = GitCommitAIService { route, _ in
            await calls.record(route.model)
            if route.model == "first" { throw GitCommitAIError("failed") }
            return "fix: preserve staged changes"
        }
        let result = try await service.generate(routes: routes, prompt: "patch")
        #expect(result.attempt == 2)
        #expect(result.route.model == "second")
        #expect(await calls.values == ["first", "second"])
    }

    @Test func cancellationNeverFallsBack() async {
        let calls = Calls()
        let routes = GitCommitAIRoute.adding(agent: .pi, models: ["first", "second"], to: [])
        let service = GitCommitAIService { route, _ in
            await calls.record(route.model)
            throw GitExecutionError.cancelled
        }
        do {
            _ = try await service.generate(routes: routes, prompt: "patch")
            Issue.record("Cancellation must propagate")
        } catch { #expect(error is CancellationError) }
        #expect(await calls.values == ["first"])
    }

    @Test func invalidOutputFallsBackAndRawErrorsAreNotExposed() async {
        let calls = Calls()
        let routes = GitCommitAIRoute.adding(agent: .pi, models: ["first", "second"], to: [])
        let service = GitCommitAIService { route, _ in
            await calls.record(route.model)
            if route.model == "first" { return "  " }
            throw GitCommitAIError("secret diagnostic")
        }
        do {
            _ = try await service.generate(routes: routes, prompt: "patch")
            Issue.record("All attempts must fail")
        } catch { #expect(!error.localizedDescription.contains("secret diagnostic")) }
        #expect(await calls.values == ["first", "second"])
    }

    @Test func onlyFinalSuccessfulTextIsAccepted() throws {
        let claude = #"{"type":"result","subtype":"success","is_error":false,"result":"fix: staged change"}"#
        #expect(try GitCommitAIService.parse("startup noise\n" + claude, agent: .claude) == "fix: staged change")
        let pi = #"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"fix: staged change"}]}}"#
        #expect(try GitCommitAIService.parse(pi, agent: .pi) == "fix: staged change")
        #expect(throws: (any Error).self) {
            try GitCommitAIService.parse(pi.replacingOccurrences(of: "\"stop\"", with: "\"error\""), agent: .pi)
        }
        #expect(throws: (any Error).self) {
            try GitCommitAIService.parse(claude.replacingOccurrences(of: "false", with: "true"), agent: .claude)
        }
    }

    @Test func invocationsDisableToolsAndExtensions() {
        let pi = GitCommitAgent.pi.arguments(model: "provider/model")
        #expect(pi.contains("--no-tools"))
        #expect(pi.contains("--no-extensions"))
        #expect(pi.contains("--no-context-files"))
        #expect(pi.contains("--no-approve"))
        let claude = GitCommitAgent.claude.arguments(model: "sonnet")
        #expect(claude.contains("--bare"))
        #expect(claude.contains("--strict-mcp-config"))
        #expect(claude[claude.firstIndex(of: "--tools")! + 1] == "")
        #expect(GitCommitAIService.shellQuote("a'; echo unsafe") == "'a'\\''; echo unsafe'")
    }

    @Test func modelTableParsingIgnoresHeadersAndDiagnostics() {
        let output = """
        provider model context max-out thinking images
        anthropic claude-test 200K 64K yes yes
        openai gpt-test 200K 32K yes no
        No more models.
        """
        #expect(GitCommitAIService.parseModels(output) == ["anthropic/claude-test", "openai/gpt-test"])
    }

    @MainActor @Test func settingsRoundTripAndIndependentNavigation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        settings.gitCommitAIRoutes = GitCommitAIRoute.adding(agent: .pi, models: ["p/first", "p/second"], to: [])
        settings.gitCommitAIRoutes.swapAt(0, 1)
        let reloaded = OhMyGhosttySettings(fileURL: url)
        #expect(reloaded.gitCommitAIRoutes == settings.gitCommitAIRoutes)
        #expect(OhMyGhosttySettingsTab.allCases.contains(.git))
        #expect(OhMyGhosttySettingsTab.allCases.contains(.ssh))
        #expect(OhMyGhosttySettingsTab.allCases.contains(.agents))
        #expect(SettingsStrings(language: .simplifiedChinese).tabTitle(.agents) == "Agent 集成")
    }

    @Test func onlyStagedPatchIsSentAndIndexChangesInvalidateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.path
        let executor = LocalGitExecutor()
        _ = try await executor.execute(arguments: ["init"], workingDirectory: root)
        let file = directory.appendingPathComponent("test.txt")
        try Data("STAGED_CONTENT\n".utf8).write(to: file)
        _ = try await executor.execute(arguments: ["add", "test.txt"], workingDirectory: root)
        try Data("UNSTAGED_PRIVATE_CONTENT\n".utf8).write(to: file)
        let repository = GitRepositoryIdentity(worktreePath: root, gitDirPath: root + "/.git", commonGitDirPath: root + "/.git")
        let routes = GitCommitAIRoute.adding(agent: .pi, models: ["p/model"], to: [])
        let service = GitCommitAIService { _, prompt in
            #expect(prompt.contains("STAGED_CONTENT"))
            #expect(!prompt.contains("UNSTAGED_PRIVATE_CONTENT"))
            return "feat: add test file"
        }
        #expect(try await service.generate(repository: repository, routes: routes).message == "feat: add test file")
        let staleService = GitCommitAIService { _, _ in
            _ = try await executor.execute(arguments: ["add", "test.txt"], workingDirectory: root)
            return "feat: outdated message"
        }
        await #expect(throws: (any Error).self) {
            try await staleService.generate(repository: repository, routes: routes)
        }
    }
}
