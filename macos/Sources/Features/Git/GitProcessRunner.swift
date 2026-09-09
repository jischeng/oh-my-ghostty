import Darwin
import Foundation

/// Shared process IO for local Git and the SSH transport. Neither adapter owns
/// pipes, cancellation, output limits or process settlement.
struct GitProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        maxOutputBytes: Int? = 10 * 1024 * 1024
    ) async throws -> GitExecutionResult {
        guard maxOutputBytes.map({ $0 >= 0 }) ?? true else {
            throw GitExecutionError.executionFailed("The output limit must not be negative.")
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        defer {
            for pipe in [output, errors, input] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let invocation = Invocation(process: process, limit: maxOutputBytes)
        process.terminationHandler = { [weak invocation] _ in invocation?.terminated() }
        let io = DispatchGroup()
        return try await withTaskCancellationHandler {
            try invocation.launch()
            read(output.fileHandleForReading, stream: .stdout, invocation: invocation, group: io)
            read(errors.fileHandleForReading, stream: .stderr, invocation: invocation, group: io)
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            if let stdin {
                try? input.fileHandleForReading.close()
                write(stdin, to: input.fileHandleForWriting, invocation: invocation, group: io)
            }
            await invocation.waitForExit()
            await withCheckedContinuation { continuation in
                io.notify(queue: .global(qos: .utility)) { continuation.resume() }
            }
            return try invocation.result()
        } onCancel: {
            invocation.abort(.cancelled)
        }
    }

    private func channel(_ handle: FileHandle, invocation: Invocation) throws -> DispatchIO {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else {
            throw GitExecutionError.executionFailed("Could not create a process IO channel.")
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: .global(qos: .utility)) { _ in
            Darwin.close(descriptor)
        }
        invocation.add(channel)
        return channel
    }

    private func read(_ handle: FileHandle, stream: Invocation.Stream, invocation: Invocation, group: DispatchGroup) {
        do {
            let channel = try channel(handle, invocation: invocation)
            channel.setLimit(lowWater: 1)
            channel.setLimit(highWater: 16 * 1024)
            group.enter()
            channel.read(offset: 0, length: .max, queue: .global(qos: .utility)) { done, data, error in
                if let data, !data.isEmpty { invocation.append(Data(data), stream: stream) }
                if error != 0 && error != ECANCELED {
                    invocation.abort(.executionFailed("Could not read process output (\(error))."))
                }
                if done {
                    channel.close()
                    group.leave()
                }
            }
        } catch { invocation.abort(.executionFailed(error.localizedDescription)) }
    }

    private func write(_ data: Data, to handle: FileHandle, invocation: Invocation, group: DispatchGroup) {
        do {
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            let channel = try channel(handle, invocation: invocation)
            let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
            group.enter()
            channel.write(offset: 0, data: bytes, queue: .global(qos: .utility)) { done, _, error in
                if error != 0 && error != ECANCELED { invocation.inputFailed(error) }
                if done {
                    channel.close()
                    group.leave()
                }
            }
            // Only the IO channel and child retain their respective pipe ends.
            try? handle.close()
        } catch { invocation.abort(.executionFailed(error.localizedDescription)) }
    }

    /// The lock protects both launch/stop ordering and result publication. Pipe
    /// callbacks are drained before result(), so no stream writes race its data.
    private final class Invocation: @unchecked Sendable {
        enum Stream { case stdout, stderr }
        private let process: Process
        private let limit: Int?
        private let lock = NSLock()
        private var channels: [DispatchIO] = []
        private var output = Data()
        private var errors = Data()
        private var failure: GitExecutionError?
        private var inputError: Int32?
        private var exited = false
        private var exitWaiter: CheckedContinuation<Void, Never>?

        init(process: Process, limit: Int?) {
            self.process = process
            self.limit = limit
        }

        func launch() throws {
            lock.lock()
            defer { lock.unlock() }
            if let failure { throw failure }
            do { try process.run() } catch { throw GitExecutionError.executionFailed(error.localizedDescription) }
        }

        func add(_ channel: DispatchIO) {
            lock.lock()
            let stopped = failure != nil
            channels.append(channel)
            lock.unlock()
            if stopped { channel.close(flags: .stop) }
        }

        func append(_ data: Data, stream: Stream) {
            lock.lock()
            guard failure == nil else { lock.unlock(); return }
            let remaining = limit.map { max(0, $0 - output.count - errors.count) } ?? data.count
            switch stream {
            case .stdout: output.append(data.prefix(remaining))
            case .stderr: errors.append(data.prefix(remaining))
            }
            let exceeded = data.count > remaining
            lock.unlock()
            if exceeded { abort(.outputLimitExceeded(maxBytes: limit ?? 0)) }
        }

        func inputFailed(_ code: Int32) {
            lock.lock()
            inputError = code
            lock.unlock()
        }

        func abort(_ error: GitExecutionError) {
            lock.lock()
            guard failure == nil else { lock.unlock(); return }
            failure = error
            let activeChannels = channels
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGTERM) }
            lock.unlock()
            activeChannels.forEach { $0.close(flags: .stop) }
            // A noisy hook may ignore SIGTERM. The spawned process remains the
            // sole signal target; never signal the terminal's foreground group.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self else { return }
                lock.lock()
                if !exited && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }

        func terminated() {
            lock.lock()
            exited = true
            let waiter = exitWaiter
            exitWaiter = nil
            lock.unlock()
            waiter?.resume()
        }

        func waitForExit() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if exited {
                    lock.unlock()
                    continuation.resume()
                } else {
                    exitWaiter = continuation
                    lock.unlock()
                }
            }
        }

        func result() throws -> GitExecutionResult {
            lock.lock()
            defer { lock.unlock() }
            if let failure { throw failure }
            if process.terminationStatus == 0, let inputError {
                throw GitExecutionError.executionFailed("Could not send the complete process input (\(inputError)).")
            }
            return GitExecutionResult(exitCode: process.terminationStatus, stdout: output, stderr: errors)
        }
    }
}
