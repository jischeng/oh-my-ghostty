import Foundation
import Testing
@testable import Ghostty

struct WorkspaceProviderTests {
    @Test func parsesSSHConfigAliasesWithoutSecrets() throws {
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

    @Test func createsSSHWorkspaceDescriptorFromAlias() throws {
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
