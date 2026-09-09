import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
private final class GitSSHTestServer {
    let root: URL
    let process: Process
    let connection: GitSSHConnection

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-ssh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root
        self.process = Process()
        for key in ["host_key", "client_key"] {
            let result = try await LocalGitExecutor(gitPath: "/usr/bin/ssh-keygen").execute(
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent(key).path],
                workingDirectory: root.path)
            try #require(result.isSuccess)
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GitExecutionError.executionFailed("Cannot allocate test port.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        Darwin.close(fd)
        try #require(bound == 0 && named == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let hostPublicKey = try String(contentsOf: root.appendingPathComponent("host_key.pub"), encoding: .utf8)
        try ("[127.0.0.1]:\(port) " + hostPublicKey).write(to: root.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.path)/host_key
        PidFile \(root.path)/pid
        AuthorizedKeysFile \(root.path)/client_key.pub
        AllowUsers \(NSUserName())
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        LogLevel ERROR
        """
        let configURL = root.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        connection = try GitSSHConnection(destination: NSUserName() + "@127.0.0.1",
            options: ["-F", "/dev/null", "-p", String(port), "-i", root.appendingPathComponent("client_key").path,
                      "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=" + root.appendingPathComponent("known_hosts").path,
                      "-o", "StrictHostKeyChecking=yes"], workspaceID: "ssh:test-remote")
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", configURL.path, "-E", root.appendingPathComponent("sshd.log").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            var ready = false
            for _ in 0..<30 {
                if let result = try? await SSHGitExecutor(connection: connection).execute(
                    arguments: ["--version"], workingDirectory: "/", stdin: nil, maxOutputBytes: 4096), result.isSuccess {
                    ready = true; break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(ready, "Isolated loopback OpenSSH server must accept its pinned test key")
        } catch {
            process.terminate()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }

    func session(directory: String) -> PaneSessionContext {
        var session = PaneSessionContext(workingDirectory: "/local", terminalTitle: "Test")
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
                                         terminfo: false, cache: false, args: connection.options + [connection.destination])
        let hex = directory.utf8.map { String(format: "%02x", $0) }.joined()
        session.apply(.init(action: .start, id: "omg-ssh-test", metadata: "type=remote;targethost=test-remote;cwdhex=" + hex),
                      currentWorkingDirectory: "/local", currentTerminalTitle: "Test", sshReplay: replay)
        return session
    }
}

@MainActor
struct SSHGitExecutorTests {
    @Test func connectionPreservesRoutingOptionsWithoutRepeatingInteractiveSideEffects() throws {
        let ssh = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil,
            replay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false,
                          args: ["-tt", "-A", "-p2222", "-J", "jump", "-i", "/key path", "-L", "9000:localhost:80", "user@host"]),
            transferTarget: "user@host", localProcessGroupID: nil)
        let connection = try GitSSHConnection(session: ssh)
        #expect(connection.options == ["-A", "-p", "2222", "-J", "jump", "-i", "/key path"])
        #expect(connection.arguments.contains("ClearAllForwardings=yes"))
        #expect(connection.arguments.contains("RemoteCommand=none"))
        #expect(!connection.arguments.contains("-tt"))
        let other = try GitSSHConnection(destination: "user@host", options: ["-p", "2223"])
        let first = GitRepositoryIdentity(target: .remote(host: "host", user: "user"), sshConnection: connection,
                                          worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let second = GitRepositoryIdentity(target: .remote(host: "host", user: "user"), sshConnection: other,
                                           worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        #expect(first.stateKey != second.stateKey && first.stateKey != "/repo")
    }

    @Test func rawProcessArgumentsPreserveBoundariesAndDoNotReadEnvironment() throws {
        let arguments = ["ssh", "-i", "/key path/with'quote", "user@host"]
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(Data("/usr/bin/ssh\0\0".utf8))
        for argument in arguments { bytes.append(Data((argument + "\0").utf8)) }
        bytes.append(Data("PRIVATE_ENV=not-an-argument\0".utf8))
        #expect(SSHProcessArguments.decode(bytes) == arguments)
        #expect(SSHProcessArguments.read(pid: getpid())?.isEmpty == false)
        let unknown = PaneSessionContext.SSH(connectionID: "old", alias: "host", serverID: nil, replay: nil,
                                             transferTarget: "host", localProcessGroupID: 123)
        #expect(throws: (any Error).self) { try GitSSHConnection(session: unknown) }
        let unbound = PaneSessionContext.SSH(connectionID: "omg-ssh-unbound", alias: "host", serverID: nil,
                                             replay: nil, transferTarget: "host", localProcessGroupID: nil)
        #expect(throws: (any Error).self) { try GitSSHConnection(session: unbound) }
        #expect(GitRepositoryService.absolutePath("../.git", relativeTo: "/remote/repo/sub/") == "/remote/repo/.git")
    }

    @Test func rejectedCommandWithLargeStdinDoesNotBlockOrSignalTheApp() async throws {
        let result = try await LocalGitExecutor(gitPath: "/bin/sh").execute(
            arguments: ["-c", "exit 1"], workingDirectory: "/", stdin: Data(repeating: 42, count: 1024 * 1024))
        #expect(result.exitCode == 1)
    }

    @Test func framedTransportPreservesNULAndStdinAndQuotesPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        printf 'login banner\n'
        for last do :; done
        exec /bin/sh -c "$last"
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let connection = try GitSSHConnection(destination: "stub")
        let executor = SSHGitExecutor(connection: connection, sshPath: stub.path)
        let path = root.appendingPathComponent("quotes ' 中文 $(nope)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let initialized = try await executor.execute(arguments: ["init", "-b", "main"], workingDirectory: path.path)
        #expect(initialized.isSuccess)
        let hash = try await executor.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: Data("body ' \n 中文".utf8))
        #expect(hash.isSuccess && hash.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).count == 40)
        try Data("remote text".utf8).write(to: path.appendingPathComponent("new file"))
        let files = try await executor.execute(arguments: ["ls-files", "--others", "-z"], workingDirectory: path.path)
        #expect(files.stdout == Data("new file\0".utf8))
        #expect(try await executor.readWorkingFile(at: path.appendingPathComponent("new file").path, root: path.path, limit: 100) == Data("remote text".utf8))
        await #expect(throws: (any Error).self) {
            try await executor.readWorkingFile(at: path.appendingPathComponent("new file").path, root: path.path, limit: 2)
        }
    }

    @Test func realSSHProvidesReadWriteAndDiffParityWithoutLocalPathFallback() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let path = server.root.appendingPathComponent("repo ' 中文")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let remote = SSHGitExecutor(connection: server.connection)
        for args in [["init", "-b", "main"], ["config", "user.name", "SSH Test"], ["config", "user.email", "ssh@example.com"],
                     ["config", "commit.gpgSign", "false"], ["config", "core.hooksPath", path.path + "/.git/hooks"]] {
            #expect(try await remote.execute(arguments: args, workingDirectory: path.path).isSuccess)
        }
        let payload = Data((0..<200_000).map { UInt8($0 % 256) })
        let remoteHash = try await remote.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        let localHash = try await LocalGitExecutor().execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        #expect(remoteHash.stdout == localHash.stdout)
        let status = await GitRepositoryService().resolveStatus(workingDirectory: path.path, session: server.session(directory: path.path))
        let repository = try #require(status.repository)
        #expect(repository.sshConnection?.options == server.connection.options)
        #expect(repository.stateKey != path.path)
        try Data("let number = 1\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        let mutations = GitMutationService()
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.commit("first ' 中文\n\nBody"), in: repository)
        let history = GitHistoryService()
        let snapshot = try await history.captureSnapshot(for: repository, scope: .allBranches)
        let page = try await history.loadPage(snapshot: snapshot, repository: repository, offset: 0)
        #expect(page.commits.first?.subject == "first ' 中文")
        let diff = GitDiffService()
        let commit = try #require(page.commits.first?.id)
        let changed = try await diff.listFiles(for: repository, target: .commit(commit))
        let original = try await diff.sourceVersions(for: changed.files[0], repository: repository, target: .commit(commit))
        #expect(original.before.isEmpty && original.after == "let number = 1\n")
        try Data("let number = 2\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        let unstaged = try await diff.listFiles(for: repository, target: .unstaged)
        let source = try await diff.sourceVersions(for: unstaged.files[0], repository: repository, target: .unstaged)
        #expect(source.before == "let number = 1\n" && source.after == "let number = 2\n")
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.unstage(["file.swift"]), in: repository)
        #expect(try await diff.listFiles(for: repository, target: .staged).files.isEmpty)
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.commit("second"), in: repository)
        try await mutations.perform(.create(name: "feature/ssh", start: "refs/heads/main"), in: repository)
        try await mutations.perform(.checkout("main"), in: repository)
        let bare = server.root.appendingPathComponent("upstream.git").path
        #expect(try await remote.execute(arguments: ["init", "--bare", bare], workingDirectory: path.path).isSuccess)
        #expect(try await remote.execute(arguments: ["remote", "add", "origin", bare], workingDirectory: path.path).isSuccess)
        try await mutations.perform(.push(branch: "feature/ssh", remote: "origin", destination: "review/ssh"), in: repository)
        try await mutations.perform(.setUpstream(branch: "feature/ssh", upstream: "refs/remotes/origin/review/ssh"), in: repository)
        let branches = try await GitRepositoryService().branches(for: repository)
        #expect(branches.first(where: { $0.name == "feature/ssh" })?.upstream == "origin/review/ssh")
        #expect(branches.first(where: { $0.isCurrent })?.name == "main")

        // The same path on local and SSH surfaces must have independent drafts,
        // selected tabs and expanded commits, while using the same native provider.
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let tab = UUID()
        let surface = UUID()
        let localContext = InspectorPaneContext(tabID: tab, surfaceID: surface, title: "Local", workingDirectory: path.path)
        let sshContext = InspectorPaneContext(tabID: tab, surfaceID: surface, title: "SSH", workingDirectory: path.path,
                                              session: server.session(directory: path.path))
        defer { registry.presentationDidChange(to: nil, context: localContext) }
        func send(_ action: InspectorGitAction, in context: InspectorPaneContext) {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID, action: .init(context: context, kind: .gitAction(action)))
        }
        func waitFor(_ context: InspectorPaneContext, _ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<400 {
                if case .git(let value) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !value.isLoading, !value.history.isLoading, value.operation == nil, predicate(value) { return value }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw GitExecutionError.executionFailed("SSH provider did not publish expected state.")
        }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: localContext)
        _ = try await waitFor(localContext) { $0.repository != nil }
        send(.updateCommitDraft("local draft"), in: localContext)
        send(.selectTab(.changes), in: localContext)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: sshContext)
        let remoteState = try await waitFor(sshContext) { $0.repository?.sshConnection != nil }
        #expect(remoteState.commitDraft.isEmpty && remoteState.activeTab == .history)
        #expect(remoteState.connectionLabel == server.connection.destination)
        let remoteCommit = try #require(remoteState.history.commits.first?.id)
        send(.openCommit(remoteCommit), in: sshContext)
        let expanded = try await waitFor(sshContext) { $0.expandedCommits[remoteCommit]?.metadata != nil }
        #expect(expanded.expandedCommits[remoteCommit]?.files.first?.path == "file.swift")
        try Data("let number = 3\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        send(.refresh, in: sshContext)
        let updated = try await waitFor(sshContext) { !$0.workingTree.unstaged.isEmpty }
        send(.setFileStaged(updated.workingTree.unstaged[0], true), in: sshContext)
        _ = try await waitFor(sshContext) { !$0.workingTree.staged.isEmpty }
        send(.updateCommitDraft("remote draft"), in: sshContext)
        send(.commitStaged, in: sshContext)
        _ = try await waitFor(sshContext) { $0.commitDraft.isEmpty && $0.history.commits.count == 3 }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: localContext)
        let restored = try await waitFor(localContext) { $0.repository?.target == .local }
        #expect(restored.commitDraft == "local draft" && restored.activeTab == .changes)
        #expect(restored.expandedCommits.isEmpty)
        registry.presentationDidChange(to: nil, context: localContext)
        server.process.terminate()
        server.process.waitUntilExit()
        await #expect(throws: (any Error).self) {
            try await remote.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        }
        let disconnected = await GitRepositoryService().resolveStatus(workingDirectory: path.path, session: server.session(directory: path.path))
        guard case .error = disconnected else { Issue.record("A disconnected SSH session must never fall back to local Git"); return }

    }
}
