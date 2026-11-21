import Foundation
import Testing
@testable import Ghostty

struct OMGControlProtocolTests {
    @Test func socketPathIsChannelIsolatedAndFallsBackForLongHomes() {
        let base = URL(fileURLWithPath: "/Users/dev/Library/Application Support")
        #expect(OMGControlSocketPath.path(channel: "release", applicationSupportBase: base, uid: 501) ==
            "/Users/dev/Library/Application Support/OMG/control/v1.sock")
        #expect(OMGControlSocketPath.path(channel: "debug", applicationSupportBase: base, uid: 501) ==
            "/Users/dev/Library/Application Support/OMG Dev/control/v1.sock")
        #expect(OMGControlSocketPath.path(channel: "debug-workspace", applicationSupportBase: base, uid: 501) ==
            "/Users/dev/Library/Application Support/OMG Dev Workspace/control/v1.sock")
        #expect(OMGControlSocketPath.path(channel: "debug-pty", applicationSupportBase: base, uid: 501) ==
            "/Users/dev/Library/Application Support/OMG Dev PTY/control/v1.sock")
        // An unknown channel never invents a directory.
        #expect(OMGControlSocketPath.path(channel: "../evil", applicationSupportBase: base, uid: 501) ==
            "/Users/dev/Library/Application Support/OMG/control/v1.sock")

        // sun_path cannot hold this one, so both ends use the /tmp path.
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 70) + "/Library/Application Support")
        let fallback = OMGControlSocketPath.path(channel: "debug-workspace", applicationSupportBase: long, uid: 501)
        #expect(fallback == "/tmp/omg-control-501-debug-workspace/v1.sock")
        #expect(OMGControlSocket.address(path: fallback) != nil)
        #expect(OMGControlSocket.address(path: long.path + "/OMG/control/v1.sock") == nil)

        // The table mirrors the app's own Application Support directory.
        let own = OMGControlSocketPath.path()
        #expect(own.hasPrefix(OMGApplicationEnvironment.applicationSupportURL().path + "/control/") ||
            own.hasPrefix("/tmp/omg-control-"))
    }

    @Test func framerSplitsLinesAndRefusesOversizedFrames() throws {
        var framer = OMGControlLineFramer()
        let first = try framer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        let second = try framer.append(Data(":2}\n\n".utf8))
        #expect(first == [Data("{\"a\":1}".utf8)])
        #expect(second == [Data("{\"b\":2}".utf8)])

        var oversized = OMGControlLineFramer()
        let atLimit = try oversized.append(Data(repeating: 0x61, count: OMGControlProtocol.maximumFrameBytes))
        #expect(atLimit.isEmpty)
        var refused = false
        do { _ = try oversized.append(Data([0x61])) } catch is OMGControlFrame.TooLarge { refused = true }
        #expect(refused)
    }

    @Test func requestsRoundTripAndBadFramesGetJSONRPCErrors() throws {
        let request = OMGControlRequest(
            id: .number(7),
            method: "editor.open",
            params: .init(path: "a \"b\"\n.txt:3", cwd: "/tmp", pane: "P", tab: nil, destination: "right", wait: true)
        )
        let frame = try request.frame()
        #expect(!frame.contains(0x0A))
        #expect(try OMGControlFrame.decodeRequest(frame).get() == request)

        func failure(_ json: String) -> OMGControlResponse? {
            if case .failure(let response) = OMGControlFrame.decodeRequest(Data(json.utf8)) { return response }
            return nil
        }
        #expect(failure("not json")?.error?.code == -32_700)
        #expect(failure(#"{"jsonrpc":"1.0","id":1,"method":"editor.open"}"#)?.error?.code == -32_600)
        #expect(failure(#"{"jsonrpc":"2.0","method":"editor.open"}"#)?.error?.code == -32_600)
        let unknown = failure(#"{"jsonrpc":"2.0","id":"x","method":"pane.send_text","params":{}}"#)
        #expect(unknown?.error?.code == -32_601)
        #expect(unknown?.id == .string("x"))
        #expect(failure(#"{"jsonrpc":"2.0","id":1,"method":"editor.open","params":{"path":1}}"#)?.error?.code == -32_602)

        let response = OMGControlResponse.success(.number(7), ["status": "opened"])
        #expect(try JSONDecoder().decode(OMGControlResponse.self, from: response.frame()) == response)
    }

    @Test func openRequestValidatesAndResolvesAgainstTheCallerDirectory() throws {
        func params(_ path: String, cwd: String = "/work/repo", destination: String? = nil,
                    wait: Bool? = nil, pane: String? = nil) -> OMGControlOpenParams {
            .init(path: path, cwd: cwd, pane: pane, tab: nil, destination: destination, wait: wait)
        }
        let pane = UUID()
        let edit = try OMGControlOpenRequest(
            method: .editorOpen,
            params: params("src/main.swift:12:4", destination: "down", wait: true, pane: pane.uuidString)
        )
        #expect(edit.target == .file(path: "/work/repo/src/main.swift", location: .init(startLine: 12, column: 4)))
        #expect(edit.destination == .splitDown)
        #expect(edit.wait && edit.createsMissingFile)
        #expect(edit.pane == pane)

        // Viewing never waits or creates, and a stale pane ID is ignored.
        let view = try OMGControlOpenRequest(method: .viewerOpen, params: params("/abs/README.md", wait: true, pane: "stale"))
        #expect(view.target == .file(path: "/abs/README.md", location: nil))
        #expect(!view.wait && !view.createsMissingFile && view.pane == nil && view.destination == nil)

        // Only the viewer takes links; the editor treats one as a bad path.
        #expect(try OMGControlOpenRequest(method: .viewerOpen, params: params("https://example.com/a")).target ==
            .url("https://example.com/a"))
        #expect(throws: OMGControlError.self) {
            try OMGControlOpenRequest(method: .editorOpen, params: params("https://example.com/a"))
        }
        #expect(throws: OMGControlError.self) {
            try OMGControlOpenRequest(method: .editorOpen, params: params("a.txt", cwd: "relative"))
        }
        #expect(throws: OMGControlError.self) {
            try OMGControlOpenRequest(method: .editorOpen, params: params("a.txt", destination: "sideways"))
        }
        #expect(throws: OMGControlError.self) {
            try OMGControlOpenRequest(method: .editorOpen, params: params(""))
        }
    }
}

