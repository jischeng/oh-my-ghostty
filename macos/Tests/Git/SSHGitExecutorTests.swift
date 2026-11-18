import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
final class GitSSHTestServer {
    let root: URL
    let process: Process
    let connection: GitSSHConnection

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-ssh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root
        self.process = Process()
        for key in ["host_key", "client_key"] {
            let result = try await GitProcessRunner().run(executablePath: "/usr/bin/ssh-keygen",
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
        Subsystem sftp internal-sftp
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

    func disconnect() {
        if process.isRunning {
            // Stopping only the listener leaves authenticated sshd children
            // (and therefore multiplexed transports) alive. Stop this fixture's
            // accepted sessions too, to model an actual server disconnect.
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            children.arguments = ["-TERM", "-P", String(process.processIdentifier)]
            children.standardOutput = FileHandle.nullDevice
            children.standardError = FileHandle.nullDevice
            if (try? children.run()) != nil { children.waitUntilExit() }
            process.terminate()
            process.waitUntilExit()
        }
    }

    func stop() {
        disconnect()
        try? FileManager.default.removeItem(at: root)
    }

    func session(directory: String) -> PaneSessionContext {
        var session = PaneSessionContext(workingDirectory: root.path, terminalTitle: "Test")
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
                                         terminfo: false, cache: false, args: connection.options + [connection.destination])
        let hex = directory.utf8.map { String(format: "%02x", $0) }.joined()
        session.apply(.init(action: .start, id: "omg-ssh-test", metadata: "type=remote;targethost=test-remote;cwdhex=" + hex),
                      currentWorkingDirectory: root.path, currentTerminalTitle: "Test", sshReplay: replay)
        return session
    }
}

@MainActor
struct SSHGitExecutorTests {
    @Test func privateMultiplexedConnectionReusesTransportAndKeepsEndpointsIsolated() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let remote = SSHGitExecutor(connection: server.connection)
        let arguments = ["-c", "alias.transport=!printf '%s' \"$SSH_CONNECTION\"", "transport"]
        let first = try await remote.execute(arguments: arguments, workingDirectory: server.root.path)
        try #require(first.isSuccess && !first.stdout.isEmpty)
        let start = Date()
        for _ in 0..<5 {
            let result = try await remote.execute(arguments: arguments, workingDirectory: server.root.path)
            #expect(result.isSuccess && result.stdout == first.stdout)
        }
        let reused = Date().timeIntervalSince(start) / 5
        let cold = SSHGitExecutor(connection: server.connection, multiplexing: false)
        let coldStart = Date()
        for _ in 0..<3 {
            let result = try await cold.execute(arguments: arguments, workingDirectory: server.root.path)
            #expect(result.isSuccess && result.stdout != first.stdout)
        }
        let fresh = Date().timeIntervalSince(coldStart) / 3
        print("SSH transport benchmark: fresh=\(fresh)s reused=\(reused)s per command")
        async let left = remote.execute(arguments: arguments, workingDirectory: server.root.path)
        async let right = remote.execute(arguments: arguments, workingDirectory: server.root.path)
        let pair = try await (left, right)
        #expect(pair.0.stdout == first.stdout && pair.1.stdout == first.stdout)
        let socket = try GitSSHControlSocket.path(for: server.connection, executablePath: "/usr/bin/ssh")
        #expect(socket.utf8.count < 104)
        let other = try GitSSHConnection(destination: server.connection.destination,
            options: server.connection.options, localWorkingDirectory: server.root.path)
        #expect(try GitSSHControlSocket.path(for: other, executablePath: "/usr/bin/ssh") != socket)
        #expect(try GitSSHControlSocket.path(for: server.connection, executablePath: "/different/ssh") != socket)
    }

