import Foundation
import Testing
@testable import Ghostty

struct GitCommitAITests {
    private actor Calls {
        var values: [String] = []
        func record(_ value: String) { values.append(value) }
    }

    @Test func batchAddNormalizesDeduplicatesAndPersistsOrder() {
        let initial = GitCommitAIRoute.adding(agent: .pi, models: [" p/one ", "p/two", "p/one", "", "bad\0id"], to: [])
        #expect(initial.map(\.model) == ["p/one", "p/two"])
        let routes = GitCommitAIRoute.adding(agent: .claude, models: ["sonnet", "opus"], to: initial)
        #expect(GitCommitAIRoute.decode(GitCommitAIRoute.encode(routes)) == routes)
        #expect(GitCommitAIRoute.decode("invalid").isEmpty)
    }

    @Test func duplicateIDsAreRepaired() {
        let id = UUID()
        let routes = [GitCommitAIRoute(id: id, agent: .pi, model: "a/b"), GitCommitAIRoute(id: id, agent: .pi, model: "a/c")]
        #expect(Set(GitCommitAIRoute.decode(GitCommitAIRoute.encode(routes)).map(\.id)).count == 2)
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
        let routes = GitCommitAIRoute.adding(agent: .pi, models: ["first", "second"], to: [])
        let service = GitCommitAIService { route, _ in
            if route.model == "first" { return "  " }
            throw GitCommitAIError("secret diagnostic")
        }
        do {
            _ = try await service.generate(routes: routes, prompt: "patch")
            Issue.record("All attempts must fail")
        } catch { #expect(!error.localizedDescription.contains("secret diagnostic")) }
    }

    @Test func allAgentsUseACPAndDiscoverModels() {
        for agent in GitCommitAgent.allCases {
            #expect(agent.canDiscoverModels)
            #expect(agent.acpCommand.joined(separator: " ").contains("acp"))
        }
        #expect(GitCommitAIService.shellQuote("a'; echo unsafe") == "'a'\\''; echo unsafe'")
    }

    @Test func codexACPManagedExecutableUsesTheAppSupportVersion() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let bin = support.appendingPathComponent("CommitAI/ACP/codex/1.13.1/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("codex-acp")
        try Data("#!/bin/sh\\nexit 0\\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("1.13.1".utf8).write(to: support.appendingPathComponent("CommitAI/ACP/codex/current"))
        #expect(GitACPAdapterManager.activeCodexBinURL(supportURL: support) == bin)
    }

    @Test func codexACPPrunesOlderManagedVersionsAfterUpdate() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appendingPathComponent("CommitAI/ACP/codex", isDirectory: true)
        for name in ["1.12.0", "1.13.1", "metadata"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        GitACPAdapterManager.pruneInactiveCodexVersions(supportURL: support, keeping: "1.13.1")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("1.12.0").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.13.1").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata").path))
    }

    @Test func codexACPVersionChecksUseStableSemverOrdering() {
        #expect(GitACPAdapterManager.isStableVersion("1.13.1"))
        #expect(!GitACPAdapterManager.isStableVersion("1.13.2-preview.5"))
        #expect(!GitACPAdapterManager.isStableVersion("01.13.1"))
        #expect(GitACPAdapterManager.isNewer("1.13.1", than: "1.12.0"))
        #expect(GitACPAdapterManager.isNewer("2.0.0", than: "1.99.99"))
        #expect(!GitACPAdapterManager.isNewer("1.13.1", than: "1.13.1"))
        #expect(!GitACPAdapterManager.isNewer("1.12.9", than: "1.13.0"))
    }

    @Test func acpModelsSupportGroupedAndLegacyCatalogs() {
        let current = GitACPModels(response: ["configOptions": [["id": "model-choice", "category": "model",
            "options": [["group": "vendor", "options": [["value": "model-a"], ["value": "model-b"]]]]]]])
        #expect(current.ids == ["model-a", "model-b"])
        #expect(current.configID == "model-choice")
        let old = GitACPModels(response: ["models": ["availableModels": [["modelId": "p/m"]]]])
        #expect(old.ids == ["p/m"])
        #expect(old.configID == nil)
    }

    @Test func sessionKeysIsolateRepositoryModelAndStyle() throws {
        let route = GitCommitAIRoute(agent: .pi, model: "p/m")
        let local = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let ssh = GitRepositoryIdentity(target: .ssh(try GitSSHConnection(destination: "new-pod", options: [])),
            worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let key = GitACPSessionStore.key(repository: local, route: route, style: "")
        #expect(key != GitACPSessionStore.key(repository: ssh, route: route, style: ""))
        #expect(key != GitACPSessionStore.key(repository: local, route: route, style: "Chinese"))
        #expect(!key.contains("/repo"))
    }

    @Test func sessionRetentionOnlyDeletesOwnedExpiredDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitACPSessionStore(root: root)
        let directory = try store.create()
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try store.prune(now: Date().addingTimeInterval(GitACPSessionStore.retention + 60))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func isolatedSessionEnvironmentKeepsHistoryOutsideRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: original.appendingPathComponent(".pi/agent"), withIntermediateDirectories: true)
        let auth = original.appendingPathComponent(".pi/agent/auth.json")
        try Data("{}".utf8).write(to: auth)
        for agent in GitCommitAgent.allCases {
            let directory = root.appendingPathComponent(agent.rawValue)
            let env = try GitACPEnvironment.prepare(agent: agent, directory: directory, base: ["HOME": original.path])
            #expect(env["HOME"] == directory.appendingPathComponent("home").path)
            #expect(env["XDG_DATA_HOME"]?.hasPrefix(directory.path) == true)
            #expect(env["XDG_STATE_HOME"]?.hasPrefix(directory.path) == true)
        }
        let piAuth = root.appendingPathComponent("pi/home/.pi/agent/auth.json")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: piAuth.path) == auth.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("pi"))
        #expect(FileManager.default.fileExists(atPath: auth.path))
    }

    @Test func customStyleTakesPrecedenceAndKeepsSourceBoundary() {
        let prompt = GitCommitAIService.prompt(patch: Data("+hello".utf8), history: Data("old style".utf8), customPrompt: "中文正文")
        #expect(prompt.contains("中文正文"))
        #expect(prompt.contains("take precedence over recent subjects"))
        #expect(prompt.contains("untrusted source data"))
    }

    @MainActor @Test func settingsRoundTripAndIndependentNavigation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        for agent in GitCommitAgent.allCases {
            settings.gitCommitAIRoutes = GitCommitAIRoute.adding(agent: agent, models: ["model"], to: settings.gitCommitAIRoutes)
        }
        settings.gitCommitAIPrompt = "Use Conventional Commits.\n中文正文。"
        let reloaded = OhMyGhosttySettings(fileURL: url)
        #expect(reloaded.gitCommitAIRoutes == settings.gitCommitAIRoutes)
        #expect(reloaded.gitCommitAIPrompt == settings.gitCommitAIPrompt)
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
        await #expect(throws: (any Error).self) { try await staleService.generate(repository: repository, routes: routes) }
    }
}