struct OMGControlCLITests {
    @Test func parsesEditAndViewArguments() throws {
        func parse(_ arguments: String...) throws -> OMGControlCLI.Invocation? {
            try OMGControlCLI.invocation(arguments: ["omg"] + arguments)
        }
        #expect(try parse() == nil)
        #expect(try parse("+ssh", "host") == nil)
        #expect(try parse("+edit", "+view", "a") == nil)
        // `omg -e vim +edit` launches vim; the action is vim's argument.
        #expect(try parse("-e", "vim", "+edit", "a") == nil)

        #expect(try parse("+edit", "a.txt") == .init(command: .edit, paths: ["a.txt"]))
        #expect(try parse("+edit", "--wait", "--split", "right", "a.txt:3", "b") ==
            .init(command: .edit, paths: ["a.txt:3", "b"], destination: "right", wait: true))
        #expect(try parse("--split=down", "+view", "README.md") ==
            .init(command: .view, paths: ["README.md"], destination: "down"))
        #expect(try parse("+view", "--tab", "x")?.destination == "tab")
        #expect(try parse("+view", "--preview", "x")?.destination == "current")
        #expect(try parse("+edit", "--current", "--", "--odd-name")?.paths == ["--odd-name"])
        #expect(try parse("+edit", "--help")?.help == true)

        #expect(throws: OMGControlCLI.UsageError.self) { try parse("+edit") }
        #expect(throws: OMGControlCLI.UsageError.self) { try parse("+view", "--wait", "x") }
        #expect(throws: OMGControlCLI.UsageError.self) { try parse("+edit", "--split", "sideways", "x") }
        #expect(throws: OMGControlCLI.UsageError.self) { try parse("+edit", "--split") }
        #expect(throws: OMGControlCLI.UsageError.self) { try parse("+edit", "--bogus", "x") }
    }

    @Test func requestCarriesThePaneIdentityFromTheEnvironment() {
        let invocation = OMGControlCLI.Invocation(command: .edit, paths: ["a"], destination: "tab", wait: true)
        let request = OMGControlCLI.request(
            for: "a", id: 2, invocation: invocation,
            environment: ["OMG_PANE_ID": "PANE", "OMG_SESSION_ID": "runtime", "OH_MY_GHOSTTY_SESSION": "TAB"],
            currentDirectory: "/work"
        )
        #expect(request == .init(id: .number(2), method: "editor.open", params: .init(
            path: "a", cwd: "/work", pane: "PANE", tab: "TAB", destination: "tab", wait: true
        )))
        // A runtime-hosted shell from before OMG_PANE_ID still names its pane.
        let legacy = OMGControlCLI.request(
            for: "a", id: 1, invocation: .init(command: .view, paths: ["a"]),
            environment: ["OMG_SESSION_ID": "runtime"], currentDirectory: "/work"
        )
        #expect(legacy.method == "viewer.open")
        #expect(legacy.params.pane == "runtime" && legacy.params.tab == nil && legacy.params.wait == nil)

        // The pane's channel picks the socket, so a Dev pane reaches OMG Dev.
        #expect(OMGControlCLI.socketPath(environment: ["OMG_CONTROL_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(OMGControlCLI.socketPath(environment: ["OH_MY_GHOSTTY_CHANNEL": "debug"]) ==
            OMGControlSocketPath.path(channel: "debug"))
    }

    @Test func surfaceConfigurationNamesItsPane() {
        var configuration = Ghostty.SurfaceConfiguration()
        let pane = UUID()
        OMGControlService.configure(&configuration, pane: pane)
        #expect(configuration.environmentVariables["OMG_PANE_ID"] == pane.uuidString)
    }
}

