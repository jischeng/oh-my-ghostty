import AppKit
import Combine

/// Fuzzy matcher and bounded workspace file walker powering `⌘P` / `⌘O` Quick Open.
enum EditorQuickOpenSearch {
    static let maxLocalFiles = 6_000
    static let maxRemoteDirectories = 48
    static let maxRemoteFiles = 2_000
    static let maxDepth = 10

    static func shouldSkipDirectory(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".git"
            || lower == "node_modules"
            || lower == ".hg"
            || lower == ".svn"
            || lower == ".ds_store"
            || lower == ".build"
            || lower == "deriveddata"
            || lower == "target"
            || lower == "__pycache__"
            || lower == ".venv"
            || lower == "venv"
            || lower == ".next"
            || lower == ".cache" {
            return true
        }
        if lower.hasPrefix("zig-") || lower == ".zig-cache" || lower.hasPrefix("build") {
            return true
        }
        return false
    }

    static func rank(
        files: [WorkspaceFileEntry],
        query: String,
        rootDirectory: String,
        limit: Int = 200
    ) -> [WorkspaceFileEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let normalizedQuery = trimmed.lowercased()
        let rootPrefix = rootDirectory == "/"
            ? "/"
            : (rootDirectory.hasSuffix("/") ? rootDirectory : rootDirectory + "/")

        var scored: [(entry: WorkspaceFileEntry, score: Int, relativeLength: Int)] = []
        scored.reserveCapacity(min(files.count, 512))

        for entry in files where !entry.isDirectory {
            let relativePath: String
            if entry.path.hasPrefix(rootPrefix) {
                relativePath = String(entry.path.dropFirst(rootPrefix.count))
            } else {
                relativePath = entry.path
            }
            guard let score = fuzzyScore(
                query: normalizedQuery,
                fileName: entry.name,
                relativePath: relativePath
            ) else {
                continue
            }
            scored.append((entry, score, relativePath.utf8.count))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.relativeLength != rhs.relativeLength {
                return lhs.relativeLength < rhs.relativeLength
            }
            return lhs.entry.path.localizedStandardCompare(rhs.entry.path) == .orderedAscending
        }

        return scored.prefix(limit).map(\.entry)
    }

    static func fuzzyScore(query: String, fileName: String, relativePath: String) -> Int? {
        let lowerName = fileName.lowercased()
        let lowerPath = relativePath.lowercased()

        if lowerName == query {
            return 10_000
        }
        if lowerName.hasPrefix(query) {
            return 8_000 - max(0, lowerName.count - query.count) * 4
        }
        if let nameSubsequenceScore = subsequenceScore(query: query, candidate: fileName, lowerCandidate: lowerName) {
            return 4_000 + nameSubsequenceScore
        }
        if let pathSubsequenceScore = subsequenceScore(query: query, candidate: relativePath, lowerCandidate: lowerPath) {
            return 1_000 + pathSubsequenceScore
        }
        return nil
    }

    private static func subsequenceScore(query: String, candidate: String, lowerCandidate: String) -> Int? {
        let qBytes = Array(query.utf8)
        let cLower = Array(lowerCandidate.utf8)
        let cOrig = Array(candidate.utf8)
        guard !qBytes.isEmpty, qBytes.count <= cLower.count else { return nil }

        var qIdx = 0
        var score = 0
        var lastMatchIndex = -2

        for cIdx in 0..<cLower.count where qIdx < qBytes.count {
            if cLower[cIdx] == qBytes[qIdx] {
                score += 20
                if cIdx == lastMatchIndex + 1 {
                    score += 35 // consecutive character bonus
                }
                if cIdx == 0 {
                    score += 30
                } else {
                    let prev = cOrig[cIdx - 1]
                    let curr = cOrig[cIdx]
                    let isBoundary = prev == UInt8(ascii: "/")
                        || prev == UInt8(ascii: "_")
                        || prev == UInt8(ascii: "-")
                        || prev == UInt8(ascii: ".")
                        || (curr >= UInt8(ascii: "A") && curr <= UInt8(ascii: "Z")
                            && prev >= UInt8(ascii: "a") && prev <= UInt8(ascii: "z"))
                    if isBoundary {
                        score += 28
                    }
                }
                lastMatchIndex = cIdx
                qIdx += 1
            }
        }

        guard qIdx == qBytes.count else { return nil }
        return score - max(0, cLower.count - qBytes.count)
    }

