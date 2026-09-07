import Foundation
import Testing
@testable import Ghostty

struct EditorDocumentTests {
    @Test @MainActor func savingUnchangedFilePreservesMixedNewlines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-unchanged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed.txt")
        let original = Data("one\r\ntwo\nthree\r".utf8)
        try original.write(to: file)
        let document = try await EditorDocument.open(
            path: file.path,
            filesystem: LocalWorkspaceFilesystem(workingDirectory: directory.path)
        )
        try await document.save()
        #expect(try Data(contentsOf: file) == original)
    }

    @Test @MainActor func localFileRoundTripPreservesBOMAndCRLF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hello.txt")
        try Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8)).write(to: file)

        let filesystem = LocalWorkspaceFilesystem(workingDirectory: directory.path)
        let document = try await EditorDocument.open(path: file.path, filesystem: filesystem)
        #expect(document.text == "one\ntwo\n")
        #expect(!document.isDirty)

        document.text += "three\n"
        #expect(document.isDirty)
        try await document.save()
        #expect(!document.isDirty)
        #expect(try Data(contentsOf: file) == Data(
            [0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree\r\n".utf8)
        ))
    }

    @Test @MainActor func rejectsBinaryAndInvalidUTF8Files() async throws {
        let binary = MemoryEditorFilesystem(data: Data([0x61, 0x00, 0x62]))
        await #expect(throws: EditorDocumentError.binaryFile) {
            try await EditorDocument.open(path: "/binary", filesystem: binary)
        }
        let invalidUTF8 = MemoryEditorFilesystem(data: Data([0xC3, 0x28]))
        await #expect(throws: EditorDocumentError.unsupportedEncoding) {
            try await EditorDocument.open(path: "/invalid", filesystem: invalidUTF8)
        }
    }

    @Test @MainActor func rejectsFilesLargerThanEditorLimitBeforeReading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.txt")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(10 * 1_024 * 1_024 + 1))
        try handle.close()

        await #expect(throws: WorkspaceFilesystemError.fileTooLarge(
            file.path,
            10 * 1_024 * 1_024
        )) {
            try await EditorDocument.open(
                path: file.path,
                filesystem: LocalWorkspaceFilesystem(workingDirectory: directory.path)
            )
        }
    }

    @Test @MainActor func failedSaveKeepsDocumentDirty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("removed.txt")
        try Data("before".utf8).write(to: file)
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: directory.path)
        let document = try await EditorDocument.open(path: file.path, filesystem: filesystem)
        document.text = "after"
        try FileManager.default.removeItem(at: directory)

        await #expect(throws: Error.self) {
            try await document.save()
        }
        #expect(document.isDirty)
        #expect(!document.isSaving)
    }

    @Test @MainActor func editDuringSaveIsNotMarkedCleanOrLost() async throws {
        let filesystem = SuspendedWriteEditorFilesystem(data: Data("before".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        document.text = "first edit"

        let save = Task { try await document.save() }
        await filesystem.waitUntilWriteStarts()
        #expect(document.isSaving)
        await #expect(throws: EditorDocumentError.saveInProgress) {
            try await document.save()
        }
        document.text = "second edit"
        await filesystem.finishWrite()
        try await save.value

        #expect(document.text == "second edit")
        #expect(document.isDirty)
        #expect(await filesystem.writtenData() == Data("first edit".utf8))
    }

    @Test @MainActor func slowSaveSchedulesRemainingEdits() async throws {
        let filesystem = SuspendedWriteEditorFilesystem(data: Data("before".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        document.text = "first edit"
        let save = Task { try await document.save() }
        await filesystem.waitUntilWriteStarts()
        document.text = "second edit"
        // Let the old debounce deadline pass while the first write is blocked.
        try await Task.sleep(for: .milliseconds(1200))
        await filesystem.finishWrite()
        try await save.value
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await filesystem.writtenData() == Data("second edit".utf8))
        await filesystem.finishWrite()
        document.suspendAutoSave()
    }

    @Test @MainActor func suspendedAutoSaveCannotFlushAndResumesAfterCancel() async throws {
        let filesystem = MutableEditorFilesystem(data: Data("original".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        document.text = "edited"
        document.suspendAutoSave()
        document.flushAutoSave()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await filesystem.currentData() == Data("original".utf8))
        #expect(document.isDirty)
        document.resumeAutoSave()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await filesystem.currentData() == Data("edited".utf8))
        #expect(!document.isDirty)
    }

    @Test @MainActor func autoSaveFailureIsVisibleAndSuccessfulRetryClearsIt() async throws {
        let filesystem = MutableEditorFilesystem(data: Data("original".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        await filesystem.replaceData(Data("external".utf8))
        document.text = "edited"
        document.flushAutoSave()
        try await Task.sleep(for: .milliseconds(300))
        #expect(document.saveErrorMessage != nil)
        #expect(document.isDirty)
        #expect(await filesystem.currentData() == Data("external".utf8))
        await filesystem.replaceData(Data("original".utf8))
        try await document.save()
        #expect(document.saveErrorMessage == nil)
        #expect(!document.isDirty)
        #expect(await filesystem.currentData() == Data("edited".utf8))
    }

    @Test @MainActor func dirtyTracksDifferenceFromPersistedText() async throws {
        let filesystem = MemoryEditorFilesystem(data: Data("original".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)

        document.text = "original"
        #expect(!document.isDirty)
        document.text = "changed"
        #expect(document.isDirty)
        document.text = "original"
        #expect(!document.isDirty)
    }

    @Test @MainActor func externalModificationPreventsOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: file)
        let document = try await EditorDocument.open(
            path: file.path,
            filesystem: LocalWorkspaceFilesystem(workingDirectory: directory.path)
        )
        document.text = "editor"
        try Data("external".utf8).write(to: file)

        await #expect(throws: WorkspaceFilesystemError.fileChanged(file.path)) {
            try await document.save()
        }
        #expect(document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external")
    }

    @Test @MainActor func reloadsExternalModificationAndCanSaveWithNewEncoding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("original\n".utf8).write(to: file)
        let document = try await EditorDocument.open(
            path: file.path,
            filesystem: LocalWorkspaceFilesystem(workingDirectory: directory.path)
        )
        try Data([0xEF, 0xBB, 0xBF] + Array("external\r\n".utf8)).write(to: file)

        try await document.reload()

        #expect(document.text == "external\n")
        #expect(!document.isDirty)
        #expect(document.contentGeneration == 1)
        document.text += "saved\n"
        try await document.save()
        #expect(try Data(contentsOf: file) == Data(
            [0xEF, 0xBB, 0xBF] + Array("external\r\nsaved\r\n".utf8)
        ))
    }

    @Test @MainActor func failedReloadPreservesDirtyContent() async throws {
        let filesystem = MutableEditorFilesystem(data: Data("original".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        document.text = "editor"
        await filesystem.failReads()

        await #expect(throws: TestEditorFilesystemError.readFailed) {
            try await document.reload()
        }

        #expect(document.text == "editor")
        #expect(document.isDirty)
        #expect(!document.isReloading)
        #expect(document.contentGeneration == 0)
    }

    @Test @MainActor func editDuringReloadIsNotOverwritten() async throws {
        let filesystem = SuspendedReadEditorFilesystem(data: Data("original".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        await filesystem.replaceData(Data("external".utf8))
        await filesystem.suspendNextRead()

        let reload = Task { try await document.reload() }
        await filesystem.waitUntilReadStarts()
        #expect(document.isReloading)
        document.text = "editor"
        await filesystem.finishRead()
        await #expect(throws: EditorDocumentError.editedDuringReload) {
            try await reload.value
        }

        #expect(document.text == "editor")
        #expect(document.isDirty)
        #expect(!document.isReloading)
        #expect(document.contentGeneration == 0)
        await #expect(throws: WorkspaceFilesystemError.fileChanged("/file")) {
            try await document.save()
        }
        #expect(await filesystem.currentData() == Data("external".utf8))
    }

    @Test @MainActor func saveAndReloadAreMutuallyExclusive() async throws {
        let filesystem = SuspendedReadEditorFilesystem(data: Data("original".utf8))
        let document = try await EditorDocument.open(path: "/file", filesystem: filesystem)
        document.text = "editor"
        await filesystem.suspendNextRead()

        let reload = Task { try await document.reload() }
        await filesystem.waitUntilReadStarts()
        await #expect(throws: EditorDocumentError.reloadInProgress) {
            try await document.reload()
        }
        await #expect(throws: EditorDocumentError.reloadInProgress) {
            try await document.save()
        }
        await filesystem.finishRead()
        try await reload.value

        let suspendedWrite = SuspendedWriteEditorFilesystem(data: Data("original".utf8))
        let savingDocument = try await EditorDocument.open(path: "/file", filesystem: suspendedWrite)
        savingDocument.text = "editor"
        let save = Task { try await savingDocument.save() }
        await suspendedWrite.waitUntilWriteStarts()
        await #expect(throws: EditorDocumentError.saveInProgress) {
            try await savingDocument.reload()
        }
        await suspendedWrite.finishWrite()
        try await save.value
    }

    @Test @MainActor func localSavePreservesSymlinkAndExecutableMode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("script.sh")
        let link = directory.appendingPathComponent("script-link.sh")
        try Data("#!/bin/sh\necho before\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let document = try await EditorDocument.open(
            path: link.path,
            filesystem: LocalWorkspaceFilesystem(workingDirectory: directory.path)
        )
        document.text = "#!/bin/sh\necho after\n"
        try await document.save()

        let linkValues = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(linkValues.isSymbolicLink == true)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("echo after"))
    }

    @Test func identityUsesEndpointAndNormalizedAbsolutePath() throws {
        let local = WorkspaceDescriptor(
            kind: .local,
            id: "local",
            displayName: "project",
            workingDirectory: "/tmp/project"
        )
        let remote = WorkspaceDescriptor(
            kind: .ssh,
            id: "ssh:cloud",
            displayName: "cloud",
            workingDirectory: "/tmp/project"
        )
        let localID = try EditorDocumentID(descriptor: local, path: "/tmp/./project/file")
        let remoteID = try EditorDocumentID(descriptor: remote, path: "/tmp/project/file")
        #expect(localID.path == "/tmp/project/file")
        #expect(localID != remoteID)
        #expect(throws: EditorDocumentError.invalidPath) {
            try EditorDocumentID(descriptor: local, path: "relative/file")
        }
    }

    @Test func symlinkFollowedByParentResolvesToTargetParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-symlink-test-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        let targetDir = root.appendingPathComponent("target/sub")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = project.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetDir)

        let configFile = root.appendingPathComponent("target/config")
        try Data("correct".utf8).write(to: configFile)

        let wrongConfigFile = project.appendingPathComponent("config")
        try Data("wrong".utf8).write(to: wrongConfigFile)

        let localDescriptor = WorkspaceDescriptor(
            kind: .local,
            id: "local",
            displayName: "project",
            workingDirectory: project.path
        )

        let testPath = link.path + "/../config"
        let docID = try EditorDocumentID(descriptor: localDescriptor, path: testPath)
        #expect(docID.path == configFile.path)
    }

    @Test func multiLevelSymlinkFollowedByParentResolvesToTargetParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-multisymlink-test-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        let targetDir = root.appendingPathComponent("target/sub")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link2 = project.appendingPathComponent("link2")
        try FileManager.default.createSymbolicLink(at: link2, withDestinationURL: targetDir)

        let link1 = project.appendingPathComponent("link1")
        try FileManager.default.createSymbolicLink(at: link1, withDestinationURL: link2)

        let configFile = root.appendingPathComponent("target/config")
        try Data("correct".utf8).write(to: configFile)

        let localDescriptor = WorkspaceDescriptor(
            kind: .local,
            id: "local",
            displayName: "project",
            workingDirectory: project.path
        )

        let testPath = link1.path + "/../config"
        let docID = try EditorDocumentID(descriptor: localDescriptor, path: testPath)
        #expect(docID.path == configFile.path)
    }
}

