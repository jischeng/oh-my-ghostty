import Foundation
import Testing
@testable import Ghostty

struct WorkspaceProviderTests {
    @Test func parsesSSHConfigAliasesWithoutSecrets() throws {
        let previous = UserDefaults.standard.object(forKey: "OMG.Plugin.Enabled.builtin.ssh")
        UserDefaults.standard.set(true, forKey: "OMG.Plugin.Enabled.builtin.ssh")
        defer { UserDefaults.standard.set(previous, forKey: "OMG.Plugin.Enabled.builtin.ssh") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        Host cloud
            HostName 10.0.0.12
            User json
            Port 22
            IdentityFile ~/.ssh/id_ed25519

        Host *.example.com
            HostName ignored.example.com
        """.write(to: url, atomically: true, encoding: .utf8)

        let hosts = SSHPlugin.configurations(at: url)
        #expect(hosts == [
            .init(
                alias: "cloud",
                hostname: "10.0.0.12",
                user: "json",
                port: 22,
                proxyJump: nil
            ),
        ])
        #expect(hosts.first?.workspaceID == "ssh:cloud")
    }

    @Test func createsGenericLocalWorkspaceDescriptor() {
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: "/tmp/project")
        #expect(filesystem.descriptor.kind == .local)
        #expect(filesystem.descriptor.workingDirectory == "/tmp/project")
    }

    @Test func paneSessionLifecycleRestoresLocalContextOnDisconnect() {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "~/code"
        )
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "~/code"
        )
        guard case .sshConnecting(let connecting) = context.state else {
            Issue.record("Expected an SSH connecting context")
            return
        }
        #expect(connecting.alias == "cloud")
        #expect(context.workingDirectory == "/Users/test/code")
        #expect(context.presentationTitle == "~/code")
        #expect(context.tabIconSystemName == "terminal")

        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/tmp"
            ),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "remote title"
        )
        guard case .sshReady(let ready, let remoteCWD) = context.state else {
            Issue.record("Expected an SSH ready context")
            return
        }
        #expect(ready.alias == "cloud")
        #expect(remoteCWD == "/tmp")
        #expect(context.presentationTitle == "cloud /tmp")
        #expect(context.tabIconSystemName == "cloud")

        context.apply(
            .init(
                action: .end,
                id: "omg-ssh-1",
                metadata: "exit=success;status=0;cwd=/Users/test/code"
            ),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "remote title"
        )
        #expect(context.state == .local)
        #expect(context.workingDirectory == "/Users/test/code")
        #expect(context.presentationTitle == "~/code")
        #expect(context.tabIconSystemName == "terminal")

        context.updateLocalMetadata(
            workingDirectory: "/Users/test/code",
            terminalTitle: "remote title"
        )
        #expect(context.presentationTitle == "~/code")
        context.updateLocalMetadata(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        #expect(context.presentationTitle == "code")
    }

    @Test func staleSSHDisconnectCannotClearNewConnection() {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        for (id, alias) in [("omg-ssh-a", "cloud"), ("omg-ssh-b", "build")] {
            context.apply(
                .init(
                    action: .start,
                    id: id,
                    metadata: "type=remote;targethost=\(alias);cwd=/tmp"
                ),
                currentWorkingDirectory: "/tmp",
                currentTerminalTitle: alias
            )
        }
        context.apply(
            .init(action: .end, id: "omg-ssh-a", metadata: "status=255"),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "cloud"
        )
        guard case .sshReady(let active, _) = context.state else {
            Issue.record("Expected the newer SSH connection to remain active")
            return
        }
        #expect(active.connectionID == "omg-ssh-b")
        #expect(active.alias == "build")
    }

    @Test func unresolvedReadySSHNeverFallsBackToLocalFilesystem() {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=missing-host;cwd=/remote/path"
            ),
            currentWorkingDirectory: "/remote/path",
            currentTerminalTitle: "remote"
        )
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            session: session
        )
        let filesystem = WorkspaceFilesystemFactory.make(for: context)
        #expect(filesystem.descriptor.kind == .ssh)
        #expect(filesystem.descriptor.workingDirectory == "/remote/path")
    }

    @Test func tabPathDisplayIsSharedByLocalAndSSHContexts() {
        var local = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "~/code"
        )
        #expect(local.presentationTitle(pathDisplay: .fullPath) == "~/code")
        #expect(local.presentationTitle(pathDisplay: .folderName) == "code")
        #expect(local.agentPathTitle(pathDisplay: .fullPath) == "/Users/test/code")
        #expect(local.agentPathTitle(pathDisplay: .folderName) == "code")

        local.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/home/test/project/omg"
            ),
            currentWorkingDirectory: "/home/test/project/omg",
            currentTerminalTitle: "remote"
        )
        #expect(
            local.presentationTitle(pathDisplay: .fullPath) ==
                "cloud /home/test/project/omg"
        )
        #expect(local.presentationTitle(pathDisplay: .folderName) == "cloud omg")
        #expect(
            local.agentPathTitle(pathDisplay: .fullPath) ==
                "cloud /home/test/project/omg"
        )
        #expect(local.agentPathTitle(pathDisplay: .folderName) == "cloud omg")
    }

    @Test func folderDisplayNameIsSharedByLocalAndRemoteFiles() {
        #expect(WorkspacePathPresentation.folderName("/Users/test/code") == "code")
        #expect(WorkspacePathPresentation.folderName("/home/test/project/omg") == "omg")
        #expect(WorkspacePathPresentation.folderName("/") == "/")
    }

    @Test func sshReplayDescriptorPreservesExactArgumentsAndQuotesCommand() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let connectionID = "omg-ssh-123"
        let url = try #require(SSHReplayStore.url(
            for: connectionID,
            applicationSupportURL: support
        ))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: true,
            terminfo: false,
            cache: true,
            args: ["-J", "jump host", "user@cloud", "quote'arg"]
        )
        try JSONEncoder().encode(descriptor).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        let restored = try #require(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support
        ))
        #expect(restored == descriptor)
        let command = try #require(restored.command(
            executablePath: "/Applications/OMG Dev.app/Contents/MacOS/omg"
        ))
        #expect(command.contains("'+ssh'"))
        #expect(command.contains("'--ssh=/usr/bin/ssh'"))
        #expect(command.contains("'jump host'"))
        #expect(command.contains("'quote'\\''arg'"))
        #expect(command.hasSuffix("'quote'\\''arg'"))

        let cwdCommand = try #require(restored.command(
            executablePath: "/Applications/OMG Dev.app/Contents/MacOS/omg",
            remoteWorkingDirectory: "/home/test/project's code"
        ))
        #expect(cwdCommand.contains(
            "'--remote-working-directory=/home/test/project'\\''s code'"
        ))
    }

    @Test func sshReplayStoreRejectsInvalidOrStaleDescriptors() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(SSHReplayStore.url(
            for: "../../escape",
            applicationSupportURL: support
        ) == nil)

        let connectionID = "omg-ssh-stale"
        let url = try #require(SSHReplayStore.url(
            for: connectionID,
            applicationSupportURL: support
        ))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = SSHReplayDescriptor(
            version: 1,
            ssh: "ssh",
            forwardEnv: true,
            terminfo: true,
            cache: true,
            args: ["cloud"]
        )
        try JSONEncoder().encode(descriptor).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let tomorrow = Date().addingTimeInterval(25 * 60 * 60)
        #expect(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support,
            now: tomorrow
        ) == nil)
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date(),
                .posixPermissions: 0o644,
            ],
            ofItemAtPath: url.path
        )
        #expect(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support
        ) == nil)
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date().addingTimeInterval(10 * 60),
                .posixPermissions: 0o600,
            ],
            ofItemAtPath: url.path
        )
        #expect(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support
        ) == nil)
    }

    @Test func boundsLargeSFTPDirectoryListings() throws {
        let output = (0..<800).map { index in
            "-rw-r--r-- 1 user group 1 Jan 1 00:00 file-\(index)"
        }.joined(separator: "\n")
        let entries = try SSHWorkspaceFilesystem.parseLongListing(
            output,
            directory: "/remote"
        )
        #expect(entries.count == 500)
        #expect(entries.allSatisfy { $0.path.hasPrefix("/remote/") })
    }

    @Test func createsSSHWorkspaceDescriptorFromAlias() throws {
        let previous = UserDefaults.standard.object(forKey: "OMG.Plugin.Enabled.builtin.ssh")
        UserDefaults.standard.set(true, forKey: "OMG.Plugin.Enabled.builtin.ssh")
        defer { UserDefaults.standard.set(previous, forKey: "OMG.Plugin.Enabled.builtin.ssh") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        Host cloud
            HostName 10.0.0.12
            User json
        """.write(to: url, atomically: true, encoding: .utf8)
        let configuration = try #require(SSHPlugin.configurations(at: url).first)
        let filesystem = SSHWorkspaceFilesystem(
            host: configuration,
            workingDirectory: "/home/json/project"
        )
        #expect(filesystem.descriptor.kind == .ssh)
        #expect(filesystem.descriptor.id == "ssh:cloud")
        #expect(filesystem.descriptor.displayName == "cloud")
    }
}
