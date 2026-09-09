import Foundation
import Testing
@testable import Ghostty

struct GitProcessRunnerTests {
    @Test func concurrentBinaryPipesAreDrainedBeforePublishingResults() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 256) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let result = try await GitProcessRunner().run(
                        executablePath: "/bin/sh", arguments: ["-c", "cat; printf error-stream >&2"],
                        workingDirectory: "/", stdin: payload, maxOutputBytes: 300_000
                    )
                    #expect(result.isSuccess && result.stdout == payload)
                    #expect(result.stderrString == "error-stream")
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func outputLimitStopsACommandThatDoesNotExitOrHonorTerm() async throws {
        let task = Task {
            try await GitProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", "trap '' TERM PIPE; while :; do printf 012345678901234567890123456789 >&2; done"],
                workingDirectory: "/", maxOutputBytes: 32 * 1024
            )
        }
        let deadline = Task { try await Task.sleep(for: .seconds(3)); task.cancel() }
        defer { deadline.cancel() }
        do {
            _ = try await task.value
            Issue.record("The output limit should terminate a continuing command.")
        } catch let error as GitExecutionError {
            #expect(error == .outputLimitExceeded(maxBytes: 32 * 1024))
        }
    }

    @Test func cancellationWorksBeforeLaunchAndWhilePipesRemainOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await GitProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf ready > ready; trap '' TERM; while :; do sleep 1; done"],
                workingDirectory: root.path
            )
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled command returned a result") } catch let error as GitExecutionError { #expect(error == .cancelled) }

        let neverLaunched = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitProcessRunner().run(
                executablePath: "/bin/sh", arguments: ["-c", "touch should-not-exist"], workingDirectory: root.path
            )
        }
        neverLaunched.cancel()
        _ = try? await neverLaunched.value
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
    }
}
