import AppKit
import UniformTypeIdentifiers

enum EditorFileOpening {
    static func prefersDefaultApplication(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["dmg", "iso", "img", "zip", "7z", "rar", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf"].contains(ext) {
            return true
        }
        guard ext != "svg", let type = UTType(filenameExtension: ext) else { return false }
        return [UTType.image, .audio, .movie, .archive, .executable].contains { type.conforms(to: $0) }
    }

    static func isUnsupported(_ error: Error) -> Bool {
        if let error = error as? EditorDocumentError {
            return error == .binaryFile || error == .unsupportedEncoding
        }
        if case WorkspaceFilesystemError.fileTooLarge = error { return true }
        return false
    }

    /// Remote files use the same bounded read-only download as the Files app chooser.
    static func externalURL(path: String, filesystem: any WorkspaceFilesystem) async throws -> URL {
        guard filesystem.descriptor.kind == .ssh else { return URL(fileURLWithPath: path) }
        let data = try await filesystem.readFile(at: path)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        return url
    }

    @MainActor
    static func openExternally(
        path: String, filesystem: any WorkspaceFilesystem,
        opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async throws {
        let url = try await externalURL(path: path, filesystem: filesystem)
        try Task.checkCancellation()
        guard opener(url) else {
            throw WorkspaceFilesystemError.operationFailed("No default application could open \(url.lastPathComponent).")
        }
    }
}
