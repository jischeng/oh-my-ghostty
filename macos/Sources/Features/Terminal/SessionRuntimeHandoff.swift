import AppKit

/// A terminal OSC only names a private request file. It never carries a command
/// or authority: the request must match this local pane's random capability.
@MainActor
final class SessionRuntimeHandoff {
    static let shared = SessionRuntimeHandoff()
    private var tokens: [UUID: String] = [:]
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omg-ssh-handoff-" + UUID().uuidString)

    func configure(_ config: inout Ghostty.SurfaceConfiguration, pane: UUID) {
        guard config.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil else { return }
        let helper = SessionRuntimeConnections.resources.appendingPathComponent("omgd")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let token = UUID().uuidString + UUID().uuidString
            tokens[pane] = token
            config.environmentVariables["OMG_SSH_HANDOFF_HELPER"] = helper.path
            config.environmentVariables["OMG_SSH_HANDOFF_DIRECTORY"] = directory.path
            config.environmentVariables["OMG_SSH_HANDOFF_TOKEN"] = token
        } catch { Ghostty.logger.error("Could not prepare native SSH handoff") }
    }

    func accept(_ signal: Ghostty.ContextSignal, source: Ghostty.SurfaceView, controller: TerminalController) -> Bool {
        let prefix = "omg-runtime-request-"
        guard signal.id.hasPrefix(prefix) else { return false }
        guard source.runtimeDescriptor == nil, signal.action == .start else { return true }
        let name = String(signal.id.dropFirst(prefix.count))
        guard name.count == 32, name.allSatisfy(\.isHexDigit) else { return true }
        let file = directory.appendingPathComponent(name + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        struct Request: Decodable { let token: String; let ssh: String; let args: [String]; let cwd: String }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 65536 else { return true }
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: file))
            guard request.token == tokens[source.id], let parsed = OpenSSHArguments(request.args),
                  let destination = parsed.interactiveDestination,
                  let executable = SSHProcessArguments.executablePath(for: request.ssh, workingDirectory: request.cwd) else { return true }
            let connection = try GitSSHConnection(destination: destination, options: parsed.options.flatMap(\.arguments),
                executablePath: executable, localWorkingDirectory: request.cwd)
            let descriptor = try SessionRuntimeConnections.descriptor(connection: connection, policy: OhMyGhosttySettings.shared.runtimePolicy)
            guard let app = controller.ghostty.app, let node = controller.surfaceTree.find(id: source.id) else { return true }
            var config = Ghostty.SurfaceConfiguration()
            try descriptor.configure(&config)
            let replacement = Ghostty.SurfaceView(app, baseConfig: config)
            let tree = try controller.surfaceTree.replacing(node: node, with: .leaf(view: replacement))
            controller.replaceSurfaceTree(tree, moveFocusTo: replacement, moveFocusFrom: source, undoAction: nil)
            controller.focusedSurface = replacement
            controller.invalidateRestorableState()
            tokens.removeValue(forKey: source.id)
        } catch { Ghostty.logger.error("Native SSH handoff failed: \(error.localizedDescription, privacy: .public)") }
        return true
    }
}
