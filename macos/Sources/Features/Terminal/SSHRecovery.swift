import AppKit
import SwiftUI

extension TerminalController {
    func pendingSSHRecovery(for surface: Ghostty.SurfaceView) -> SSHResumeDescriptor? {
        guard paneSessionContext(for: surface)?.isSSHSession != true,
              let descriptor = surface.sshResumeDescriptor,
              descriptor.isAwaitingReconnect else { return nil }
        return descriptor
    }

    /// Launch through a new PTY, never type commands into a shell that the user
    /// may already be using locally. The old pane keeps its output and processes.
    func reconnectSSH(for surface: Ghostty.SurfaceView) {
        guard let descriptor = pendingSSHRecovery(for: surface),
              let executable = Bundle.main.executablePath,
              let command = descriptor.command(executablePath: executable),
              let appDelegate = NSApp.delegate as? AppDelegate else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = descriptor.localWorkingDirectory
        config.command = Self.replaySurvivalCommand(command)
        guard let controller = Self.newTab(
            appDelegate.ghostty, from: window, withBaseConfig: config
        ), let destination = controller.surfaceTree.first else { return }
        // Seed before lifecycle callbacks: a failed attempt must preserve both
        // cwd and exact conversation even if it never reaches a remote prompt.
        destination.pendingSSHLaunchReplay = descriptor.sshReplay
        controller.adoptSSHRecoveryDescriptor(descriptor, for: destination)
        dismissSSHRecovery(for: surface)
    }
}

struct SSHRecoveryBanner: View {
    @ObservedObject var controller: TerminalController
    let surface: Ghostty.SurfaceView

    var body: some View {
        if let recovery = controller.pendingSSHRecovery(for: surface) {
            HStack(spacing: 8) {
                Image(systemName: "network.slash")
                Text("SSH disconnected · \(recovery.displayDestination)")
                    .lineLimit(1)
                    .help(recovery.remoteWorkingDirectory ?? recovery.displayDestination)
                Spacer(minLength: 0)
                Button("Reconnect in New Tab") { controller.reconnectSSH(for: surface) }
                Button("Keep Local") { controller.dismissSSHRecovery(for: surface) }
            }
            .font(.callout)
            .padding(8)
            .background(.regularMaterial)
            .accessibilityIdentifier("sshRecoveryBanner")
        }
    }
}
