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
    @ObservedObject var settings: OhMyGhosttySettings = .shared
    let surface: Ghostty.SurfaceView

    private var strings: SettingsStrings { .init(language: settings.language) }

    var body: some View {
        if let recovery = controller.pendingSSHRecovery(for: surface) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network.slash").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.sshRecoveryTitle + " · " + recovery.displayDestination)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .help(recovery.remoteWorkingDirectory ?? recovery.displayDestination)
                    Text(strings.sshRecoveryReconnectHelp)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(strings.sshRecoveryReconnect) {
                            controller.reconnectSSH(for: surface)
                        }
                        .buttonStyle(.borderedProminent)
                        .help(strings.sshRecoveryReconnectHelp)
                        Button(strings.sshRecoveryKeepLocal) {
                            controller.dismissSSHRecovery(for: surface)
                        }
                        .help(strings.sshRecoveryKeepLocalHelp)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(10)
            .background(.regularMaterial)
            .accessibilityIdentifier("sshRecoveryBanner")
        }
    }
}
