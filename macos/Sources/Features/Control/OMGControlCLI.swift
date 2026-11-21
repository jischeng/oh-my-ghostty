import Foundation

/// `omg +edit` and `omg +view`: ask the running OMG app to open files in the
/// editor of the pane this command runs in. Handled before AppKit starts; the
/// process talks to the app's control socket and exits.
enum OMGControlCLI {
    enum Command: String, Equatable, Sendable {
        case edit
        case view

        var method: OMGControlProtocol.Method {
            self == .edit ? .editorOpen : .viewerOpen
        }
    }

    struct Invocation: Equatable, Sendable {
        var command: Command
        var paths: [String] = []
        var destination: String?
        var wait = false
        var help = false
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    enum ExitCode {
        static let success: Int32 = 0
        static let failure: Int32 = 1
        static let usage: Int32 = 2
        /// EX_UNAVAILABLE: OMG is not running, or not reachable.
        static let unavailable: Int32 = 69
    }

    static let usage = """
    Usage: omg +edit [options] <path[:line[:column]]>...
           omg +view [options] <path|url>...

    Open files in the OMG editor of the pane this command runs in. +view shows
    Markdown as a preview and opens http(s) links in the default browser.

    Options:
      --split <right|down|left|up>  Open in a new split.
      --tab                         Open in a new tab.
      --current                     Open over the current pane.
      --wait                        +edit only: return once the file is closed,
                                    so EDITOR="omg +edit --wait" works with git.
      --help                        Show this help.

    Without a placement option OMG follows its editor "open files in" setting.

    """

    /// nil when the arguments name no control action, so normal startup and
    /// the other CLI actions proceed untouched.
    static func invocation(arguments: [String]) throws -> Invocation? {
        let actions = arguments.dropFirst().filter { $0.hasPrefix("+") }
        // Two actions are an error the shared CLI already reports.
        guard actions.count == 1, let command = Command(rawValue: String(actions[0].dropFirst())) else {
            return nil
        }
        // `omg -e <command> +edit` runs a command; `+edit` belongs to it.
        if let execute = arguments.firstIndex(of: "-e"), let action = arguments.firstIndex(of: actions[0]),
           execute < action {
            return nil
        }
        var invocation = Invocation(command: command)
        var literal = false
        var pending = arguments.dropFirst().filter { !$0.hasPrefix("+") }[...]
        while let argument = pending.popFirst() {
            if literal || !argument.hasPrefix("-") || argument == "-" {
                invocation.paths.append(argument)
                continue
            }
            switch argument {
            case "--": literal = true
            case "--help", "-h": invocation.help = true
            case "--wait", "-w":
                guard command == .edit else { throw UsageError(message: "--wait applies to +edit only") }
                invocation.wait = true
            case "--tab": invocation.destination = "tab"
            case "--current", "--preview": invocation.destination = "current"
            case "--split":
                guard let direction = pending.popFirst() else {
                    throw UsageError(message: "--split needs right, down, left, or up")
                }
                invocation.destination = try splitDestination(direction)
            default:
                guard argument.hasPrefix("--split=") else {
                    throw UsageError(message: "unknown option \(argument)")
                }
                invocation.destination = try splitDestination(String(argument.dropFirst("--split=".count)))
            }
        }
        guard invocation.help || !invocation.paths.isEmpty else {
            throw UsageError(message: "no file given")
        }
        return invocation
    }

    private static func splitDestination(_ direction: String) throws -> String {
        guard ["right", "down", "left", "up"].contains(direction) else {
            throw UsageError(message: "--split needs right, down, left, or up")
        }
        return direction
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        let report: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        do {
            guard let invocation = try invocation(arguments: arguments) else { return }
            exit(run(
                invocation,
                environment: ProcessInfo.processInfo.environment,
                currentDirectory: FileManager.default.currentDirectoryPath,
                report: report
            ))
        } catch let error as UsageError {
            report("omg: \(error.message)\n\n\(usage)")
            exit(ExitCode.usage)
        } catch {
            exit(ExitCode.usage)
        }
    }

    /// The socket of the app that owns the calling pane; outside a pane, the
    /// socket of this executable's own channel.
    static func socketPath(environment: [String: String]) -> String {
        if let explicit = environment["OMG_CONTROL_SOCKET"], !explicit.isEmpty { return explicit }
        let channel = environment["OH_MY_GHOSTTY_CHANNEL"] ?? OMGApplicationEnvironment.channel()
        return OMGControlSocketPath.path(channel: channel)
    }

    static func request(
        for path: String,
        id: Int,
        invocation: Invocation,
        environment: [String: String],
        currentDirectory: String
    ) -> OMGControlRequest {
        OMGControlRequest(
            id: .number(id),
            method: invocation.command.method.rawValue,
            params: .init(
                path: path,
                cwd: currentDirectory,
                // Runtime-hosted shells started before OMG_PANE_ID existed
                // still carry the same Surface UUID as OMG_SESSION_ID.
                pane: environment[OMGControlService.paneEnvironmentKey] ?? environment["OMG_SESSION_ID"],
                tab: environment["OH_MY_GHOSTTY_SESSION"],
                destination: invocation.destination,
                wait: invocation.wait ? true : nil
            )
        )
    }

    static func run(
        _ invocation: Invocation,
        environment: [String: String],
        currentDirectory: String,
        report: (String) -> Void
    ) -> Int32 {
        if invocation.help {
            FileHandle.standardOutput.write(Data(usage.utf8))
            return ExitCode.success
        }
        let name = "omg +\(invocation.command.rawValue)"
        let path = socketPath(environment: environment)

        // Send every request first so all files open together; with --wait
        // each reply arrives when its file is closed.
        var connections: [Int32] = []
        defer { connections.forEach { close($0) } }
        for (index, file) in invocation.paths.enumerated() {
            guard let fd = OMGControlSocket.connect(path: path), OMGControlSocket.peerIsCurrentUser(fd) else {
                report("\(name): OMG is not running, or its control socket is unavailable (\(path))")
                return ExitCode.unavailable
            }
            connections.append(fd)
            let request = request(
                for: file, id: index + 1, invocation: invocation,
                environment: environment, currentDirectory: currentDirectory
            )
            guard let frame = try? request.frame(), OMGControlSocket.writeAll(fd, frame + [0x0A]) else {
                report("\(name): could not send the request for \(file)")
                return ExitCode.failure
            }
        }

        var status = ExitCode.success
        for (fd, file) in zip(connections, invocation.paths) {
            guard let frame = readFrame(fd),
                  let response = try? JSONDecoder().decode(OMGControlResponse.self, from: frame) else {
                report("\(name): OMG closed the connection before answering for \(file)")
                status = ExitCode.failure
                continue
            }
            if let error = response.error {
                report("\(name): \(error.message)")
                status = ExitCode.failure
            }
        }
        return status
    }

    /// Blocks until one newline-terminated frame arrives.
    static func readFrame(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) { return Data(buffer[buffer.startIndex..<newline]) }
            guard buffer.count <= OMGControlProtocol.maximumFrameBytes else { return nil }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}
