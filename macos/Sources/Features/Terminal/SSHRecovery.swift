import AppKit
import SwiftUI

extension TerminalController {
    func pendingSSHRecovery(for surface: Ghostty.SurfaceView) -> SSHResumeDescriptor? {
        guard paneSessionContext(for: surface)?.isSSHSession != true,
              let descriptor = surface.sshResumeDescriptor,
              descriptor.isAwaitingReconnect else { return nil }
        return descriptor
    }

    /// Replace this pane's PTY with a fresh SSH connection. The user asked for
    /// the current pane explicitly, so interrupted output is intentionally lost.
    func reconnectSSHHere(for surface: Ghostty.SurfaceView) {
        guard let descriptor = pendingSSHRecovery(for: surface),
              let command = Self.sshReplayCommand(descriptor),
              let ghosttyApp = ghostty.app,
              let node = surfaceTree.find(id: surface.id),
              !surfaceTree.contains(where: { $0 !== surface && $0.id == surface.id }) else {
            return
        }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = descriptor.localWorkingDirectory
        config.command = Self.replaySurvivalCommand(command)
        config = Self.injectingSessionID(tabSessionID, into: config)
        let replacement = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
        replacement.sshResumeDescriptor = descriptor
        replacement.pendingSSHLaunchReplay = descriptor.sshReplay
        guard let newTree = try? surfaceTree.replacing(node: node, with: .leaf(view: replacement)) else {
            return
        }
        replaceSurfaceTree(
            newTree,
            moveFocusTo: replacement,
            moveFocusFrom: surface,
            undoAction: nil
        )
        focusedSurface = replacement
        invalidateRestorableState()
    }

    /// Launch through a new PTY, never type commands into a shell that the user
    /// may already be using locally. The old pane keeps its output and processes.
    func reconnectSSH(for surface: Ghostty.SurfaceView) {
        guard let descriptor = pendingSSHRecovery(for: surface),
              let command = Self.sshReplayCommand(descriptor),
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

    private static func sshReplayCommand(_ descriptor: SSHResumeDescriptor) -> String? {
        guard let executable = Bundle.main.executablePath else { return nil }
        return descriptor.command(executablePath: executable)
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
                    HStack(spacing: 6) {
                        Text(strings.sshRecoveryTitle + " · " + recovery.displayDestination)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .help(recovery.remoteWorkingDirectory ?? recovery.displayDestination)
                        Spacer(minLength: 0)
                        Button {
                            controller.dismissSSHRecovery(for: surface)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help(strings.sshRecoveryDismissHelp)
                        .accessibilityLabel(strings.sshRecoveryDismissHelp)
                    }
                    if let agent = recovery.interruptedAgent {
                        Text(strings.sshRecoveryResumesAgent(agent.agent.displayName))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button(strings.sshRecoveryReconnectHere) {
                            controller.reconnectSSHHere(for: surface)
                        }
                        .buttonStyle(.borderedProminent)
                        .help(strings.sshRecoveryReconnectHereHelp)
                        Button(strings.sshRecoveryReconnect) {
                            controller.reconnectSSH(for: surface)
                        }
                        .help(strings.sshRecoveryReconnectHelp)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(.regularMaterial)
            .accessibilityIdentifier("sshRecoveryBanner")
        }
    }
}