/// End-to-end over a real socket: the CLI client against the app's listener
/// and service, with the editor replaced by a recording opener.
@MainActor
struct OMGControlServiceTests {
    /// macOS temporary directories are long; keep the socket inside sun_path.
    private func socketDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/omg-ct-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func runCLI(_ invocation: OMGControlCLI.Invocation, socket: String,
                        environment: [String: String] = [:]) async -> (status: Int32, errors: [String]) {
        var environment = environment
        environment["OMG_CONTROL_SOCKET"] = socket
        let captured = environment
        return await Task.detached {
            var errors: [String] = []
            let status = OMGControlCLI.run(invocation, environment: captured, currentDirectory: "/work") {
                errors.append($0)
            }
            return (status, errors)
        }.value
    }

    @Test func clientReachesTheServiceAndReportsItsAnswer() async throws {
        let directory = try socketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("v1.sock").path
        var requests: [OMGControlOpenRequest] = []
        let service = OMGControlService { request in
            requests.append(request)
            if case .file(let path, _) = request.target, path.hasSuffix("missing.txt") {
                return .failure(.failed("No such file: \(path)"))
            }
            return .success(.external(path: "/work/a.txt"))
        }
        service.start(path: socket)
        defer { service.stop() }

        var attributes = stat()
        #expect(lstat(socket, &attributes) == 0)
        #expect(attributes.st_mode & S_IFMT == S_IFSOCK && attributes.st_mode & 0o777 == 0o600)

        let pane = UUID()
        let opened = await runCLI(
            .init(command: .edit, paths: ["a.txt:5", "b.txt"], destination: "right"),
            socket: socket, environment: ["OMG_PANE_ID": pane.uuidString]
        )
        #expect(opened.status == 0 && opened.errors.isEmpty)
        #expect(requests.count == 2)
        #expect(requests.contains { $0.target == .file(path: "/work/a.txt", location: .init(startLine: 5)) })
        #expect(requests.contains { $0.target == .file(path: "/work/b.txt", location: nil) })
        #expect(requests.allSatisfy { $0.pane == pane && $0.destination == .splitRight && !$0.wait })

        let failed = await runCLI(.init(command: .view, paths: ["missing.txt"]), socket: socket)
        #expect(failed.status == 1)
        #expect(failed.errors == ["omg +view: No such file: /work/missing.txt"])

        // Nothing listening is reported as unavailable, not as a file error.
        service.stop()
        let offline = await runCLI(.init(command: .edit, paths: ["a.txt"]), socket: socket)
        #expect(offline.status == 69)
        #expect(lstat(socket, &attributes) != 0)
    }

