import Combine
import Foundation

/// One cancellable load owns the file list and its selected file's snapshots.
/// Refresh always resolves the selection against a new list before reading it.
@MainActor
final class GitEditorDiffModel: ObservableObject {
    struct Content: Equatable {
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
        let optimisticFile = selected ?? request.file
        let path = optimisticFile?.path
        let knownCommitBase = commitBase
        let shouldPreloadOptimistic: Bool = {
            guard optimisticFile != nil else { return false }
            if case .commit(let commit) = request.target {
                return knownCommitBase?.commit == commit
            }
            return true
        }()
        files = []
        return startLoading(.files) {
            let optimisticTask: Task<Content, Error>? = if shouldPreloadOptimistic, let optimisticFile {
                Task { @MainActor in
                    try await self.loadContent(for: optimisticFile, knownBase: knownCommitBase)
                }
            } else {
                nil
            }
            defer { optimisticTask?.cancel() }

            let list = try await self.service.listFiles(for: self.request.repository, target: self.request.target)
            try Task.checkCancellation()
            self.files = list.files
            self.commitBase = list.commitBase
            self.selected = path.flatMap { path in list.files.first { $0.path == path } } ?? list.files.first
            guard let selected = self.selected else {
                optimisticTask?.cancel()
                return
            }
            self.phase = .diff
            if let optimisticTask, let optimisticFile, selected == optimisticFile {
                let loaded = try await optimisticTask.value
                try Task.checkCancellation()
                self.content = loaded
            } else {
                optimisticTask?.cancel()
                let loaded = try await self.loadContent(for: selected, knownBase: self.commitBase)
                try Task.checkCancellation()
                self.content = loaded
            }
        }
    }

    @discardableResult
    func select(_ file: GitDiffFile) -> Task<Void, Never>? {
        guard files.contains(file) else { return nil }
        selected = file
        let knownCommitBase = commitBase
        return startLoading(.diff) {
            let loaded = try await self.loadContent(for: file, knownBase: knownCommitBase)
            try Task.checkCancellation()
            self.content = loaded
        }
    }

    @discardableResult
    func selectAdjacentFile(offset: Int) -> Task<Void, Never>? {
        guard !files.isEmpty else { return nil }
        let current = selected.flatMap { files.firstIndex(of: $0) } ?? 0
        let index = ((current + offset) % files.count + files.count) % files.count
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

    private func loadContent(
        for file: GitDiffFile,
        knownBase: GitDiffCommitBase?
    ) async throws -> Content {
        let repository = request.repository
        let target = request.target
        let service = self.service
        let versionsTask = Task {
            try await service.sourceVersions(
                for: file,
                repository: repository,
                target: target,
                knownBase: knownBase
            )
        }
        defer { versionsTask.cancel() }

        let document = try await service.loadDiff(
            for: file,
            repository: repository,
            target: target,
            knownBase: knownBase
        )
        try Task.checkCancellation()
        var content = Content(document: document)
        if !document.isBinary && !document.isTruncated {
            do {
                let versions = try await versionsTask.value
                try Task.checkCancellation()
                content.before = versions.before
                content.after = versions.after
                let presentation = GitDiffPresentation(
                    before: versions.before,
                    after: versions.after,
                    patch: document.text
                )
                content.presentation = presentation
                if !presentation.isConsistent {
                    content.sourceError = GitL10n.text("Source snapshots do not match this patch. Refresh to retry; the patch is shown below.")
                }
            } catch {
                try Task.checkCancellation()
                content.sourceError = error.localizedDescription
            }
        }
        return content
    }
}
