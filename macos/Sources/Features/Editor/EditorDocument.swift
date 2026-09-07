import Combine
import Foundation

enum EditorDocumentError: Error, Equatable, Sendable {
    case invalidPath
    case binaryFile
    case unsupportedEncoding
    case saveInProgress
    case reloadInProgress
    case editedDuringReload
}

extension EditorDocumentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPath: "The file path is invalid."
        case .binaryFile: "The file contains binary data and cannot be edited as text."
        case .unsupportedEncoding: "The file is not valid UTF-8 text."
        case .saveInProgress: "This document is already being saved."
        case .reloadInProgress: "This document is already being reloaded."
        case .editedDuringReload: "The document was edited while it was being reloaded."
        }
    }
}

struct EditorDocumentID: Hashable, Sendable {
    enum Endpoint: Hashable, Sendable {
        case local
        case ssh(workspaceID: String)
    }

    let endpoint: Endpoint
    let path: String

    init(descriptor: WorkspaceDescriptor, path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else {
            throw EditorDocumentError.invalidPath
        }
        switch descriptor.kind {
        case .local:
            self.endpoint = .local
        case .ssh:
            self.endpoint = .ssh(workspaceID: descriptor.id)
        }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if descriptor.kind == .local {
                    var currentString = "/" + components.joined(separator: "/")
                    var depth = 0
                    while depth < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: currentString) {
                        let currentURL = URL(fileURLWithPath: currentString)
                        let resolvedURL: URL
                        if target.hasPrefix("/") {
                            resolvedURL = URL(fileURLWithPath: target).standardizedFileURL
                        } else {
                            resolvedURL = URL(fileURLWithPath: target, relativeTo: currentURL.deletingLastPathComponent()).standardizedFileURL
                        }
                        currentString = resolvedURL.path
                        depth += 1
                    }
                    if depth > 0 {
                        let parentPath = URL(fileURLWithPath: currentString).deletingLastPathComponent().path
                        components = parentPath.split(separator: "/").map { Substring($0) }
                        continue
                    }
                }
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        self.path = "/" + components.joined(separator: "/")
    }
}

struct EditorDocumentEncoding: Equatable, Sendable {
    enum Newline: String, Sendable {
        case lineFeed = "\n"
        case carriageReturnLineFeed = "\r\n"
        case carriageReturn = "\r"
    }

    let hasUTF8ByteOrderMark: Bool
    let newline: Newline
}

