import Foundation
import Testing
@testable import Ghostty

struct EditorFileOpeningTests {
    @Test func binaryFormatsPreferTheirDefaultAppButSourceFilesStayEditable() {
        for ext in ["dmg", "DMG", "pdf", "png", "jpg", "mp4", "zip", "docx"] {
            #expect(EditorFileOpening.prefersDefaultApplication(path: "/tmp/file." + ext))
        }
        for path in ["README.md", ".gitignore", "file.swift", "file.json", "file.svg", "Dockerfile"] {
            #expect(!EditorFileOpening.prefersDefaultApplication(path: path))
        }
        #expect(EditorFileOpening.isUnsupported(EditorDocumentError.binaryFile))
        #expect(EditorFileOpening.isUnsupported(EditorDocumentError.unsupportedEncoding))
        #expect(!EditorFileOpening.isUnsupported(WorkspaceFilesystemError.unavailable))
    }

    @Test @MainActor func defaultAppReceivesOriginalLocalFileWithoutReadingBinaryContents() async throws {
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: "/tmp")
        var opened: URL?
        try await EditorFileOpening.openExternally(path: "/tmp/Example image.dmg", filesystem: filesystem) {
            opened = $0
            return true
        }
        #expect(opened?.path == "/tmp/Example image.dmg")
    }
}
