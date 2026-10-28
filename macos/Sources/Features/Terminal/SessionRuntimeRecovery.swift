import SwiftUI

extension TerminalController {
    /// Recreate only the SSH relay and attach the same remote Session ID.
    /// A fresh local PTY is never used as a tmux/attach wrapper.
    func reconnectRuntimeHere(for surface: Ghostty.SurfaceView) {
        guard let descriptor = surface.runtimeDescriptor,
              let app = ghostty.app,
              let node = surfaceTree.find(id: surface.id) else { return }
        SessionRuntimeConnections.shared.invalidate(descriptor)
        var config = Ghostty.SurfaceConfiguration()
        do { try descriptor.configure(&config) } catch { return }
        let replacement = Ghostty.SurfaceView(app, baseConfig: config)
        replacement.runtimeLocalSurface = surface.runtimeLocalSurface
        replacement.runtimeLocalCompletion = surface.runtimeLocalCompletion
        guard let tree = try? surfaceTree.replacing(node: node, with: .leaf(view: replacement)) else { return }
        replaceSurfaceTree(tree, moveFocusTo: replacement, moveFocusFrom: surface, undoAction: nil)
        focusedSurface = replacement
        invalidateRestorableState()
    }
}

struct SessionRuntimeRecoveryBanner: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var settings = OhMyGhosttySettings.shared
    let surface: Ghostty.SurfaceView

    var body: some View {
        if surface.runtimeDisconnected, let descriptor = surface.runtimeDescriptor {
            let strings = SettingsStrings(language: settings.language)
            HStack(spacing: 10) {
                Image(systemName: "network.slash").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.sshRecoveryTitle + " · " + descriptor.connection.displayEndpoint)
                        .fontWeight(.medium).lineLimit(1)
                    Text(strings.sshRecoveryReconnectHereHelp)
                        .font(.caption).foregroundStyle(.secondary)
                    Button(strings.sshRecoveryReconnectHere) {
                        controller.reconnectRuntimeHere(for: surface)
                    }.buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
