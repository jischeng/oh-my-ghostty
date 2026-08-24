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

    @Test func resolvesSSHWorkspaceFromTerminalTitle() throws {
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
        let hosts = SSHPlugin.configurations(at: url)
        let workspace = SSHPlugin.workspace(
            forTitle: "json@cloud: ~/project",
            workingDirectory: "/home/json/project",
            configurations: hosts
        )
        #expect(workspace?.displayName == "cloud")
        #expect(workspace?.presentationTitle == "☁ cloud /home/json/project")
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
