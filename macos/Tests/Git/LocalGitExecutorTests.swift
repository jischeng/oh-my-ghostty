import Foundation
import Testing
@testable import Ghostty

struct LocalGitExecutorTests {
    @Test func executesGitVersionSuccessfully() async throws {
        let executor = LocalGitExecutor()
        let result = try await executor.execute(
            arguments: ["--version"],
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        #expect(result.isSuccess)
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.contains("git version"))
    }

    @Test func capturesStderrOnInvalidCommand() async throws {
        let executor = LocalGitExecutor()
        let result = try await executor.execute(
            arguments: ["some-invalid-git-subcommand-xyz"],
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        #expect(!result.isSuccess)
        #expect(result.exitCode != 0)
        #expect(!result.stderrString.isEmpty)
    }

    @Test func passesStdinDataToProcess() async throws {
        let executor = LocalGitExecutor()
        let inputString = "hello world stdin test"
        let inputData = inputString.data(using: .utf8)
        let result = try await executor.execute(
            arguments: ["hash-object", "--stdin"],
            workingDirectory: FileManager.default.temporaryDirectory.path,
            stdin: inputData
        )
        #expect(result.isSuccess)
        #expect(!result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func enforcesOutputByteLimit() async throws {
        let executor = LocalGitExecutor()
        await #expect(throws: GitExecutionError.self) {
            _ = try await executor.execute(
                arguments: ["--version"],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                maxOutputBytes: 4
            )
        }
    }

    @Test func handlesTaskCancellation() async throws {
        let executor = LocalGitExecutor()
        let task = Task {
            try await executor.execute(
                arguments: ["version"],
                workingDirectory: FileManager.default.temporaryDirectory.path
            )
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch let error as GitExecutionError {
            #expect(error == .cancelled)
        } catch is CancellationError {
            // CancellationError is also an expected cancellation outcome in Swift concurrency
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