    static func collectLocalFiles(rootDirectory: String) -> [WorkspaceFileEntry] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
        var results: [WorkspaceFileEntry] = []
        results.reserveCapacity(512)

        func walk(_ dirURL: URL, depth: Int) {
            guard !Task.isCancelled, depth <= maxDepth, results.count < maxLocalFiles else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { return }

            for child in children {
                if Task.isCancelled || results.count >= maxLocalFiles { return }
                let name = child.lastPathComponent
                if name == ".DS_Store" { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if shouldSkipDirectory(name) { continue }
                    walk(child, depth: depth + 1)
                } else {
                    results.append(WorkspaceFileEntry(path: child.path, name: name, isDirectory: false))
                }
            }
        }

        walk(rootURL, depth: 0)
        return results
    }

    static func collectFilesystemFiles(
        rootDirectory: String,
        filesystem: any WorkspaceFilesystem
    ) async -> [WorkspaceFileEntry] {
        if filesystem.descriptor.kind == .local {
            return await Task.detached(priority: .userInitiated) {
                collectLocalFiles(rootDirectory: rootDirectory)
            }.value
        }

        var queue: [(path: String, depth: Int)] = [(rootDirectory, 0)]
        var visitedDirs = 0
        var files: [WorkspaceFileEntry] = []

        while !queue.isEmpty,
              !Task.isCancelled,
              visitedDirs < maxRemoteDirectories,
              files.count < maxRemoteFiles {
            let current = queue.removeFirst()
            visitedDirs += 1
            guard let children = try? await filesystem.listDirectory(at: current.path) else {
                continue
            }
            for entry in children {
                if Task.isCancelled || files.count >= maxRemoteFiles { break }
                if entry.isDirectory {
                    if current.depth + 1 <= maxDepth, !shouldSkipDirectory(entry.name) {
                        queue.append((entry.path, current.depth + 1))
                    }
                } else if entry.name != ".DS_Store" {
                    files.append(entry)
                }
            }
        }
        return files
    }
}

@MainActor
final class EditorFilePicker: NSWindowController {
    private let parentWindow: NSWindow
    private let onOpen: (String) -> Void
    private let model: EditorFilePickerModel

    static func present(
        filesystem: any WorkspaceFilesystem,
        for parentWindow: NSWindow,
        onOpen: @escaping (String) -> Void
    ) {
        let picker = EditorFilePicker(
            filesystem: filesystem,
            parentWindow: parentWindow,
            onOpen: onOpen
        )
        guard let window = picker.window else { return }
        parentWindow.beginSheet(window) { _ in
            picker.model.cancelLoading()
        }
    }

    private init(
        filesystem: any WorkspaceFilesystem,
        parentWindow: NSWindow,
        onOpen: @escaping (String) -> Void
    ) {
        self.parentWindow = parentWindow
        self.onOpen = onOpen
        let model = EditorFilePickerModel(filesystem: filesystem)
        self.model = model
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Open — \(filesystem.descriptor.displayName)"
        super.init(window: panel)
        let browseSystem: (() -> Void)? = filesystem.descriptor.kind == .local ? { [weak self] in
            self?.presentSystemOpenPanel(initialDirectory: model.directory)
        } : nil
        let content = EditorFilePickerController(
            model: model,
            onCancel: { [weak self] in self?.finish() },
            onOpen: { [weak self] path in self?.finish(opening: path) },
            onBrowseSystem: browseSystem
        )
        panel.contentViewController = content
        (content.view as? OMGNativeSurfaceView)?.bindTheme(to: parentWindow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func presentSystemOpenPanel(initialDirectory: String) {
        guard let sheetWindow = window else { return }
        let hostWindow = parentWindow
        let callback = onOpen
        model.cancelLoading()
        hostWindow.endSheet(sheetWindow)
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: initialDirectory)
            panel.beginSheetModal(for: hostWindow) { response in
                guard response == .OK, let url = panel.url else { return }
                callback(url.path)
            }
        }
    }

