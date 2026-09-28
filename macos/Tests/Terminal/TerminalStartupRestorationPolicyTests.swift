import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalStartupRestorationPolicyTests {
    @Test func layoutOnlyRestoresCustomCommandWindowsAsFreshShells() {
        #expect(TerminalController.canRestoreWindow(customCommand: true,
            mode: .restoreTabs, hasResumeDescriptor: false))
        #expect(!TerminalController.canRestoreWindow(customCommand: true,
            mode: .restoreSessions, hasResumeDescriptor: false))
        #expect(TerminalController.canRestoreWindow(customCommand: true,
            mode: .restoreSessions, hasResumeDescriptor: true))
        #expect(TerminalController.canRestoreWindow(customCommand: false,
            mode: .restoreSessions, hasResumeDescriptor: false))
    }

    @Test func tabOnlyModeUsesLocalDirectoryInsteadOfRemotePWD() {
        let ssh = SSHResumeDescriptor(
            sshReplay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
                             terminfo: false, cache: false, args: ["cloud"]),
            remoteWorkingDirectory: "/remote/project",
            localWorkingDirectory: "/Users/test/code"
        )
        #expect(TerminalStartupRestorationPolicy.localWorkingDirectory(
            saved: "/remote/project", agent: nil, ssh: ssh
        ) == "/Users/test/code")
        let remoteAgent = AgentResumeDescriptor(agent: .pi, scope: .remote,
            workingDirectory: "/remote/project", sshReplay: ssh.sshReplay)
        #expect(TerminalStartupRestorationPolicy.localWorkingDirectory(
            saved: "/remote/project", agent: remoteAgent, ssh: nil
        ) == nil)
        let localAgent = AgentResumeDescriptor(agent: .pi, scope: .local,
            workingDirectory: "/Users/test/agent")
        #expect(TerminalStartupRestorationPolicy.localWorkingDirectory(
            saved: "/Users/test/shell", agent: localAgent, ssh: nil
        ) == "/Users/test/agent")
        #expect(TerminalStartupRestorationPolicy.localWorkingDirectory(
            saved: "/Users/test/shell", agent: nil, ssh: nil
        ) == "/Users/test/shell")
    }
}