@MainActor
final class EditorDocument: ObservableObject {
    let id: EditorDocumentID
    let filesystem: any WorkspaceFilesystem

    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            revision &+= 1
            isDirty = text != persistedText
            if isDirty { scheduleAutoSave() }
        }
    }
    @Published private(set) var isDirty: Bool
    @Published private(set) var isSaving = false
    @Published private(set) var isReloading = false
    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var contentGeneration: UInt64 = 0

    private var encoding: EditorDocumentEncoding
    private var persistedText: String
    private var persistedData: Data
    private var revision: UInt64 = 0
    private var autoSaveTask: Task<Void, Never>?

    var path: String { id.path }

    private var autoSaveSuspensionCount = 0

    func suspendAutoSave() {
        autoSaveSuspensionCount += 1
        cancelAutoSave()
    }

    func resumeAutoSave() {
        autoSaveSuspensionCount = max(0, autoSaveSuspensionCount - 1)
        if isDirty { scheduleAutoSave() }
    }

    func cancelAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    func flushAutoSave() {
        scheduleAutoSave(delay: .zero)
    }

    private func scheduleAutoSave(delay: Duration = .seconds(1)) {
        cancelAutoSave()
        guard autoSaveSuspensionCount == 0, isDirty, !isSaving, !isReloading else { return }
        autoSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // The timer has fired. A subsequent edit must not cancel an in-flight write.
            self.autoSaveTask = nil
            do {
                try await self.save()
            } catch {
                // save() retains the error on the document for the editor to display.
            }
        }
    }

    init(
        id: EditorDocumentID,
        text: String,
        encoding: EditorDocumentEncoding,
        originalData: Data,
        filesystem: any WorkspaceFilesystem
    ) {
        self.id = id
        self.text = text
        self.encoding = encoding
        self.persistedText = text
        self.persistedData = originalData
        self.filesystem = filesystem
        self.isDirty = false
    }

    static func open(
        path: String,
        filesystem: any WorkspaceFilesystem
    ) async throws -> EditorDocument {
        let id = try EditorDocumentID(descriptor: filesystem.descriptor, path: path)
        let data = try await filesystem.readFile(at: id.path)
        let decoded = try await Task.detached(priority: .utility) {
            try Self.decode(data)
        }.value
        return EditorDocument(
            id: id,
            text: decoded.text,
            encoding: decoded.encoding,
            originalData: data,
            filesystem: filesystem
        )
    }

    func save() async throws {
        guard !isSaving else { throw EditorDocumentError.saveInProgress }
        guard !isReloading else { throw EditorDocumentError.reloadInProgress }
        guard isDirty else { return }
        cancelAutoSave()
        let savedRevision = revision
        let savedText = text
        let expectedData = persistedData
        isSaving = true
        defer { isSaving = false }
        let encoding = encoding
        let data = await Task.detached(priority: .utility) {
            Self.encode(savedText, encoding: encoding)
        }.value
        do {
            try await filesystem.writeFile(data, at: path, replacing: expectedData)
        } catch {
            saveErrorMessage = error.localizedDescription
            throw error
        }
        saveErrorMessage = nil
        persistedText = savedText
        persistedData = data
        if revision == savedRevision {
            isDirty = false
        } else {
            isDirty = text != persistedText
        }
        // A slow local/SSH write may outlive the debounce for edits made during it.
        isSaving = false
        if isDirty { scheduleAutoSave() }
    }

    func reload() async throws {
        guard !isSaving else { throw EditorDocumentError.saveInProgress }
        guard !isReloading else { throw EditorDocumentError.reloadInProgress }
        cancelAutoSave()
        let reloadRevision = revision
        isReloading = true
        defer {
            isReloading = false
            if isDirty { scheduleAutoSave() }
        }

        let data = try await filesystem.readFile(at: path)
        let decoded = try await Task.detached(priority: .utility) {
            try Self.decode(data)
        }.value

        guard revision == reloadRevision else {
            throw EditorDocumentError.editedDuringReload
        }
        encoding = decoded.encoding
        persistedText = decoded.text
        persistedData = data
        text = decoded.text
        isDirty = false
        saveErrorMessage = nil
        contentGeneration &+= 1
    }

    func discardChanges() {
        cancelAutoSave()
        text = persistedText
        isDirty = false
        saveErrorMessage = nil
    }

    nonisolated private static func decode(
        _ data: Data
    ) throws -> (text: String, encoding: EditorDocumentEncoding) {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = data.starts(with: bom)
        let content = hasBOM ? data.dropFirst(bom.count) : data[...]
        let containsBinaryControl = content.contains { byte in
            byte == 0 || byte < 0x08 || (byte > 0x0D && byte < 0x20)
        }
        guard !containsBinaryControl else { throw EditorDocumentError.binaryFile }
        guard let raw = String(data: content, encoding: .utf8) else {
            throw EditorDocumentError.unsupportedEncoding
        }
        let newline: EditorDocumentEncoding.Newline
        if raw.contains("\r\n") {
            newline = .carriageReturnLineFeed
        } else if raw.contains("\r") {
            newline = .carriageReturn
        } else {
            newline = .lineFeed
        }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return (normalized, .init(hasUTF8ByteOrderMark: hasBOM, newline: newline))
    }

    nonisolated private static func encode(
        _ text: String,
        encoding: EditorDocumentEncoding
    ) -> Data {
        let serialized = encoding.newline == .lineFeed
            ? text
            : text.replacingOccurrences(of: "\n", with: encoding.newline.rawValue)
        var data = Data()
        if encoding.hasUTF8ByteOrderMark {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(serialized.data(using: .utf8)!)
        return data
    }
}
