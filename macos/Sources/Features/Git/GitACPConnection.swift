import Foundation

/// ACP uses one JSON-RPC object per LF-delimited line, not LSP Content-Length frames.
actor GitACPConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writer = DispatchQueue(label: "omg.commit.acp.stdin")
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 0
    private var closed = false
    private var text = ""
    private var activeSession: String?
    private var outputOverflow = false

    func start(executable: String, arguments: [String], cwd: URL, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in Task { await self?.stop() } }
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let stream = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? stream.close() }
            var buffer = Data()
            while true {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(stream.fileDescriptor, &bytes, bytes.count)
                if count <= 0 { break }
                buffer.append(contentsOf: bytes.prefix(count))
                if buffer.count > 2_000_000 { break }
                while let newline = buffer.firstIndex(of: 10) {
                    let frame = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    // Serial FIFO delivery prevents the final response overtaking text chunks.
                    let semaphore = DispatchSemaphore(value: 0)
                    Task { await self?.receive(frame); semaphore.signal() }
                    semaphore.wait()
                }
            }
            Task { await self?.stop() }
        }
        let stderr = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            defer { try? stderr.close() }
            // Drain but never retain diagnostics: agents may echo source or credentials.
            var bytes = [UInt8](repeating: 0, count: 8192)
            while Darwin.read(stderr.fileDescriptor, &bytes, bytes.count) > 0 {}
        }
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 25) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw GitCommitAIError("ACP connection closed. Check the adapter installation and login.") }
        nextID += 1
        let id = nextID
        let frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self.stop()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                let handle = input.fileHandleForWriting
                let bytes = frame + Data([10])
                writer.async { [weak self] in
                    do { try handle.write(contentsOf: bytes) } catch { Task { await self?.stop() } }
                }
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    func prompt(session: String, text prompt: String) async throws -> String {
        text = ""
        outputOverflow = false
        activeSession = session
        defer { activeSession = nil }
        let response = try await request("session/prompt", params: [
            "sessionId": session, "prompt": [["type": "text", "text": prompt]]
        ], timeout: 90)
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        guard object?["stopReason"] as? String == "end_turn", !outputOverflow,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitCommitAIError("The agent did not return a successful final response.")
        }
        return text
    }

    private func send(_ data: Data) throws {
        var line = data
        line.append(10)
        let handle = input.fileHandleForWriting
        let bytes = line
        writer.async { [weak self] in
            do { try handle.write(contentsOf: bytes) } catch { Task { await self?.stop() } }
        }
    }

    private func receive(_ data: Data) {
        guard !closed, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = object["id"] {
                // No filesystem or terminal capabilities are advertised or serviced.
                let reply: [String: Any]
                if method == "session/request_permission" {
                    reply = ["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]]
                } else {
                    reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Client capability unavailable"]]
                }
                if let encoded = try? JSONSerialization.data(withJSONObject: reply) { try? send(encoded) }
            } else if method == "session/update", params["sessionId"] as? String == activeSession,
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "agent_message_chunk",
                      let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                      let chunk = content["text"] as? String {
                if text.utf8.count + chunk.utf8.count <= 16_000 { text += chunk } else { outputOverflow = true }
            }
            return
        }
        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if object["error"] != nil {
            continuation.resume(throwing: GitCommitAIError("ACP request failed. Check the selected model, adapter and login."))
        } else if let result = object["result"], let encoded = try? JSONSerialization.data(withJSONObject: result) {
            continuation.resume(returning: encoded)
        } else {
            continuation.resume(throwing: GitCommitAIError("Invalid ACP response."))
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        for waiter in pending.values {
            waiter.resume(throwing: GitCommitAIError("ACP connection closed. Check the adapter installation and login."))
        }
        pending.removeAll()
    }
}
