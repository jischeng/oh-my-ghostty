import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class GitDetailWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [UUID: GitDetailWindowController] = [:]

    private let viewModel: GitDiffDetailViewModel
    private let tabID: UUID

    /// Opens one reusable detail window for each terminal tab. The repository and target
    /// are copied into the view model when this method is called; later cwd changes do not
    /// mutate an already-open window.
    static func open(
        repository: GitRepositoryIdentity,
        target: GitDiffTarget,
        tabID: UUID,
        service: GitDiffService = GitDiffService()
    ) {
        if let existing = controllers[tabID] {
            existing.viewModel.configure(repository: repository, target: target)
            existing.presentWindow()
            return
        }

        let controller = GitDetailWindowController(
            repository: repository,
            target: target,
            tabID: tabID,
            service: service
        )
        controllers[tabID] = controller
        controller.presentWindow()
    }

    private init(
        repository: GitRepositoryIdentity,
        target: GitDiffTarget,
        tabID: UUID,
        service: GitDiffService
    ) {
        self.tabID = tabID
        self.viewModel = GitDiffDetailViewModel(
            repository: repository,
            target: target,
            service: service
        )

        let rootView = GitDiffDetailView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Git Diff"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 640))
        window.minSize = NSSize(width: 680, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        viewModel.reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.cancel()
        Self.controllers.removeValue(forKey: tabID)
    }

    private func presentWindow() {
        guard let window else { return }
        window.title = "Git Diff — \(viewModel.repository.repositoryName)"
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class GitDiffDetailViewModel: ObservableObject {
    @Published private(set) var repository: GitRepositoryIdentity
    @Published private(set) var target: GitDiffTarget
    @Published private(set) var files: [GitDiffFile] = []
    @Published private(set) var selectedFileID: String?
    @Published private(set) var document: GitDiffDocument?
    @Published private(set) var isLoadingFiles = false
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var baseDescription = ""
    @Published private(set) var commitMetadata: GitCommitMetadata?

    private let service: GitDiffService
    private var filesTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    init(repository: GitRepositoryIdentity, target: GitDiffTarget, service: GitDiffService) {
        self.repository = repository
        self.target = target
        self.service = service
    }

    func configure(repository: GitRepositoryIdentity, target: GitDiffTarget) {
        guard self.repository != repository || self.target != target else {
            reload()
            return
        }
        self.repository = repository
        self.target = target
        files = []
        selectedFileID = nil
        document = nil
        commitMetadata = nil
        reload()
    }

    func reload() {
        filesTask?.cancel()
        diffTask?.cancel()
        isLoadingFiles = true
        isLoadingDiff = false
        errorMessage = nil
        filesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await service.listFiles(for: repository, target: target)
                guard !Task.isCancelled else { return }
                let metadata: GitCommitMetadata? = switch target {
                case .commit(let commit):
                    try await service.loadCommitMetadata(for: commit, repository: repository)
                case .staged, .unstaged:
                    nil
                }
                guard !Task.isCancelled else { return }
                files = list.files
                baseDescription = list.baseDescription
                commitMetadata = metadata
                isLoadingFiles = false
                if let selectedFileID, let selected = files.first(where: { $0.id == selectedFileID }) {
                    select(selected)
                } else if let first = files.first {
                    select(first)
                } else {
                    selectedFileID = nil
                    document = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingFiles = false
                errorMessage = error.localizedDescription
                files = []
                document = nil
            }
        }
    }

    func select(_ file: GitDiffFile) {
        selectedFileID = file.id
        document = nil
        diffTask?.cancel()
        isLoadingDiff = true
        errorMessage = nil
        let repository = repository
        let target = target
        let baseDescription = baseDescription
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.loadDiff(
                    for: file,
                    repository: repository,
                    target: target,
                    baseDescription: baseDescription
                )
                guard !Task.isCancelled else { return }
                document = loaded
                isLoadingDiff = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingDiff = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        filesTask?.cancel()
        diffTask?.cancel()
    }
}

private struct GitDiffDetailView: View {
    @ObservedObject var viewModel: GitDiffDetailViewModel

    var body: some View {
        VStack(spacing: 0) {
            commitMetadataView
            HSplitView {
                fileList
                    .frame(minWidth: 220, idealWidth: 290, maxWidth: 420)
                detail
                    .frame(minWidth: 420)
            }
        }
        .frame(minWidth: 680, minHeight: 360)
    }

    @ViewBuilder
    private var commitMetadataView: some View {
        if let metadata = viewModel.commitMetadata {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metadata.subject)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(metadata.commitID.shortSHA)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Label(metadata.authorDescription, systemImage: "person")
                    Label(metadata.authoredAt, systemImage: "calendar")
                    if !metadata.parents.isEmpty {
                        Label(
                            "Parents: \(metadata.parents.map(\.shortSHA).joined(separator: ", "))",
                            systemImage: "arrow.turn.up.left"
                        )
                    } else {
                        Label("Root commit", systemImage: "sparkles")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    Text(metadata.message)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.target.description)
                        .font(.headline)
                    Text(viewModel.repository.worktreePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: viewModel.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoadingFiles)
                .help("Refresh diff")
            }
            .padding(12)
            Divider()

            if viewModel.isLoadingFiles {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.files.isEmpty {
                GitDiffEmptyState(
                    title: "No Changes",
                    systemImage: "checkmark.circle",
                    message: "The selected Git target has no changed files."
                )
            } else {
                List(viewModel.files, selection: Binding(
                    get: { viewModel.selectedFileID },
                    set: { id in
                        guard let id, let file = viewModel.files.first(where: { $0.id == id }) else { return }
                        viewModel.select(file)
                    }
                )) { file in
                    HStack(spacing: 7) {
                        Text(file.kind.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(for: file.kind))
                            .frame(width: 15)
                        Text(file.displayPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(file.id)
                    .help(file.displayPath)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack {
                if let document = viewModel.document {
                    Text(document.file.displayPath)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(document.baseDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if document.isBinary {
                        Label("Binary", systemImage: "doc.zipper")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if document.isTruncated {
                        Label("Truncated", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Diff")
                        .font(.headline)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            if viewModel.isLoadingDiff {
                ProgressView("Loading selected file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage {
                GitDiffEmptyState(
                    title: "Unable to load diff",
                    systemImage: "exclamationmark.triangle",
                    message: message
                )
            } else if let document = viewModel.document {
                GitDiffTextView(text: document.text)
            } else {
                GitDiffEmptyState(
                    title: "Select a file",
                    systemImage: "doc.text.magnifyingglass",
                    message: nil
                )
            }
        }
    }

    private func color(for kind: GitDiffChangeKind) -> Color {
        switch kind {
        case .added: .green
        case .deleted: .red
        case .renamed, .copied: .orange
        default: .secondary
        }
    }
}

private struct GitDiffEmptyState: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private struct GitDiffTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textStorage?.setAttributedString(GitDiffTextRenderer.render(text))
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let rendered = GitDiffTextRenderer.render(text)
        guard textView.attributedString() != rendered else { return }
        textView.textStorage?.setAttributedString(rendered)
    }
}

enum GitDiffTextRenderer {
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff ") { inHunk = false }
            let isHunk = line.hasPrefix("@@")
            if isHunk {
                updateLineNumbers(from: line, old: &oldLine, new: &newLine)
                inHunk = true
            }
            let isMetadata = !inHunk && (
                line.hasPrefix("diff ") ||
                line.hasPrefix("index ") ||
                line.hasPrefix("---") ||
                line.hasPrefix("+++") ||
                line.hasPrefix("Binary files ")
            )
            let isAdded = inHunk && line.hasPrefix("+")
            let isDeleted = inHunk && line.hasPrefix("-")
            let hasLineNumber = inHunk && !isHunk && !isMetadata && !line.hasPrefix("\\")

            let oldNumber = hasLineNumber && !isAdded && !isHunk ? oldLine : nil
            let newNumber = hasLineNumber && !isDeleted && !isHunk ? newLine : nil
            if isAdded { newLine += 1 } else if isDeleted { oldLine += 1 } else if !isHunk && !isMetadata && !line.hasPrefix("\\") { oldLine += 1; newLine += 1 }

            let prefix = "\(number(oldNumber)) \(number(newNumber)) │ "
            let output = prefix + line + (index + 1 < lines.count ? "\n" : "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: isAdded ? NSColor.systemGreen : (isDeleted ? NSColor.systemRed : (isHunk ? NSColor.systemBlue : NSColor.labelColor)),
                .backgroundColor: isAdded ? NSColor.systemGreen.withAlphaComponent(0.08) : (isDeleted ? NSColor.systemRed.withAlphaComponent(0.08) : NSColor.textBackgroundColor),
            ]
            result.append(NSAttributedString(string: output, attributes: attributes))
        }
        return result
    }

    private static func updateLineNumbers(from line: String, old: inout Int, new: inout Int) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }
        old = Int(parts[1].dropFirst().split(separator: ",", maxSplits: 1).first ?? "") ?? 0
        new = Int(parts[2].dropFirst().split(separator: ",", maxSplits: 1).first ?? "") ?? 0
    }

    private static func number(_ value: Int?) -> String {
        guard let value else { return "    " }
        let string = String(value)
        return String(repeating: " ", count: max(0, 4 - string.count)) + string
    }
}
