import AppKit
import Foundation
import Testing
@testable import Ghostty

struct EditorWorkspaceTests {
    @Test @MainActor func paneDocumentsFollowTheirSurfaceAndStayIndependent() {
        let store = EditorWorkspaceStore()
        let tab = UUID()
        let movedTab = UUID()
        let left = UUID()
        let right = UUID()
        let leftWorkspace = store.workspace(for: tab, surfaceID: left)
        let rightWorkspace = store.workspace(for: tab, surfaceID: right)
        #expect(leftWorkspace !== rightWorkspace)
        #expect(store.workspace(for: movedTab, surfaceID: right) === rightWorkspace)
        store.remove(tabID: tab)
        #expect(store.workspace(for: movedTab, surfaceID: right) === rightWorkspace)
        #expect(store.workspace(for: tab, surfaceID: left) !== leftWorkspace)
    }

    @Test @MainActor func tabNavigationWrapsAndSaveAllWritesEachDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        let workspace = EditorWorkspace()
        for name in ["first.txt", "second.txt"] {
            let file = root.appendingPathComponent(name)
            try Data("original".utf8).write(to: file)
            workspace.open(path: file.path, filesystem: filesystem)
            await waitUntil { !workspace.isLoading }
        }
        #expect(workspace.documents.count == 2)
        let first = try #require(workspace.documents.first)
        let second = try #require(workspace.documents.last)
        workspace.selectAdjacentDocument(offset: 1)
        #expect(workspace.selectedID == first.id)
        workspace.selectAdjacentDocument(offset: -1)
        #expect(workspace.selectedID == second.id)
        first.text = "first edit"
        second.text = "second edit"
        #expect(await workspace.saveAll())
        #expect(!first.isDirty && !second.isDirty)
        #expect(try String(contentsOfFile: first.path, encoding: .utf8) == "first edit")
        #expect(try String(contentsOfFile: second.path, encoding: .utf8) == "second edit")
    }

    @Test func shortcutModifiersIgnoreCapsLockButDistinguishShiftAndControl() {
        #expect(EditorKeyStroke(key: "F", modifiers: [.command, .capsLock]) ==
            EditorKeyStroke(key: "f", modifiers: .command))
        #expect(EditorKeyStroke(key: "g", modifiers: [.command, .shift]) !=
            EditorKeyStroke(key: "g", modifiers: .command))
        #expect(EditorKeyStroke(key: "\t", modifiers: .control) !=
            EditorKeyStroke(key: "\t", modifiers: [.control, .shift]))
    }

    @Test @MainActor func staleConcurrentOpenCannotReplaceNewerSelection() async throws {
        let filesystem = ControlledEditorWorkspaceFilesystem()
        let workspace = EditorWorkspace()

        workspace.open(path: "/first", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/first")
        workspace.open(path: "/second", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/second")
        await filesystem.finishRead(at: "/second", with: Data("second".utf8))
        await waitUntil { workspace.selectedDocument?.path == "/second" }

        await filesystem.finishRead(at: "/first", with: Data("first".utf8))
        await Task.yield()

        #expect(workspace.documents.map(\.path) == ["/second"])
        #expect(workspace.selectedDocument?.text == "second")
        #expect(!workspace.isLoading)
    }

    @Test @MainActor func repeatedOpenKeepsExistingDirtyDocument() async throws {
        let filesystem = ControlledEditorWorkspaceFilesystem()
        let workspace = EditorWorkspace()

        workspace.open(path: "/project/file", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/project/file")
        await filesystem.finishRead(at: "/project/file", with: Data("original".utf8))
        await waitUntil { workspace.documents.count == 1 }
        let original = try #require(workspace.selectedDocument)
        original.text = "unsaved"

        workspace.open(path: "/project/./file", filesystem: filesystem)

        #expect(workspace.documents.count == 1)
        #expect(workspace.selectedDocument === original)
        #expect(workspace.selectedDocument?.text == "unsaved")
        #expect(workspace.selectedDocument?.isDirty == true)
        #expect(!workspace.isLoading)
        #expect(await filesystem.readCount() == 1)
    }

    @Test @MainActor func failedSavePublishesReasonAndKeepsDirtyState() async throws {
        let reason = "Remote disk is read-only."
        let filesystem = ControlledEditorWorkspaceFilesystem(writeFailure: reason)
        let workspace = EditorWorkspace()
        workspace.open(path: "/file", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/file")
        await filesystem.finishRead(at: "/file", with: Data("original".utf8))
        await waitUntil { workspace.selectedDocument != nil }
        let document = try #require(workspace.selectedDocument)
        document.text = "changed"

        let saved = await workspace.save(document)

        #expect(!saved)
        #expect(document.isDirty)
        #expect(!document.isSaving)
        #expect(workspace.errorMessage == reason)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for editor workspace state")
    }
}

private actor ControlledEditorWorkspaceFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(
        kind: .local,
        id: "local",
        displayName: "test",
        workingDirectory: "/"
    )

    private struct PendingRead {
        let continuation: CheckedContinuation<Data, Error>
    }

    private let writeFailure: String?
    private var pendingReads: [String: PendingRead] = [:]
    private var readWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var reads = 0

    init(writeFailure: String? = nil) {
        self.writeFailure = writeFailure
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}

    func readFile(at path: String) async throws -> Data {
        reads += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[path] = PendingRead(continuation: continuation)
            readWaiters.removeValue(forKey: path)?.forEach { $0.resume() }
        }
    }

    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        if let writeFailure {
            throw WorkspaceFilesystemError.operationFailed(writeFailure)
        }
    }

    func waitUntilReadStarts(at path: String) async {
        if pendingReads[path] != nil { return }
        await withCheckedContinuation { continuation in
            readWaiters[path, default: []].append(continuation)
        }
    }

    func finishRead(at path: String, with data: Data) {
        pendingReads.removeValue(forKey: path)?.continuation.resume(returning: data)
    }

    func readCount() -> Int { reads }
}