    private func finish(opening path: String? = nil) {
        guard let window else { return }
        model.cancelLoading()
        parentWindow.endSheet(window)
        if let path { onOpen(path) }
    }
}

@MainActor
final class EditorFilePickerModel: ObservableObject {
    @Published private(set) var directory: String
    @Published var pathInput: String = ""
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            applySearchQueryChange()
        }
    }
    @Published private(set) var entries: [WorkspaceFileEntry] = []
    @Published var selection: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    let filesystem: any WorkspaceFilesystem
    private var directoryEntries: [WorkspaceFileEntry] = []
    private var indexedRootDirectory: String?
    private var indexedWorkspaceFiles: [WorkspaceFileEntry]?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(filesystem: any WorkspaceFilesystem) {
        self.filesystem = filesystem
        let initialDir = filesystem.descriptor.workingDirectory
        self.directory = initialDir
        self.pathInput = initialDir
        load(initialDir)
    }

    var isFuzzySearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedEntry: WorkspaceFileEntry? {
        entries.first { $0.path == selection }
    }

    var canGoUp: Bool { directory != "/" }

    func relativeDisplayPath(for entry: WorkspaceFileEntry) -> String? {
        guard isFuzzySearchActive else { return nil }
        let prefix = directory == "/" ? "/" : (directory.hasSuffix("/") ? directory : directory + "/")
        if entry.path.hasPrefix(prefix) {
            let rel = String(entry.path.dropFirst(prefix.count))
            let parent = (rel as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : parent
        }
        return (entry.path as NSString).deletingLastPathComponent
    }

    func open(_ entry: WorkspaceFileEntry, fileHandler: (String) -> Void) {
        if entry.isDirectory {
            if !searchQuery.isEmpty {
                searchQuery = ""
            }
            load(entry.path)
        } else {
            fileHandler(entry.path)
        }
    }

    func goUp() {
        guard canGoUp else { return }
        if !searchQuery.isEmpty {
            searchQuery = ""
        }
        let parent = (directory as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    func retry() {
        if isFuzzySearchActive {
            indexedWorkspaceFiles = nil
            applySearchQueryChange()
        } else {
            load(directory)
        }
    }

    func navigate(to input: String, fileHandler: @escaping (String) -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: String
        if trimmed.hasPrefix("/") {
            target = (trimmed as NSString).standardizingPath
        } else {
            target = ((directory as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
        }
        if let file = entries.first(where: { $0.path == target && !$0.isDirectory }) {
            fileHandler(file.path)
            return
        }
        if let dir = entries.first(where: { $0.path == target && $0.isDirectory }) {
            load(dir.path)
            return
        }
        directory = target
        pathInput = target
        loadTask?.cancel()
        searchTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            if let type = try? await filesystem.itemType(at: target) {
                guard !Task.isCancelled, directory == target else { return }
                if type == .file {
                    isLoading = false
                    fileHandler(target)
                    return
                }
            }
            guard !Task.isCancelled, directory == target else { return }
            load(target)
        }
    }

    func openSelection(fileHandler: (String) -> Void) {
        guard let selectedEntry else { return }
        open(selectedEntry, fileHandler: fileHandler)
    }

    func moveSelection(delta: Int) {
        guard !entries.isEmpty else { return }
        let currentIndex = selection.flatMap { sel in entries.firstIndex(where: { $0.path == sel }) } ?? -1
        let nextIndex: Int
        if currentIndex < 0 {
            nextIndex = delta >= 0 ? 0 : entries.count - 1
        } else {
            nextIndex = min(max(currentIndex + delta, 0), entries.count - 1)
        }
        selection = entries[nextIndex].path
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func applySearchQueryChange() {
        searchTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            entries = directoryEntries
            if let selection, !entries.contains(where: { $0.path == selection }) {
                self.selection = nil
            }
            return
        }

        let targetRoot = directory
        if indexedRootDirectory == targetRoot, let cached = indexedWorkspaceFiles {
            let ranked = EditorQuickOpenSearch.rank(files: cached, query: trimmed, rootDirectory: targetRoot)
            entries = ranked
            selection = ranked.first?.path
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        let fs = filesystem
        searchTask = Task { @MainActor [weak self] in
            let collected = await EditorQuickOpenSearch.collectFilesystemFiles(
                rootDirectory: targetRoot,
                filesystem: fs
            )
            guard let self, !Task.isCancelled, self.directory == targetRoot else { return }
            self.indexedRootDirectory = targetRoot
            self.indexedWorkspaceFiles = collected
            let activeQuery = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !activeQuery.isEmpty else {
                self.isSearching = false
                self.entries = self.directoryEntries
                return
            }
            let ranked = EditorQuickOpenSearch.rank(
                files: collected,
                query: activeQuery,
                rootDirectory: targetRoot
            )
            self.entries = ranked
            self.selection = ranked.first?.path
            self.isSearching = false
        }
    }

    private func load(_ path: String) {
        loadTask?.cancel()
        searchTask?.cancel()
        isSearching = false
        if indexedRootDirectory != path {
            indexedRootDirectory = nil
            indexedWorkspaceFiles = nil
        }
        directory = path
        pathInput = path
        directoryEntries = []
        entries = []
        selection = nil
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await filesystem.listDirectory(at: path)
                guard !Task.isCancelled, directory == path else { return }
                directoryEntries = result
                if !isFuzzySearchActive {
                    entries = result
                }
            } catch {
                guard !Task.isCancelled, directory == path else { return }
                directoryEntries = []
                if !isFuzzySearchActive {
                    entries = []
                }
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled, directory == path else { return }
            isLoading = false
            if isFuzzySearchActive {
                applySearchQueryChange()
            }
        }
    }
}

@MainActor
final class EditorFilePickerController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate,
    NSSearchFieldDelegate {
    private let model: EditorFilePickerModel
    let onCancel: () -> Void
    let onOpen: (String) -> Void
    let onBrowseSystem: (() -> Void)?
    let searchField = NSSearchField()
    let pathField = OMGNativeTextField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NativeProgressIndicator()
    private let goUpButton = NativeActionControl()
    private let retryButton = NativeActionControl()
    private let browseButton = NativeActionControl()
    private let openButton = NativeActionControl()
    private var cancellables = Set<AnyCancellable>()
    private var isSynchronizingSelection = false
    private var renderedEntries: [WorkspaceFileEntry] = []
    private var renderedFuzzyMode = false
    private var renderedDirectory: String?

    init(
        model: EditorFilePickerModel,
        onCancel: @escaping () -> Void,
        onOpen: @escaping (String) -> Void,
        onBrowseSystem: (() -> Void)? = nil
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onOpen = onOpen
        self.onBrowseSystem = onBrowseSystem
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setFrameSize(NSSize(width: 640, height: 480))
        view = root

        searchField.placeholderString = "Search files by name (⌘P)…"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Quick Open Search")

        let pathBar = NSStackView()
        pathBar.orientation = .horizontal
        pathBar.spacing = 8
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        goUpButton.title = ""
        retryButton.title = "Retry"
        retryButton.controlStyle = .bordered
        browseButton.title = "Browse…"
        browseButton.controlStyle = .bordered
        browseButton.target = self
        browseButton.action = #selector(browseSystem)
        browseButton.isHidden = onBrowseSystem == nil
        openButton.title = "Open"
        openButton.controlStyle = .prominent
        goUpButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Parent Directory")
        goUpButton.bezelStyle = .toolbar
        goUpButton.target = self
        goUpButton.action = #selector(goUp)
        goUpButton.setAccessibilityLabel("Parent Directory")
        pathField.placeholderString = "Path"
        pathField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pathField.delegate = self
        pathBar.addArrangedSubview(goUpButton)
        pathBar.addArrangedSubview(pathField)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        pathBar.addArrangedSubview(spinner)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        scrollView.drawsBackground = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.setAccessibilityLabel("Files")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isHidden = true

        let cancelButton = NativeActionControl()
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.controlStyle = .bordered
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSelection)
        openButton.keyEquivalent = "\r"
        openButton.bezelStyle = .rounded
        openButton.keyEquivalentModifierMask = []

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [retryButton, browseButton, spacer, cancelButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(pathBar)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            pathBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            pathBar.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        bindModel()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { renderedEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry-cell")
        guard renderedEntries.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EditorFilePickerCell
            ?? EditorFilePickerCell()
        cell.identifier = identifier
        let entry = renderedEntries[row]
        cell.configure(entry, subtitle: model.relativeDisplayPath(for: entry))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizingSelection else { return }
        let row = tableView.selectedRow
        model.selection = renderedEntries.indices.contains(row) ? renderedEntries[row].path : nil
        renderButtons()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === searchField {
            model.searchQuery = searchField.stringValue
        } else if field === pathField {
            model.pathInput = pathField.stringValue
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === pathField else { return }
        model.pathInput = field.stringValue
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        guard movement == NSReturnTextMovement else { return }
        model.navigate(to: field.stringValue, fileHandler: onOpen)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            model.moveSelection(delta: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            model.moveSelection(delta: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if model.selectedEntry != nil, !model.isLoading, !model.isSearching {
                openSelection()
                return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                model.searchQuery = ""
                return true
            }
            cancel()
            return true
        }
        return false
    }

    private func bindModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)
    }

    private func render() {
        guard isViewLoaded else { return }
        let navigated = renderedDirectory != model.directory
        renderedDirectory = model.directory
        if navigated || pathField.currentEditor() == nil, pathField.stringValue != model.pathInput {
            pathField.stringValue = model.pathInput
        }
        if searchField.currentEditor() == nil, searchField.stringValue != model.searchQuery {
            searchField.stringValue = model.searchQuery
        }
        let busy = model.isLoading || model.isSearching
        goUpButton.isEnabled = model.canGoUp && !busy
        if busy { spinner.setAnimating(true) } else { spinner.setAnimating(false) }
        let fuzzyMode = model.isFuzzySearchActive
        let entriesChanged = renderedEntries != model.entries || renderedFuzzyMode != fuzzyMode
        isSynchronizingSelection = true
        if entriesChanged {
            renderedEntries = model.entries
            renderedFuzzyMode = fuzzyMode
            tableView.reloadData()
        }
        if let selection = model.selection,
           let row = model.entries.firstIndex(where: { $0.path == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        isSynchronizingSelection = false
        renderStatus()
        renderButtons()
    }

    private func renderStatus() {
        if let error = model.errorMessage {
            statusLabel.stringValue = "Could Not Open Directory\n\(error)"
            statusLabel.isHidden = false
            retryButton.isHidden = false
            scrollView.isHidden = true
        } else if model.isLoading || (model.isSearching && model.entries.isEmpty) {
            statusLabel.stringValue = model.isSearching ? "Searching workspace…" : "Loading…"
            statusLabel.isHidden = false
            retryButton.isHidden = true
            scrollView.isHidden = true
        } else if model.entries.isEmpty {
            statusLabel.stringValue = model.isFuzzySearchActive
                ? "No matching files found."
                : "This directory is empty."
            statusLabel.isHidden = false
            retryButton.isHidden = true
            scrollView.isHidden = true
        } else {
            statusLabel.isHidden = true
            retryButton.isHidden = true
            scrollView.isHidden = false
        }
    }

    private func renderButtons() {
        openButton.isEnabled = model.selectedEntry != nil && !model.isLoading && !model.isSearching
    }

    @objc private func goUp() { model.goUp() }
    @objc private func retry() { model.retry() }
    @objc private func browseSystem() { onBrowseSystem?() }
    @objc func cancel() { onCancel() }
    @objc func openSelection() {
        guard !model.isLoading, !model.isSearching else { return }
        model.openSelection(fileHandler: onOpen)
    }
}

private final class EditorFilePickerCell: NSTableCellView {
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingHead
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = true

        let stack = NSStackView(views: [icon, label, subtitleLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ entry: WorkspaceFileEntry, subtitle: String?) {
        imageView?.image = NSImage(
            systemSymbolName: entry.isDirectory ? "folder" : "doc",
            accessibilityDescription: nil
        )
        textField?.stringValue = entry.name
        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.stringValue = ""
            subtitleLabel.isHidden = true
        }
        toolTip = entry.path
    }
}
