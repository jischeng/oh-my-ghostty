import Foundation

/// Restoring a tab is not the same as relaunching its foreground process.
/// Never use a remote path as the cwd of a fresh local Shell.
enum TerminalStartupRestorationPolicy {
    static func localWorkingDirectory(
        saved: String?, agent: AgentResumeDescriptor?, ssh: SSHResumeDescriptor?
    ) -> String? {
        if let ssh { return ssh.localWorkingDirectory }
        if let agent {
            switch agent.scope {
            case .local: return agent.workingDirectory ?? saved
            case .remote: return agent.sshReplay?.localWorkingDirectory
            }
        }
        return saved
    }
}