private struct MemoryEditorFilesystem: WorkspaceFilesystem {
    let descriptor = WorkspaceDescriptor(
        kind: .local,
        id: "local",
        displayName: "test",
        workingDirectory: "/"
    )
    let data: Data

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}
    func readFile(at path: String) async throws -> Data { data }
    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {}
}

private enum TestEditorFilesystemError: Error {
    case readFailed
}

private actor MutableEditorFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(
        kind: .local,
        id: "local",
        displayName: "test",
        workingDirectory: "/"
    )
    private var data: Data
    private var shouldFailReads = false

    init(data: Data) { self.data = data }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}
    func readFile(at path: String) async throws -> Data {
        guard !shouldFailReads else { throw TestEditorFilesystemError.readFailed }
        return data
    }
    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        guard self.data == expectedData else { throw WorkspaceFilesystemError.fileChanged(path) }
        self.data = data
    }
    func replaceData(_ data: Data) { self.data = data }
    func failReads() { shouldFailReads = true }
    func currentData() -> Data { data }
}

private actor SuspendedReadEditorFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(
        kind: .local,
        id: "local",
        displayName: "test",
        workingDirectory: "/"
    )
    private var data: Data
    private var shouldSuspendRead = false
    private var readStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(data: Data) { self.data = data }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}
    func readFile(at path: String) async throws -> Data {
        if shouldSuspendRead {
            shouldSuspendRead = false
            readStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { readContinuation = $0 }
        }
        return data
    }
    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        guard self.data == expectedData else { throw WorkspaceFilesystemError.fileChanged(path) }
        self.data = data
    }
    func replaceData(_ data: Data) { self.data = data }
    func suspendNextRead() { shouldSuspendRead = true }
    func waitUntilReadStarts() async {
        guard !readStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func finishRead() {
        readContinuation?.resume()
        readContinuation = nil
    }
    func currentData() -> Data { data }
}

private actor SuspendedWriteEditorFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(
        kind: .local,
        id: "local",
        displayName: "test",
        workingDirectory: "/"
    )
    private let data: Data
    private var writeStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var output: Data?

    init(data: Data) {
        self.data = data
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}
    func readFile(at path: String) async throws -> Data { data }

    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        output = data
        writeStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { writeContinuation = $0 }
    }

    func waitUntilWriteStarts() async {
        guard !writeStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }

    func writtenData() -> Data? { output }
}