    @Test func serverKeepsALiveSocketAndReplacesAStaleOne() throws {
        let directory = try socketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("v1.sock").path
        let first = OMGControlServer()
        try first.start(path: socket) { _, _ in }
        // A second instance of the channel must not steal the first one's socket.
        let second = OMGControlServer()
        #expect(throws: OMGControlServer.Failure.alreadyListening) {
            try second.start(path: socket) { _, _ in }
        }
        #expect(OMGControlSocket.connect(path: socket).map { close($0) } != nil)

        // A crash leaves the file behind with nobody listening; it is replaced.
        first.stop()
        let stale = try #require(OMGControlSocket.address(path: socket))
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = stale
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        #expect(bound == 0)
        #expect(OMGControlSocket.connect(path: socket) == nil)
        try second.start(path: socket) { _, _ in }
        defer { second.stop() }
        #expect(OMGControlSocket.connect(path: socket).map { close($0) } != nil)

        // A directory other users can enter is refused outright.
        let open = try socketDirectory()
        defer { try? FileManager.default.removeItem(at: open) }
        #expect(chmod(open.path, 0o755) == 0)
        #expect(throws: OMGControlServer.Failure.notPrivate) {
            try OMGControlServer().start(path: open.appendingPathComponent("v1.sock").path) { _, _ in }
        }
    }

    @Test func serverAnswersMalformedFramesAndDropsOversizedOnes() async throws {
        let directory = try socketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("v1.sock").path
        let service = OMGControlService { _ in .success(.url) }
        service.start(path: socket)
        defer { service.stop() }

        let reply = await Task.detached { () -> OMGControlResponse? in
            guard let fd = OMGControlSocket.connect(path: socket) else { return nil }
            defer { close(fd) }
            guard OMGControlSocket.writeAll(fd, Data("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope\"}\n".utf8)),
                  let frame = OMGControlCLI.readFrame(fd) else { return nil }
            return try? JSONDecoder().decode(OMGControlResponse.self, from: frame)
        }.value
        #expect(reply?.error?.code == -32_601)
        #expect(reply?.id == .number(3))

        // A frame past the limit closes the connection without an answer.
        let dropped = await Task.detached { () -> Bool in
            guard let fd = OMGControlSocket.connect(path: socket) else { return false }
            defer { close(fd) }
            let flood = Data(repeating: 0x61, count: OMGControlProtocol.maximumFrameBytes + 2)
            _ = OMGControlSocket.writeAll(fd, flood)
            return OMGControlCLI.readFrame(fd) == nil
        }.value
        #expect(dropped)
    }

    @Test func waitRepliesOnlyAfterTheDocumentCloses() async throws {
        let directory = try socketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("v1.sock").path
        let file = directory.appendingPathComponent("COMMIT_EDITMSG")
        try Data("message\n".utf8).write(to: file)

        let filesystem = LocalWorkspaceFilesystem(workingDirectory: directory.path)
        let workspace = EditorWorkspace()
        defer { workspace.cancelAndClear() }
        workspace.open(path: file.path, filesystem: filesystem)
        for _ in 0..<200 where workspace.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let document = try #require(workspace.documents.first)

        let service = OMGControlService { _ in .success(.document(workspace: workspace, id: document.id)) }
        service.start(path: socket)
        defer { service.stop() }

        let waiting = Task { await runCLI(.init(command: .edit, paths: [file.path], wait: true), socket: socket) }
        for _ in 0..<200 where service.waiterCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(service.waiterCount == 1)

        // A client that gives up stops being waited for.
        let abandoned = try #require(OMGControlSocket.connect(path: socket))
        let request = OMGControlRequest(id: .number(9), method: "editor.open",
                                        params: .init(path: file.path, cwd: "/work", wait: true))
        #expect(OMGControlSocket.writeAll(abandoned, try request.frame() + [0x0A]))
        for _ in 0..<200 where service.waiterCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(service.waiterCount == 2)
        close(abandoned)
        for _ in 0..<200 where service.waiterCount > 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(service.waiterCount == 1)

        workspace.remove(document)
        let result = await waiting.value
        #expect(result.status == 0 && result.errors.isEmpty)
        #expect(service.waiterCount == 0)
    }
}
