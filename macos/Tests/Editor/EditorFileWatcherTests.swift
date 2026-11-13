import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct EditorFileWatcherTests {
    @Test @MainActor
    func detectsConsecutiveAtomicTempFileRenameWrites() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-watcher-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let targetURL = dir.appendingPathComponent("AgentEdited.swift")
        let initialData = Data("let version = 1\n".utf8)
        try initialData.write(to: targetURL)

        var observed: [EditorExternalFileChange] = []
        let watcher = EditorFileWatcher(debounceInterval: 0.05) { change in
            observed.append(change)
        }
        defer { watcher.stopAll() }

        watcher.watchLocalFile(path: targetURL.path, expectedData: initialData)
        try await Task.sleep(for: .milliseconds(80))

        // First atomic save via temp file + POSIX rename() (replaces inode #1 -> inode #2)
        let temp1 = dir.appendingPathComponent(".AgentEdited.swift.tmp.1")
        let v2Data = Data("let version = 2\n".utf8)
        try v2Data.write(to: temp1)
        #expect(Darwin.rename(temp1.path, targetURL.path) == 0)

        let gotFirst = await waitForCondition(timeoutMs: 2_000) {
            observed.count == 1
        }
        #expect(gotFirst)
        #expect(observed.first?.path == targetURL.path)
        #expect(observed.first?.text == "let version = 2\n")

        // Acknowledge update and perform a SECOND atomic temp+rename (replaces inode #2 -> inode #3)
        // verifying that file descriptor watching properly re-armed on the replaced inode!
        watcher.updateExpectedData(v2Data, forPath: targetURL.path)
        try await Task.sleep(for: .milliseconds(50))

        let temp2 = dir.appendingPathComponent(".AgentEdited.swift.tmp.2")
        let v3Data = Data("let version = 3\n".utf8)
        try v3Data.write(to: temp2)
        #expect(Darwin.rename(temp2.path, targetURL.path) == 0)

        let gotSecond = await waitForCondition(timeoutMs: 2_000) {
            observed.count == 2
        }
        #expect(gotSecond)
        #expect(observed.last?.text == "let version = 3\n")
    }

    @Test @MainActor
    func detectsInPlaceFileModificationAndCoalescesBursts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-watcher-inplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let targetURL = dir.appendingPathComponent("notes.md")
        let initialData = Data("# v0\n".utf8)
        try initialData.write(to: targetURL)

        var observed: [EditorExternalFileChange] = []
        let watcher = EditorFileWatcher(debounceInterval: 0.12) { change in
            observed.append(change)
        }
        defer { watcher.stopAll() }

        watcher.watchLocalFile(path: targetURL.path, expectedData: initialData)
        try await Task.sleep(for: .milliseconds(80))

        // Perform rapid in-place writes on the same inode within the 120ms debounce window.
        for step in 1...4 {
            let handle = try FileHandle(forWritingTo: targetURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("# v\(step)\n".utf8))
            try handle.close()
            try await Task.sleep(for: .milliseconds(15))
        }

        let delivered = await waitForCondition(timeoutMs: 2_000) {
            observed.last?.text == "# v4\n"
        }
        #expect(delivered)
        #expect(observed.count == 1)
    }

    @Test @MainActor
    func suppressesSelfSavesWithoutFalsePositives() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-watcher-selfsave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let targetURL = dir.appendingPathComponent("SelfSave.swift")
        let initialData = Data("struct App {}\n".utf8)
        try initialData.write(to: targetURL)

        var observed: [EditorExternalFileChange] = []
        let watcher = EditorFileWatcher(debounceInterval: 0.05) { change in
            observed.append(change)
        }
        defer { watcher.stopAll() }

        watcher.watchLocalFile(path: targetURL.path, expectedData: initialData)
        try await Task.sleep(for: .milliseconds(60))

        // Simulate OMG's own save pipeline pre-registering and persisting new bytes.
        let selfSavedData = Data("struct App { let ready = true }\n".utf8)
        watcher.recordPendingSelfSave(selfSavedData, forPath: targetURL.path)
        try selfSavedData.write(to: targetURL, options: .atomic)
        watcher.updateExpectedData(selfSavedData, forPath: targetURL.path)

        try await Task.sleep(for: .milliseconds(220))
        #expect(observed.isEmpty)

        // Now an external tool modifies the file with unexpected bytes -> MUST fire!
        let externalData = Data("struct App { let ready = false }\n".utf8)
        try externalData.write(to: targetURL, options: .atomic)

        let fired = await waitForCondition(timeoutMs: 2_000) {
            observed.count == 1
        }
        #expect(fired)
        #expect(observed.first?.text == "struct App { let ready = false }\n")
    }

    @Test @MainActor
    func unwatchAndStopAllPreventSubsequentCallbacks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-watcher-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("A.txt")
        let fileB = dir.appendingPathComponent("B.txt")
        try Data("a1".utf8).write(to: fileA)
        try Data("b1".utf8).write(to: fileB)

        var observedPaths: [String] = []
        let watcher = EditorFileWatcher(debounceInterval: 0.05) { change in
            observedPaths.append(change.path)
        }

        watcher.watchLocalFile(path: fileA.path, expectedData: Data("a1".utf8))
        watcher.watchLocalFile(path: fileB.path, expectedData: Data("b1".utf8))
        #expect(watcher.watchedPaths.count == 2)
        try await Task.sleep(for: .milliseconds(60))

        watcher.unwatch(path: fileA.path)
        #expect(watcher.watchedPaths == [fileB.path])
        try Data("a2".utf8).write(to: fileA, options: .atomic)

        watcher.stopAll()
        #expect(watcher.watchedPaths.isEmpty)
        try Data("b2".utf8).write(to: fileB, options: .atomic)

        try await Task.sleep(for: .milliseconds(200))
        #expect(observedPaths.isEmpty)
    }

    @Test @MainActor
    func checkExternalChangeSupportsRemoteSSHFocusRefresh() async throws {
        let sshDescriptor = WorkspaceDescriptor(
            kind: .ssh,
            id: "ssh://dev@builder",
            displayName: "builder",
            workingDirectory: "/home/dev/repo"
        )
        let remoteFS = MockRemoteWatcherFilesystem(
            descriptor: sshDescriptor,
            files: [
                "/home/dev/repo/main.py": Data([0xEF, 0xBB, 0xBF] + Array("print('v1')\r\n".utf8))
            ]
        )

        let watcher = EditorFileWatcher()
        let baseline = Data([0xEF, 0xBB, 0xBF] + Array("print('v1')\r\n".utf8))

        // Unchanged remote file returns nil.
        let unchanged = await watcher.checkExternalChange(
            path: "/home/dev/repo/main.py",
            filesystem: remoteFS,
            expectedData: baseline
        )
        #expect(unchanged == nil)

        // Simulate remote edit on SSH host (`vim` / Claude Code over SSH).
        let updatedRemote = Data([0xEF, 0xBB, 0xBF] + Array("print('v2')\r\n".utf8))
        await remoteFS.setFileData(updatedRemote, forPath: "/home/dev/repo/main.py")

        let detected = await watcher.checkExternalChange(
            path: "/home/dev/repo/main.py",
            filesystem: remoteFS,
            expectedData: baseline
        )
        #expect(detected != nil)
        #expect(detected?.path == "/home/dev/repo/main.py")
        #expect(detected?.data == updatedRemote)
        #expect(detected?.text == "print('v2')\n")
        #expect(detected?.encoding == EditorDocumentEncoding(hasUTF8ByteOrderMark: true, newline: .carriageReturnLineFeed))

        // Missing/unreadable path returns nil gracefully without throwing.
        let missing = await watcher.checkExternalChange(
            path: "/home/dev/repo/missing.py",
            filesystem: remoteFS,
            expectedData: baseline
        )
        #expect(missing == nil)
    }

    @MainActor
    private func waitForCondition(
        timeoutMs: Int,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let stepMs = 20
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
            elapsed += stepMs
        }
        return condition()
    }
}

private actor MockRemoteWatcherFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor: WorkspaceDescriptor
    private var files: [String: Data]

    init(descriptor: WorkspaceDescriptor, files: [String: Data]) {
        self.descriptor = descriptor
        self.files = files
    }

    func setFileData(_ data: Data, forPath path: String) {
        files[path] = data
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        []
    }

    func createFile(named name: String, in directory: String) async throws {
        throw WorkspaceFilesystemError.unavailable
    }

    func createDirectory(named name: String, in directory: String) async throws {
        throw WorkspaceFilesystemError.unavailable
    }

    func readFile(at path: String) async throws -> Data {
        guard let data = files[path] else {
            throw WorkspaceFilesystemError.operationFailed("Not found: \(path)")
        }
        return data
    }
}
