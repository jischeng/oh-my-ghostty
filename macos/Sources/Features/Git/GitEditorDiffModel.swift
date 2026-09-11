import Combine
import Foundation

/// One cancellable load owns the file list and its selected file's snapshots.
/// Refresh always resolves the selection against a new list before reading it.
@MainActor
final class GitEditorDiffModel: ObservableObject {
    struct Content {
        let document: GitDiffDocument
        var before = ""
        var after = ""
        var presentation: GitDiffPresentation?
        var sourceError: String?
    }

    enum LoadingPhase { case idle, files, diff }

    @Published private(set) var files: [GitDiffFile] = []
    @Published private(set) var selected: GitDiffFile?
    @Published private(set) var content: Content?
    @Published private(set) var error: String?
    @Published private(set) var phase = LoadingPhase.idle
    var isLoading: Bool { phase != .idle }

    private let request: GitEditorDiffRequest
    private let service: GitDiffService
    private var task: Task<Void, Never>?
    private var commitBase: GitDiffCommitBase?

    init(request: GitEditorDiffRequest, service: GitDiffService = GitDiffService()) {
        self.request = request
        self.service = service
    }

    @discardableResult
    func reload() -> Task<Void, Never> {
        let path = selected?.path ?? request.file?.path
        files = []
        return startLoading(.files) {
            let list = try await self.service.listFiles(for: self.request.repository, target: self.request.target)
            try Task.checkCancellation()
            self.files = list.files
            self.commitBase = list.commitBase
            self.selected = path.flatMap { path in list.files.first { $0.path == path } } ?? list.files.first
            if let selected = self.selected {
                self.phase = .diff
                try await self.load(selected)
            }
        }
    }

    @discardableResult
    func select(_ file: GitDiffFile) -> Task<Void, Never>? {
        guard files.contains(file) else { return nil }
        selected = file
        return startLoading(.diff) { try await self.load(file) }
    }

    @discardableResult
    func selectAdjacentFile(offset: Int) -> Task<Void, Never>? {
        guard !files.isEmpty else { return nil }
        let current = selected.flatMap { files.firstIndex(of: $0) } ?? 0
        let index = max(0, min(files.count - 1, current + offset))
        guard index != current else { return nil }
        return select(files[index])
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func startLoading(
        _ phase: LoadingPhase,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        task?.cancel()
        self.phase = phase
        content = nil
        error = nil
        let task = Task {
            do {
                try await operation()
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self.phase = .idle
            self.task = nil
        }
        self.task = task
        return task
    }

    private func load(_ file: GitDiffFile) async throws {
        let document = try await service.loadDiff(for: file, repository: request.repository, target: request.target,
                                                  knownBase: commitBase)
        try Task.checkCancellation()
        var content = Content(document: document)
        if !document.isBinary && !document.isTruncated {
            do {
                let versions = try await service.sourceVersions(for: file, repository: request.repository,
                                                                target: request.target, knownBase: commitBase)
                try Task.checkCancellation()
                content.before = versions.before
                content.after = versions.after
                let presentation = GitDiffPresentation(before: versions.before, after: versions.after, patch: document.text)
                content.presentation = presentation
                if !presentation.isConsistent {
                    content.sourceError = GitL10n.text("Source snapshots do not match this patch. Refresh to retry; the patch is shown below.")
                }
            } catch {
                try Task.checkCancellation()
                content.sourceError = error.localizedDescription
            }
        }
        self.content = content
    }
}