    @Test func connectionPreservesRoutingOptionsWithoutRepeatingInteractiveSideEffects() throws {
        let ssh = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil,
            replay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false,
                          args: ["-tt", "-A", "-p2222", "-J", "jump", "-i", "/key path", "-L", "9000:localhost:80", "user@host"]),
            transferTarget: "user@host", localProcessGroupID: nil)
        let connection = try GitSSHConnection(session: ssh)
        #expect(connection.options == ["-A", "-p", "2222", "-J", "jump", "-i", "/key path"])
        #expect(connection.arguments.contains("ConnectTimeout=15"))
        #expect(connection.arguments.contains("ServerAliveInterval=15"))
        #expect(connection.arguments.contains("ServerAliveCountMax=3"))
        #expect(connection.arguments.contains("ClearAllForwardings=yes"))
        #expect(connection.arguments.contains("RemoteCommand=none"))
        #expect(!connection.arguments.contains("-tt"))
        let other = try GitSSHConnection(destination: "user@host", options: ["-p", "2223"])
        let first = GitRepositoryIdentity(target: .ssh(connection),
                                          worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let second = GitRepositoryIdentity(target: .ssh(other),
                                           worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        #expect(first.stateKey != second.stateKey && first.stateKey != "/repo")
    }

    @Test func sharedSSHParserPreservesCombinedValueOptionsAndRejectsUnknownOptions() throws {
        let arguments = ["-4vp2222", "-Ai", "/key path", "-oProxyCommand=proxy %h %p", "--", "user@host"]
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
                                         cache: false, args: arguments)
        let ssh = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil, replay: replay,
                                         transferTarget: "user@host", localProcessGroupID: nil)
        #expect(ForegroundSSHProcessDetector.interactiveDestination(arguments) == "user@host")
        let connection = try GitSSHConnection(session: ssh)
        #expect(connection.options == ["-4", "-p", "2222", "-A", "-i", "/key path", "-o", "ProxyCommand=proxy %h %p"])
        for invalid in [["-Z", "host"], ["-vZ", "host"], ["-p"], ["-vp", "2222"], ["-vN", "host"], ["host", "uptime"]] {
            #expect(ForegroundSSHProcessDetector.interactiveDestination(invalid) == nil)
            let rejected = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil,
                replay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false, args: invalid),
                transferTarget: "host", localProcessGroupID: nil)
            #expect(throws: (any Error).self) { try GitSSHConnection(session: rejected) }
        }
    }

    @Test func executableResolutionUsesCapturedDirectoryAndExplicitSearchPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("custom-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = bin.appendingPathComponent("ssh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(SSHProcessArguments.executablePath(for: "ssh", workingDirectory: root.path, searchPath: "custom-bin:/usr/bin") == executable.path)
        #expect(SSHProcessArguments.executablePath(for: "custom-bin/ssh", workingDirectory: root.path) == executable.path)
        #expect(SSHProcessArguments.executablePath(for: "ssh", workingDirectory: root.path, searchPath: "missing") == nil)
        #expect(SSHProcessArguments.workingDirectory(pid: getpid()) == FileManager.default.currentDirectoryPath)

        let replay = SSHReplayDescriptor(version: 1, ssh: "custom-bin/ssh", forwardEnv: false, terminfo: false,
                                         cache: false, args: ["host"], localWorkingDirectory: root.path)
        var session = PaneSessionContext(workingDirectory: "/stale-local-directory", terminalTitle: "Test")
        session.observeForegroundSSH(alias: "host", transferTarget: "host", processGroupID: 123,
                                     currentWorkingDirectory: nil, currentTerminalTitle: "Test",
                                     remoteWorkingDirectory: "/remote", replay: replay)
        let connection = try GitSSHConnection(session: session)
        #expect(connection.localWorkingDirectory == root.path)
        #expect(connection.executablePath == executable.path)
        let decoded = try JSONDecoder().decode(SSHReplayDescriptor.self, from: JSONEncoder().encode(replay))
        #expect(decoded.localWorkingDirectory == root.path)
    }

    @Test func replayUsesTheCapturedLaunchDirectoryWithoutChangingItsCaller() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-replay-\(UUID().uuidString)")
        let original = root.appendingPathComponent("original ' cwd")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("omg")
        try "#!/bin/sh\npwd -P\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
                                         cache: false, args: ["-F", "./config", "host"], localWorkingDirectory: original.path)
        let command = try #require(replay.command(executablePath: executable.path))
        let result = try await GitProcessRunner().run(executablePath: "/bin/sh", arguments: ["-c", command + "; pwd -P"],
                                                      workingDirectory: root.path)
        #expect(result.isSuccess)
        let observed = result.stdoutString.split(separator: "\n").map(String.init)
        try #require(observed.count == 2)
        for (actual, expected) in zip(observed, [original, root]) {
            let actualAttributes = try FileManager.default.attributesOfItem(atPath: actual)
            let expectedAttributes = try FileManager.default.attributesOfItem(atPath: expected.path)
            #expect(actualAttributes[.systemNumber] as? NSNumber == expectedAttributes[.systemNumber] as? NSNumber)
            #expect(actualAttributes[.systemFileNumber] as? NSNumber == expectedAttributes[.systemFileNumber] as? NSNumber)
        }
    }

    @Test func relativeSSHConfigurationIdentityAndProxyKeepTheOriginalLaunchDirectory() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let portIndex = try #require(server.connection.options.firstIndex(of: "-p"))
        let port = server.connection.options[portIndex + 1]
        let configuration = """
        Host history-review
            HostName 127.0.0.1
            User \(NSUserName())
            Port \(port)
            IdentitiesOnly yes
            UserKnownHostsFile ./known_hosts
            StrictHostKeyChecking yes
        """
        try configuration.write(to: server.root.appendingPathComponent("client_config"), atomically: true, encoding: .utf8)
        let proxy = server.root.appendingPathComponent("proxy")
        try "#!/bin/sh\nexec /usr/bin/nc \"$1\" \"$2\"\n".write(to: proxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: proxy.path)
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
            cache: false, args: ["-F", "./client_config", "-i", "./client_key", "-o", "ProxyCommand=./proxy %h %p", "history-review"])
        var session = PaneSessionContext(workingDirectory: server.root.path, terminalTitle: "Test")
        session.observeForegroundSSH(alias: "history-review", transferTarget: "history-review", processGroupID: 123,
                                     currentWorkingDirectory: server.root.path, currentTerminalTitle: "Test",
                                     remoteWorkingDirectory: "/", replay: replay)
        let connection = try GitSSHConnection(session: session)
        #expect(connection.localWorkingDirectory == server.root.path)
        let result = try await SSHGitExecutor(connection: connection).execute(arguments: ["--version"], workingDirectory: "/")
        #expect(result.isSuccess && result.stdoutString.hasPrefix("git version"))
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
        let result = try await GitProcessRunner().run(executablePath: "/bin/sh",
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

    @Test func largeFrozenHistorySnapshotStreamsRevisionsOverSSH() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let path = server.root.appendingPathComponent("large history")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let remote = SSHGitExecutor(connection: server.connection)
        for args in [["init", "-b", "main"], ["config", "user.name", "SSH Test"],
                     ["config", "user.email", "ssh@example.com"], ["config", "commit.gpgSign", "false"],
                     ["commit", "--allow-empty", "-m", "frozen history"]] {
            #expect(try await remote.execute(arguments: args, workingDirectory: path.path).isSuccess)
        }
        let status = await GitRepositoryService().resolveStatus(
            workingDirectory: path.path, session: server.session(directory: path.path))
        let repository = try #require(status.repository)
        let service = GitHistoryService()
        let original = try await service.captureSnapshot(for: repository, scope: .allBranches)
        let head = try #require(original.headCommitID)
        // Repeated valid revisions exercise the real SSH byte-size boundary
        // without creating thousands of objects. This is >1 MiB before wrapping.
        let snapshot = GitHistorySnapshot(scope: .allBranches, branchName: "main",
            headCommitID: head, tipCommitIDs: Array(repeating: head, count: 30_000),
            decorationsByCommitID: original.decorationsByCommitID)
        #expect(try await remote.execute(arguments: ["commit", "--allow-empty", "-m", "after snapshot"],
            workingDirectory: path.path).isSuccess)
        let page = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0, pageSize: 1)
        #expect(page.commits.map(\.subject) == ["frozen history"])
        #expect(!page.hasMore)
        let next = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 1, pageSize: 1)
        #expect(next.commits.isEmpty)
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
        try await mutations.perform(.discard(unstaged.files[0], staged: false), in: repository)
        #expect(try String(contentsOf: path.appendingPathComponent("file.swift"), encoding: .utf8) == "let number = 1\n")
        try Data("let number = 2\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        let unrelated = path.appendingPathComponent("unrelated [two]*.txt")
        try Data("untracked\n".utf8).write(to: unrelated)
        let scoped = try await diff.workingTreeFiles(for: repository, paths: ["file.swift"])
        #expect(scoped.staged.isEmpty && scoped.unstaged.map(\.path) == ["file.swift"])
        let literal = try await diff.workingTreeFiles(for: repository, paths: [unrelated.lastPathComponent])
        #expect(literal.unstaged.map(\.path) == [unrelated.lastPathComponent])
        try FileManager.default.removeItem(at: unrelated)
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.unstage(["file.swift"]), in: repository)
        #expect(try await diff.listFiles(for: repository, target: .staged).files.isEmpty)
        let statusFiles = try await diff.workingTreeFiles(for: repository)
        #expect(statusFiles.staged.isEmpty && statusFiles.unstaged.map(\.path) == ["file.swift"])
        var checkboxTimings: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            try await mutations.perform(.stage(["file.swift"]), in: repository)
            let stagedFiles = try await diff.workingTreeFiles(for: repository)
            #expect(stagedFiles.staged.map(\.path) == ["file.swift"] && stagedFiles.unstaged.isEmpty)
            checkboxTimings.append(Date().timeIntervalSince(start) * 1000)
            try await mutations.perform(.unstage(["file.swift"]), in: repository)
        }
        print("SSH checkbox benchmark (loopback, mutation + refreshed status): median=\(checkboxTimings.sorted()[2])ms")
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
        server.disconnect()
        await #expect(throws: (any Error).self) {
            try await remote.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        }
        let disconnected = await GitRepositoryService().resolveStatus(workingDirectory: path.path, session: server.session(directory: path.path))
        guard case .error = disconnected else { Issue.record("A disconnected SSH session must never fall back to local Git"); return }

    }

    @Test func controlPersistIsOneHourForMultiplexedConnections() throws {
        let connection = try GitSSHConnection(destination: "user@host")
        let multiplexed = connection.arguments(controlSocket: "/tmp/omg-test.sock")
        #expect(multiplexed.contains("ControlMaster=auto"))
        #expect(multiplexed.contains("ControlPersist=3600"))
        #expect(connection.arguments.contains("ControlMaster=no"))
        #expect(connection.arguments.contains("ControlPersist=no"))
    }

    @Test func idempotentReadOnlyClassificationSeparatesReadsFromConfigOverridesAndWrites() {
        let readOnlyCases: [[String]] = [
            ["--version"],
            ["version"],
            ["--no-optional-locks", "rev-parse", "--show-toplevel"],
            ["-C", "/repo", "symbolic-ref", "--short", "HEAD"],
            ["-C/repo", "status", "--porcelain=v1", "-z"],
            ["--git-dir=/repo/.git", "--work-tree=/repo", "diff", "--cached"],
            ["diff-index", "--cached", "HEAD"],
            ["diff-files"],
            ["diff-tree", "-r", "HEAD"],
            ["log", "-n", "10"],
            ["show", "--no-patch", "HEAD"],
            ["for-each-ref", "refs/heads"],
            ["ls-files", "-z"],
            ["ls-tree", "HEAD"],
            ["cat-file", "-p", "HEAD"],
            ["describe", "--tags"],
            ["--no-optional-locks", "worktree", "list", "--porcelain", "-z"],
            ["remote"],
            ["remote", "-v"],
            ["remote", "--verbose"],
            ["remote", "get-url", "origin"],
        ]
        for arguments in readOnlyCases {
            #expect(SSHGitExecutor.isIdempotentReadOnly(arguments: arguments), "Expected read-only for \(arguments)")
        }

        let nonIdempotentCases: [[String]] = [
            [],
            ["-c", "alias.status=!touch /tmp/pwn", "status"],
            ["-calias.status=x", "status"],
            ["--config-env=core.fsmonitor=HOOK", "status"],
            ["--config-env", "core.fsmonitor=HOOK", "status"],
            ["status", "-c"],
            ["commit", "-m", "msg"],
            ["push", "origin", "main"],
            ["pull"],
            ["fetch", "--prune"],
            ["checkout", "main"],
            ["switch", "-c", "feature"],
            ["restore", "file.swift"],
            ["reset", "--quiet", "--", "file.swift"],
            ["add", "--", "file.swift"],
            ["rm", "file.swift"],
            ["mv", "a", "b"],
            ["merge", "feature"],
            ["rebase", "main"],
            ["cherry-pick", "abc123"],
            ["revert", "abc123"],
            ["stash", "push"],
            ["clean", "-fd"],
            ["tag", "v1.0.0"],
            ["branch", "feature"],
            ["config", "--get", "remote.origin.url"],
            ["worktree", "add", "/tmp/wt"],
            ["worktree", "remove", "/tmp/wt"],
            ["remote", "add", "origin", "https://example.com/repo.git"],
            ["remote", "-v", "add", "origin", "https://example.com/repo.git"],
            ["remote", "set-url", "origin", "https://example.com/repo.git"],
            ["hash-object", "-w", "--stdin"],
            ["rev-list", "--count", "HEAD"],
        ]
        for arguments in nonIdempotentCases {
            #expect(!SSHGitExecutor.isIdempotentReadOnly(arguments: arguments), "Expected non-idempotent for \(arguments)")
        }
    }

    @Test func activeRelayExecLocalFastPathFallbackLimitAndTransportSentinel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-exec-local-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let relaySocket = root.appendingPathComponent("relay.sock")
        let sshStub = root.appendingPathComponent("ssh")
        let omgdStub = root.appendingPathComponent("omgd")
        let modeFile = root.appendingPathComponent("omgd.mode")
        let omgdLog = root.appendingPathComponent("omgd.log")
        let sshLog = root.appendingPathComponent("ssh.log")

        let sshScript = """
        #!/bin/sh
        printf 'ssh:%s\\n' "$*" >> \(SSHGitExecutor.quote(sshLog.path))
        printf 'via-ssh\\n'
        exit 0
        """
        try sshScript.write(to: sshStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshStub.path)

        let omgdScript = """
        #!/bin/sh
        printf '%s|%s|%s\\n' "$1" "$2" "$3" >> \(SSHGitExecutor.quote(omgdLog.path))
        mode=$(cat \(SSHGitExecutor.quote(modeFile.path)))
        case "$mode" in
          ok)
            printf 'via-omgd\\n'
            exit 0
            ;;
          unsupported)
            printf '\\036OMG-EXEC-UNSUPPORTED\\037relay unavailable\\n' >&2
            exit 253
            ;;
          plain253)
            printf 'remote exited 253\\n' >&2
            exit 253
            ;;
          limit)
            printf '\\036OMG-EXEC-LIMIT\\037output limit exceeded\\n' >&2
            exit 252
            ;;
          transport-once)
            printf 'ok\\n' > \(SSHGitExecutor.quote(modeFile.path))
            printf '\\036OMG-EXEC-TRANSPORT\\037\\ntransport dropped\\n' >&2
            exit 255
            ;;
          transport-always)
            printf '\\036OMG-EXEC-TRANSPORT\\037\\ntransport dropped\\n' >&2
            exit 255
            ;;
        esac
        """
        try omgdScript.write(to: omgdStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: omgdStub.path)

        let connection = try GitSSHConnection(
            destination: "exec-test-\(UUID().uuidString)",
            options: ["-p", "2222"],
            workspaceID: "ssh:exec-primary",
            executablePath: sshStub.path,
            localWorkingDirectory: root.path
        )
        defer { SessionRuntimeConnections.setTestActiveRelaySocket(nil, for: connection) }

        // Missing socket file on disk must not resolve.
        SessionRuntimeConnections.setTestActiveRelaySocket(relaySocket, for: connection)
        #expect(SessionRuntimeConnections.activeRelaySocket(for: connection) == nil)

        // Present socket matches exact connection and matching (destination, options, executablePath).
        FileManager.default.createFile(atPath: relaySocket.path, contents: Data())
        #expect(SessionRuntimeConnections.activeRelaySocket(for: connection) == relaySocket)
        let siblingConnection = try GitSSHConnection(
            destination: connection.destination,
            options: connection.options,
            workspaceID: "ssh:exec-sibling",
            executablePath: sshStub.path,
            localWorkingDirectory: "/tmp"
        )
        #expect(SessionRuntimeConnections.activeRelaySocket(for: siblingConnection) == relaySocket)

        // 1. Fast path succeeds via omgd exec-local without touching ssh.
        try "ok".write(to: modeFile, atomically: true, encoding: .utf8)
        let okResult = try await SSHSessionTransport.run(
            connection: connection,
            command: "echo hi",
            limit: 4096,
            omgdExecutableOverride: omgdStub.path
        )
        #expect(okResult.isSuccess && okResult.stdoutString == "via-omgd\n")
        #expect(!FileManager.default.fileExists(atPath: sshLog.path))
        let recordedOmgd = try String(contentsOf: omgdLog, encoding: .utf8)
        #expect(recordedOmgd.contains("exec-local|\(relaySocket.path)|4096"))

        // 2. Exit 253 with sentinel falls through transparently to OpenSSH.
        try "unsupported".write(to: modeFile, atomically: true, encoding: .utf8)
        let fallbackResult = try await SSHSessionTransport.run(
            connection: connection,
            command: "echo hi",
            limit: 4096,
            multiplexing: true,
            omgdExecutableOverride: omgdStub.path
        )
        #expect(fallbackResult.isSuccess && fallbackResult.stdoutString == "via-ssh\n")
        #expect(try String(contentsOf: sshLog, encoding: .utf8).contains("ssh:"))
        try? FileManager.default.removeItem(at: sshLog)

        // 3. Exit 253 without sentinel returns directly without SSH fallback.
        try "plain253".write(to: modeFile, atomically: true, encoding: .utf8)
        let plain253Result = try await SSHSessionTransport.run(
            connection: connection,
            command: "echo hi",
            limit: 4096,
            omgdExecutableOverride: omgdStub.path
        )
        #expect(plain253Result.exitCode == 253)
        #expect(plain253Result.stderrString == "remote exited 253\n")
        #expect(!FileManager.default.fileExists(atPath: sshLog.path))

        // 4. Exit 252 with sentinel throws outputLimitExceeded without SSH fallback.
        try "limit".write(to: modeFile, atomically: true, encoding: .utf8)
        do {
            _ = try await SSHSessionTransport.run(
                connection: connection,
                command: "echo hi",
                limit: 1234,
                omgdExecutableOverride: omgdStub.path
            )
            Issue.record("Expected outputLimitExceeded for 252 sentinel")
        } catch let error as GitExecutionError {
            #expect(error == .outputLimitExceeded(maxBytes: 1234))
        }
        #expect(!FileManager.default.fileExists(atPath: sshLog.path))

        // 5. Exit 255 transport sentinel strips prefix line, retries once when idempotent, and does not retry writes.
        try "transport-once".write(to: modeFile, atomically: true, encoding: .utf8)
        let retriedResult = try await SSHSessionTransport.run(
            connection: connection,
            command: "echo hi",
            limit: 4096,
            idempotent: true,
            omgdExecutableOverride: omgdStub.path
        )
        #expect(retriedResult.isSuccess && retriedResult.stdoutString == "via-omgd\n")
        #expect(!FileManager.default.fileExists(atPath: sshLog.path))

        try "transport-always".write(to: modeFile, atomically: true, encoding: .utf8)
        try Data().write(to: omgdLog)
        let writeFailure = try await SSHSessionTransport.run(
            connection: connection,
            command: "echo hi",
            limit: 4096,
            idempotent: false,
            omgdExecutableOverride: omgdStub.path
        )
        #expect(writeFailure.exitCode == 255)
        #expect(writeFailure.stderrString == "transport dropped\n")
        #expect(try String(contentsOf: omgdLog, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func openSSHColdHandshakeSerializesConcurrentCallsAndEvictsBrokenSockets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-cold-handshake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Part A: 6 concurrent reads start cold -> cold_max == 1, then warm calls run concurrently (<= 4).
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let coldSSH = root.appendingPathComponent("ssh-cold")
        let coldScript = """
        #!/bin/sh
        STATE=\(SSHGitExecutor.quote(stateDir.path))
        SOCKET=""
        PREV=""
        for arg in "$@"; do
          if [ "$PREV" = "-S" ]; then
            SOCKET="$arg"
            break
          fi
          PREV="$arg"
        done
        LOCK="$STATE/lock"
        acquire_lock() {
          while ! mkdir "$LOCK" 2>/dev/null; do
            sleep 0.005
          done
        }
        release_lock() {
          rmdir "$LOCK"
        }
        acquire_lock
        IS_COLD=0
        if [ -n "$SOCKET" ] && [ ! -e "$SOCKET" ]; then
          IS_COLD=1
          c=$(cat "$STATE/cold_active" 2>/dev/null || echo 0)
          c=$((c + 1))
          echo "$c" > "$STATE/cold_active"
          m=$(cat "$STATE/cold_max" 2>/dev/null || echo 0)
          if [ "$c" -gt "$m" ]; then echo "$c" > "$STATE/cold_max"; fi
        else
          w=$(cat "$STATE/warm_active" 2>/dev/null || echo 0)
          w=$((w + 1))
          echo "$w" > "$STATE/warm_active"
          wm=$(cat "$STATE/warm_max" 2>/dev/null || echo 0)
          if [ "$w" -gt "$wm" ]; then echo "$w" > "$STATE/warm_max"; fi
        fi
        release_lock
        if [ "$IS_COLD" -eq 1 ]; then
          sleep 0.05
        else
          sleep 0.12
        fi
        acquire_lock
        if [ "$IS_COLD" -eq 1 ]; then
          touch "$SOCKET"
          c=$(cat "$STATE/cold_active" 2>/dev/null || echo 1)
          echo $((c - 1)) > "$STATE/cold_active"
        else
          w=$(cat "$STATE/warm_active" 2>/dev/null || echo 1)
          echo $((w - 1)) > "$STATE/warm_active"
        fi
        release_lock
        printf 'ok\\n'
        exit 0
        """
        try coldScript.write(to: coldSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: coldSSH.path)

        let coldConnection = try GitSSHConnection(
            destination: "cold-host-\(UUID().uuidString)",
            executablePath: coldSSH.path,
            localWorkingDirectory: root.path
        )
        let coldSocket = try GitSSHControlSocket.path(for: coldConnection, executablePath: coldSSH.path)
        defer { Darwin.unlink(coldSocket) }
        try? FileManager.default.removeItem(atPath: coldSocket)

        try await withThrowingTaskGroup(of: GitExecutionResult.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await SSHSessionTransport.run(
                        connection: coldConnection,
                        command: "echo ok",
                        executable: coldSSH.path,
                        idempotent: true
                    )
                }
            }
            var count = 0
            for try await result in group {
                #expect(result.isSuccess)
                count += 1
            }
            #expect(count == 6)
        }
        let maxCold = Int(try String(contentsOf: stateDir.appendingPathComponent("cold_max"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let maxWarm = Int(try String(contentsOf: stateDir.appendingPathComponent("warm_max"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(maxCold == 1)
        #expect((maxWarm ?? 0) >= 2 && (maxWarm ?? 0) <= 4)

        // Part B: exit 255 evicts broken control socket, retries idempotent reads once, never retries writes.
        let evictSSH = root.appendingPathComponent("ssh-evict")
        let evictLog = root.appendingPathComponent("evict.log")
        let failFlag = root.appendingPathComponent("fail_once")
        let evictScript = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(SSHGitExecutor.quote(evictLog.path))
        for arg in "$@"; do
          if [ "$arg" = "check" ]; then
            exit 255
          fi
          if [ "$arg" = "exit" ]; then
            exit 0
          fi
        done
        if [ -f \(SSHGitExecutor.quote(failFlag.path)) ]; then
          rm -f \(SSHGitExecutor.quote(failFlag.path))
          printf 'ControlSocket broken\\n' >&2
          exit 255
        fi
        printf '\\036OMG-GIT-v1\\037recovered\\n'
        exit 0
        """
        try evictScript.write(to: evictSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: evictSSH.path)

        let evictConnection = try GitSSHConnection(
            destination: "evict-host-\(UUID().uuidString)",
            executablePath: evictSSH.path,
            localWorkingDirectory: root.path
        )
        let evictSocket = try GitSSHControlSocket.path(for: evictConnection, executablePath: evictSSH.path)
        defer { Darwin.unlink(evictSocket) }
        FileManager.default.createFile(atPath: evictSocket, contents: Data())
        FileManager.default.createFile(atPath: failFlag.path, contents: Data())

        let executor = SSHGitExecutor(connection: evictConnection)
        let readResult = try await executor.execute(arguments: ["status"], workingDirectory: root.path)
        #expect(readResult.isSuccess && readResult.stdoutString == "recovered\n")
        #expect(!FileManager.default.fileExists(atPath: evictSocket))
        let readLog = try String(contentsOf: evictLog, encoding: .utf8)
        #expect(readLog.contains("-O check"))
        #expect(readLog.contains("-O exit"))

        // Mutating command must evict broken socket on 255 and must NOT retry.
        try Data().write(to: evictLog)
        FileManager.default.createFile(atPath: evictSocket, contents: Data())
        FileManager.default.createFile(atPath: failFlag.path, contents: Data())
        await #expect(throws: GitExecutionError.self) {
            try await executor.execute(arguments: ["commit", "-m", "write"], workingDirectory: root.path)
        }
        #expect(!FileManager.default.fileExists(atPath: evictSocket))
        let writeLogLines = try String(contentsOf: evictLog, encoding: .utf8).split(separator: "\n")
        let commandInvocations = writeLogLines.filter { !$0.contains("-O check") && !$0.contains("-O exit") }
        #expect(commandInvocations.count == 1)
    }

    @Test func gitInspectorProviderAppliesPollBackoffPauseRecoveryAndStaleWhileRevalidate() async throws {
        actor MockSSHExecutor: GitExecutor {
            var shouldFail = true
            var revParseAttempts = 0

            func setShouldFail(_ value: Bool) {
                shouldFail = value
            }

            func execute(
                arguments: [String],
                workingDirectory: String,
                stdin: Data?,
                maxOutputBytes: Int?
            ) async throws -> GitExecutionResult {
                if shouldFail {
                    if arguments.contains("rev-parse"), arguments.contains("--is-inside-work-tree") {
                        revParseAttempts += 1
                    }
                    throw GitExecutionError.executionFailed("Jump host rate limit")
                }
                if arguments.contains("rev-parse") && arguments.contains("--is-inside-work-tree") {
                    revParseAttempts += 1
                    let out = "true\n/remote/repo\n/remote/repo/.git\n/remote/repo/.git\n\n"
                    return GitExecutionResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data())
                }
                if arguments.contains("symbolic-ref") {
                    return GitExecutionResult(exitCode: 0, stdout: Data("main\n".utf8), stderr: Data())
                }
                if arguments.contains("rev-parse") && arguments.contains("--verify") {
                    let sha = "0123456789abcdef0123456789abcdef01234567\n"
                    return GitExecutionResult(exitCode: 0, stdout: Data(sha.utf8), stderr: Data())
                }
                if arguments.contains("config") {
                    return GitExecutionResult(exitCode: 1, stdout: Data(), stderr: Data())
                }
                return GitExecutionResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        }

        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 0) == 10)
        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 1) == 15)
        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 2) == 30)
        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 3) == 60)
        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 4) == 120)
        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 5) == 240)
        #expect(BuiltInGitInspectorProvider.remotePollInterval(failures: 8) == 240)

        let executor = MockSSHExecutor()
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, executor: executor)
        try provider.register()

        var session = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "SSH")
        let replay = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: false,
            terminfo: false,
            cache: false,
            args: ["user@host"]
        )
        let remoteDir = "/remote/repo"
        let hex = remoteDir.utf8.map { String(format: "%02x", $0) }.joined()
        session.apply(
            .init(action: .start, id: "omg-ssh-mock-backoff", metadata: "type=remote;targethost=host;cwdhex=" + hex),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "SSH",
            sshReplay: replay
        )
        guard case .sshReady = session.state else {
            Issue.record("Expected .sshReady state after applying mock SSH signal")
            return
        }

        let tabID = UUID()
        let context = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "SSH",
            workingDirectory: remoteDir,
            session: session
        )
        defer {
            registry.presentationDidChange(to: nil, context: context)
            provider.forgetTab(tabID)
        }

        func waitUntil(_ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<200 {
                if case .git(let value) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !value.isLoading,
                   !value.history.isLoading,
                   predicate(value) {
                    return value
                }
                try await Task.sleep(for: .milliseconds(15))
            }
            throw GitExecutionError.executionFailed("Timed out waiting for Git inspector provider update.")
        }

        // Initial load fails -> consecutivePollFailures == 1, .error published.
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        let firstError = try await waitUntil {
            if case .error = $0.status { return true }
            return false
        }
        #expect(firstError.repository == nil)
        #expect(provider.consecutivePollFailureCount(for: tabID) == 1)
        #expect(await executor.revParseAttempts == 1)

        // Poll #2 at t0 -> fails -> failures == 2.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        provider.pollPresentedTabs(at: t0)
        for _ in 0..<100 where provider.consecutivePollFailureCount(for: tabID) < 2 {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(provider.consecutivePollFailureCount(for: tabID) == 2)
        #expect(await executor.revParseAttempts == 2)

        // Poll at +15s is skipped because interval for 2 failures is 30s.
        provider.pollPresentedTabs(at: t0.addingTimeInterval(15))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await executor.revParseAttempts == 2)

        // Poll #3 at +30s -> fails -> failures == 3.
        provider.pollPresentedTabs(at: t0.addingTimeInterval(30))
        for _ in 0..<100 where provider.consecutivePollFailureCount(for: tabID) < 3 {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(provider.consecutivePollFailureCount(for: tabID) == 3)
        #expect(await executor.revParseAttempts == 3)

        // After 3 initial .sshReady failures with repository == nil, auto-polling pauses indefinitely.
        provider.pollPresentedTabs(at: t0.addingTimeInterval(1_000))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await executor.revParseAttempts == 3)

        // Manual .refresh clears failure count and recovers into .ready.
        await executor.setShouldFail(false)
        registry.performAction(
            paneID: BuiltInGitInspectorProvider.paneID,
            action: .init(context: context, kind: .gitAction(.refresh))
        )
        let ready = try await waitUntil { $0.repository != nil }
        #expect(ready.repository?.worktreePath == remoteDir)
        #expect(provider.consecutivePollFailureCount(for: tabID) == 0)

        // Stale-while-revalidate: transient background poll error preserves working repository view.
        await executor.setShouldFail(true)
        let beforeTransientPoll = await executor.revParseAttempts
        provider.pollPresentedTabs(at: t0.addingTimeInterval(2_000))
        for _ in 0..<100 where provider.consecutivePollFailureCount(for: tabID) < 1 {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(await executor.revParseAttempts == beforeTransientPoll + 1)
        #expect(provider.consecutivePollFailureCount(for: tabID) == 1)
        if case .git(let staleKept) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) {
            #expect(staleKept.repository?.worktreePath == remoteDir)
            #expect(!staleKept.isLoading)
            if case .ready = staleKept.status {
                // Expected stale repository state retained.
            } else {
                Issue.record("Expected stale .ready state to be preserved on transient background poll error")
            }
        } else {
            Issue.record("Expected .git content after stale-while-revalidate poll error")
        }
    }

    @Test func inspectorGitViewEnablesRefreshAndRetryInErrorState() async throws {
        let errorContent = InspectorGitContent(
            repository: nil,
            status: .error(title: "SSH Git Error", message: "Connection failed"),
            isLoading: false
        )
        let loadingErrorContent = InspectorGitContent(
            repository: nil,
            status: .error(title: "SSH Git Error", message: "Connection failed"),
            isLoading: true
        )
        let repo = GitRepositoryIdentity(
            worktreePath: "/repo",
            gitDirPath: "/repo/.git",
            commonGitDirPath: "/repo/.git"
        )
        let readyContent = InspectorGitContent(
            repository: repo,
            branch: "main",
            status: .ready(repository: repo, branch: "main", headCommitID: nil),
            isLoading: false
        )

        #expect(InspectorGitView.isToolbarRefreshEnabled(for: errorContent))
        #expect(!InspectorGitView.isToolbarRefreshEnabled(for: loadingErrorContent))
        #expect(InspectorGitView.toolbarRefreshAction(for: errorContent) == .refresh)
        #expect(InspectorGitView.toolbarRefreshAction(for: readyContent) == .fetch)

        var actions: [InspectorPaneActionKind] = []
        let view = NSHostingView(
            rootView: InspectorGitView(content: errorContent) { actions.append($0) }
                .background(Color(NSColor.windowBackgroundColor))
        )
        view.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        func allViews(_ root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allViews)
        }

        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()

        let fetchButton = try #require(allViews(view).first { $0.accessibilityIdentifier() == "git.fetch" } as? NSButton)
        let retryButton = try #require(allViews(view).first { $0.accessibilityIdentifier() == "git.retry" } as? NSButton)
        #expect(fetchButton.isEnabled)
        #expect(retryButton.isEnabled)

        retryButton.performClick(nil)
        fetchButton.performClick(nil)
        #expect(actions == [.gitAction(.refresh), .gitAction(.refresh)])

        view.rootView = InspectorGitView(content: loadingErrorContent) { actions.append($0) }
            .background(Color(NSColor.windowBackgroundColor))
        try await Task.sleep(for: .milliseconds(80))
        view.layoutSubtreeIfNeeded()
        let loadingFetch = try #require(allViews(view).first { $0.accessibilityIdentifier() == "git.fetch" } as? NSButton)
        let loadingRetry = try #require(allViews(view).first { $0.accessibilityIdentifier() == "git.retry" } as? NSButton)
        #expect(!loadingFetch.isEnabled)
        #expect(!loadingRetry.isEnabled)
    }

    @Test func inlineRelayRegistrationSingleShellWrapAndControlSocketWarmup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-inline-git-fast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let relaySocket = root.appendingPathComponent("relay.sock")
        let omgdStub = root.appendingPathComponent("omgd")
        let sshStub = root.appendingPathComponent("ssh")
        let omgdLog = root.appendingPathComponent("omgd.log")
        let sshLog = root.appendingPathComponent("ssh.log")

        let omgdScript = """
        #!/bin/sh
        printf '%s\\n' "$4" >> \(SSHGitExecutor.quote(omgdLog.path))
        printf '\\036OMG-GIT-v1\\037ok-inline\\n'
        exit 0
        """
        try omgdScript.write(to: omgdStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: omgdStub.path)

        let sshScript = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(SSHGitExecutor.quote(sshLog.path))
        SOCKET=""
        PREV=""
        for arg in "$@"; do
          if [ "$PREV" = "-S" ]; then
            SOCKET="$arg"
            break
          fi
          PREV="$arg"
        done
        if [ -n "$SOCKET" ] && [ ! -e "$SOCKET" ]; then
          touch "$SOCKET"
        fi
        printf '\\036OMG-GIT-v1\\037ok-ssh\\n'
        exit 0
        """
        try sshScript.write(to: sshStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshStub.path)

        let connection = try GitSSHConnection(
            destination: "inline-fast-\(UUID().uuidString)",
            options: ["-p", "2222"],
            workspaceID: "ssh:inline-primary",
            executablePath: sshStub.path,
            localWorkingDirectory: root.path
        )
        let args = connection.arguments(controlSocket: "/tmp/omg-compress.sock")
        #expect(args.contains("Compression=yes"))
        let portIndex = try #require(args.lastIndex(of: "2222"))
        let compressionIndex = try #require(args.lastIndex(of: "Compression=yes"))
        #expect(compressionIndex > portIndex)

        let descriptor = SessionRuntimeDescriptor(
            connection: connection,
            revision: "rev-inline-test",
            policy: SessionRuntimePolicy(),
            localWorkingDirectory: root.path,
            initialWorkingDirectory: "/remote/repo"
        )
        let inlineSession = SessionRuntimeInlineSession(
            descriptor: descriptor,
            pane: UUID(),
            connectionID: "omg-ssh-inline-\(UUID().uuidString)",
            socket: relaySocket,
            helperPID: getpid(),
            bootID: try #require(SessionRuntimeInlineSession.currentBootID)
        )
        FileManager.default.createFile(atPath: relaySocket.path, contents: Data())
        SessionRuntimeConnections.syncInlineRelaySession(old: nil, new: inlineSession)
        defer { SessionRuntimeConnections.syncInlineRelaySession(old: inlineSession, new: nil) }

        #expect(SessionRuntimeConnections.activeRelaySocket(for: connection) == relaySocket)
        let siblingConnection = try GitSSHConnection(
            destination: connection.destination,
            options: connection.options,
            workspaceID: "ssh:inline-sibling",
            executablePath: sshStub.path,
            localWorkingDirectory: "/tmp"
        )
        #expect(SessionRuntimeConnections.activeRelaySocket(for: siblingConnection) == relaySocket)

        let relayExecutor = SSHGitExecutor(connection: siblingConnection, omgdPath: omgdStub.path)
        let relayResult = try await relayExecutor.execute(arguments: ["--version"], workingDirectory: root.path)
        #expect(relayResult.isSuccess && relayResult.stdoutString == "ok-inline\n")
        #expect(!FileManager.default.fileExists(atPath: sshLog.path))
        let recordedRelay = try String(contentsOf: omgdLog, encoding: .utf8)
        #expect(recordedRelay.contains("printf '\\036OMG-GIT-v1\\037'"))
        #expect(!recordedRelay.contains("base64 -d"))
        #expect(!recordedRelay.contains("remote/omg"))

        SessionRuntimeConnections.syncInlineRelaySession(old: inlineSession, new: nil)
        #expect(SessionRuntimeConnections.activeRelaySocket(for: connection) == nil)

        let controlSocket = try GitSSHControlSocket.path(for: connection, executablePath: sshStub.path)
        defer { Darwin.unlink(controlSocket) }
        try? FileManager.default.removeItem(atPath: controlSocket)

        let sshExecutor = SSHGitExecutor(connection: connection, sshPath: sshStub.path)
        let sshResult = try await sshExecutor.execute(arguments: ["--version"], workingDirectory: root.path)
        #expect(sshResult.isSuccess && sshResult.stdoutString == "ok-ssh\n")
        let recordedSSH = try String(contentsOf: sshLog, encoding: .utf8)
        #expect(recordedSSH.contains("-o Compression=yes"))
        #expect(recordedSSH.components(separatedBy: "base64 -d").count - 1 == 1)
        #expect(!recordedSSH.contains("remote/omg"))

        try? FileManager.default.removeItem(atPath: controlSocket)
        try Data().write(to: sshLog)
        await SSHSessionTransport.warmControlSocketIfNeeded(connection: connection)
        #expect(FileManager.default.fileExists(atPath: controlSocket))
        let warmupLines = try String(contentsOf: sshLog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(warmupLines.count == 1)
        #expect(warmupLines[0].components(separatedBy: "base64 -d").count - 1 == 1)

        await SSHSessionTransport.warmControlSocketIfNeeded(connection: connection)
        let afterSecondWarmup = try String(contentsOf: sshLog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(afterSecondWarmup.count == 1)
    }
}
