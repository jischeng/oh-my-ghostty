import Foundation

/// Zero-process instant code intelligence & workspace symbol index.
///
/// Works offline, when no LSP server is installed, and across open SSH buffers (never touching local
/// `FileManager` when `workspaceRoot` is `nil`). For local workspaces, performs a bounded background
/// scan (mtime-cached, <= 512 KB per file, <= 4,000 files, skipping `.git`, `node_modules`, `zig-cache`,
/// `zig-out`, `build*`, `.build`, `target`, and binary files).
actor EditorSymbolIndex {
    static let maxFileSizeBytes = 512 * 1_024
    static let maxIndexedFiles = 4_000

    struct AnnotatedSymbol: Equatable, Sendable {
        let symbol: EditorDocumentSymbol
        let documentation: String?
        let signatureLine: String
    }

    private struct CachedFileEntry: Sendable {
        let modificationDate: Date
        let fileSize: Int
        let languageID: String
        let symbols: [AnnotatedSymbol]
    }

    private struct OpenBufferEntry: Sendable {
        let path: String
        let languageID: String
        let text: String
        let symbols: [AnnotatedSymbol]
    }

    private struct WorkspaceFileCandidate: Sendable {
        let path: String
        let modificationDate: Date
        let fileSize: Int
    }

    private struct CachedDirectoryWalk: Sendable {
        let scannedAt: Date
        let files: [WorkspaceFileCandidate]
    }

    private static let exactSkippedDirectories: Set<String> = [
        ".git", ".hg", ".svn",
        "node_modules",
        "zig-cache", ".zig-cache", "zig-out",
        ".build", "target",
        "DerivedData", ".next", ".nuxt", ".turbo",
        "__pycache__", ".venv", "venv", ".mypy_cache", ".pytest_cache",
        "Pods", "Carthage"
    ]

    private var fileCache: [String: CachedFileEntry] = [:]
    private var directoryWalkCache: [String: CachedDirectoryWalk] = [:]
    private var openBuffers: [String: OpenBufferEntry] = [:]
    private let walkCacheTTL: TimeInterval

    init(walkCacheTTL: TimeInterval = 2.0) {
        self.walkCacheTTL = walkCacheTTL
    }

    // MARK: - Open Buffer Overlay (Local & SSH Safe)

    func updateOpenDocument(path: String, text: String, languageID: String? = nil) {
        let resolvedLanguage = EditorLanguageID.detect(path: path, explicitHint: languageID)
        let extracted = Self.extractAnnotatedSymbols(
            from: text,
            languageID: resolvedLanguage,
            filePath: path
        )
        openBuffers[path] = OpenBufferEntry(
            path: path,
            languageID: resolvedLanguage,
            text: text,
            symbols: extracted
        )
    }

    func removeOpenDocument(path: String) {
        openBuffers.removeValue(forKey: path)
    }

    func clearOpenDocuments() {
        openBuffers.removeAll()
    }

    func invalidateWorkspaceCache(workspaceRoot: String? = nil) {
        if let workspaceRoot {
            let root = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
            directoryWalkCache.removeValue(forKey: root)
            let prefix = root == "/" ? "/" : root + "/"
            fileCache = fileCache.filter { !$0.key.hasPrefix(prefix) }
        } else {
            directoryWalkCache.removeAll()
            fileCache.removeAll()
        }
    }

    // MARK: - Document Symbols (`⌘⇧O`)

    nonisolated static func extractSymbols(
        from text: String,
        languageID: String? = nil,
        filePath: String? = nil
    ) -> [EditorDocumentSymbol] {
        extractAnnotatedSymbols(from: text, languageID: languageID, filePath: filePath).map(\.symbol)
    }

    func documentSymbols(
        path: String,
        text: String,
        languageID: String? = nil
    ) -> [EditorDocumentSymbol] {
        let resolved = EditorLanguageID.detect(path: path, explicitHint: languageID)
        if let cachedOpen = openBuffers[path], cachedOpen.text == text {
            return cachedOpen.symbols.map(\.symbol)
        }
        let extracted = Self.extractAnnotatedSymbols(from: text, languageID: resolved, filePath: path)
        openBuffers[path] = OpenBufferEntry(path: path, languageID: resolved, text: text, symbols: extracted)
        return extracted.map(\.symbol)
    }

    // MARK: - Cross-File Go-to-Definition

    /// Resolves symbol definitions in `currentText`, open editor tabs, and (when `workspaceRoot` is non-nil)
    /// across the local workspace directory tree. Pass `workspaceRoot: nil` for SSH documents so local disk is untouched.
    func findDefinitions(
        symbol: String,
        currentPath: String,
        currentText: String,
        workspaceRoot: String?
    ) async -> [EditorDefinitionLocation] {
        let target = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }

        var results: [EditorDefinitionLocation] = []
        var seen = Set<EditorDefinitionLocation>()

        func appendMatches(from entries: [AnnotatedSymbol], path: String) {
            for entry in entries where entry.symbol.name == target {
                let location = EditorDefinitionLocation(
                    path: path,
                    range: entry.symbol.selectionRange,
                    preview: entry.signatureLine
                )
                if seen.insert(location).inserted {
                    results.append(location)
                }
            }
        }

        // 1. Current document first (highest relevance & lowest latency).
        let currentLanguage = EditorLanguageID.detect(path: currentPath)
        let currentSymbols = Self.extractAnnotatedSymbols(
            from: currentText,
            languageID: currentLanguage,
            filePath: currentPath
        )
        appendMatches(from: currentSymbols, path: currentPath)

        // 2. Other open buffers in memory (works for both Local and SSH!).
        let otherOpenPaths = openBuffers.keys.sorted().filter { $0 != currentPath }
        for path in otherOpenPaths {
            guard !Task.isCancelled else { return results }
            if let openEntry = openBuffers[path] {
                appendMatches(from: openEntry.symbols, path: path)
            }
        }

        // 3. Bounded local workspace scan (ONLY when a local workspaceRoot is provided).
        if let workspaceRoot, workspaceRoot.hasPrefix("/") {
            let indexed = await ensureWorkspaceIndexed(workspaceRoot: workspaceRoot)
            for candidate in indexed where candidate.path != currentPath && openBuffers[candidate.path] == nil {
                guard !Task.isCancelled else { return results }
                if let cached = fileCache[candidate.path] {
                    appendMatches(from: cached.symbols, path: candidate.path)
                }
            }
        }

        return results
    }

    // MARK: - Hover Fallback

    func hoverInfo(
        symbol: String,
        currentPath: String,
        currentText: String,
        workspaceRoot: String?
    ) async -> EditorHoverInfo? {
        let target = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        let currentLanguage = EditorLanguageID.detect(path: currentPath)
        let currentSymbols = Self.extractAnnotatedSymbols(
            from: currentText,
            languageID: currentLanguage,
            filePath: currentPath
        )
        if let hit = currentSymbols.first(where: { $0.symbol.name == target }) {
            return Self.formatHover(entry: hit, path: currentPath, languageID: currentLanguage, workspaceRoot: workspaceRoot)
        }

        for path in openBuffers.keys.sorted() where path != currentPath {
            if let openEntry = openBuffers[path],
               let hit = openEntry.symbols.first(where: { $0.symbol.name == target }) {
                return Self.formatHover(entry: hit, path: path, languageID: openEntry.languageID, workspaceRoot: workspaceRoot)
            }
        }

        if let workspaceRoot, workspaceRoot.hasPrefix("/") {
            let indexed = await ensureWorkspaceIndexed(workspaceRoot: workspaceRoot)
            for candidate in indexed where candidate.path != currentPath {
                if let cached = fileCache[candidate.path],
                   let hit = cached.symbols.first(where: { $0.symbol.name == target }) {
                    return Self.formatHover(
                        entry: hit,
                        path: candidate.path,
                        languageID: cached.languageID,
                        workspaceRoot: workspaceRoot
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Lexical References Fallback

    func findReferences(
        symbol: String,
        currentPath: String,
        currentText: String,
        workspaceRoot: String?
    ) async -> [EditorDefinitionLocation] {
        let target = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: target)
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_$])"# + escaped + #"(?![\p{L}\p{N}_$])"#) else {
            return []
        }

        var results: [EditorDefinitionLocation] = []
        let maxReferences = 200

        Self.collectWordOccurrences(in: currentText, path: currentPath, regex: regex, into: &results, limit: maxReferences)
        for path in openBuffers.keys.sorted() where path != currentPath && results.count < maxReferences {
            if let open = openBuffers[path] {
                Self.collectWordOccurrences(in: open.text, path: path, regex: regex, into: &results, limit: maxReferences)
            }
        }

        if let workspaceRoot, workspaceRoot.hasPrefix("/"), results.count < maxReferences {
            let candidates = await ensureWorkspaceIndexed(workspaceRoot: workspaceRoot)
            for candidate in candidates where candidate.path != currentPath && openBuffers[candidate.path] == nil {
                guard !Task.isCancelled, results.count < maxReferences else { break }
                guard let text = Self.readUTF8SourceFile(atPath: candidate.path, maxBytes: Self.maxFileSizeBytes),
                      text.contains(target) else {
                    continue
                }
                Self.collectWordOccurrences(in: text, path: candidate.path, regex: regex, into: &results, limit: maxReferences)
            }
        }
        return results
    }

    // MARK: - Cross-File Symbol Completions

    func workspaceCompletions(
        prefix: String,
        currentPath: String,
        workspaceRoot: String?,
        limit: Int = 25
    ) async -> [CompletionItem] {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return [] }
        let lowerPrefix = trimmedPrefix.lowercased()

        var bestByName: [String: CompletionItem] = [:]

        func consider(_ annotated: AnnotatedSymbol, path: String, isCurrentFile: Bool) {
            let name = annotated.symbol.name
            guard name.lowercased().hasPrefix(lowerPrefix), name != trimmedPrefix else { return }
            let exactCase = name.hasPrefix(trimmedPrefix)
            let baseScore: Double = isCurrentFile ? 145.0 : 135.0
            let score = baseScore + (exactCase ? 15.0 : 0.0)
            let kind = Self.completionKind(for: annotated.symbol.kind)
            let detail = annotated.symbol.detail ?? (path as NSString).lastPathComponent
            let candidate = CompletionItem(
                label: name,
                insertText: name,
                kind: kind,
                detail: detail,
                score: score
            )
            if let existing = bestByName[name], existing.score >= candidate.score {
                return
            }
            bestByName[name] = candidate
        }

        if let openCurrent = openBuffers[currentPath] {
            for entry in openCurrent.symbols {
                consider(entry, path: currentPath, isCurrentFile: true)
            }
        }

        for (path, openEntry) in openBuffers where path != currentPath {
            for entry in openEntry.symbols {
                consider(entry, path: path, isCurrentFile: false)
            }
        }

        if let workspaceRoot, workspaceRoot.hasPrefix("/") {
            let indexed = await ensureWorkspaceIndexed(workspaceRoot: workspaceRoot)
            for candidate in indexed where candidate.path != currentPath && openBuffers[candidate.path] == nil {
                guard !Task.isCancelled else { break }
                if let cached = fileCache[candidate.path] {
                    for entry in cached.symbols {
                        consider(entry, path: candidate.path, isCurrentFile: false)
                    }
                }
            }
        }

        return bestByName.values
            .sorted { $0.score == $1.score ? $0.label < $1.label : $0.score > $1.score }
            .prefix(max(1, limit))
            .map { $0 }
    }

    // MARK: - Identifier Extraction at Position

    struct WordHit: Equatable, Sendable {
        let word: String
        let range: EditorRange
    }

    nonisolated static func wordAtPosition(in text: String, position: EditorPosition) -> WordHit? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lineIndex = position.line - 1
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }

        let lineString = String(lines[lineIndex])
        let utf16 = Array(lineString.utf16)
        guard !utf16.isEmpty else { return nil }

        // Monaco column is 1-based; check character at `column - 1` first, then `column - 2` if cursor sits at word end.
        let targetCol = min(max(0, position.column - 1), utf16.count)
        let probeIndex: Int
        if targetCol < utf16.count, isIdentifierCodeUnit(utf16[targetCol]) {
            probeIndex = targetCol
        } else if targetCol > 0, targetCol - 1 < utf16.count, isIdentifierCodeUnit(utf16[targetCol - 1]) {
            probeIndex = targetCol - 1
        } else {
            return nil
        }

        var start = probeIndex
        while start > 0, isIdentifierCodeUnit(utf16[start - 1]) {
            start -= 1
        }
        var end = probeIndex + 1
        while end < utf16.count, isIdentifierCodeUnit(utf16[end]) {
            end += 1
        }
        let slice = Array(utf16[start..<end])
        let word = String(decoding: slice, as: UTF16.self)
        guard !word.isEmpty else { return nil }
        // Reject pure numbers.
        if word.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return nil
        }
        let range = EditorRange(
            startLine: position.line,
            startColumn: start + 1,
            endLine: position.line,
            endColumn: end + 1
        )
        return WordHit(word: word, range: range)
    }

    nonisolated private static func isIdentifierCodeUnit(_ unit: UInt16) -> Bool {
        if (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) {
            return true
        }
        if unit == 95 || unit == 36 { // '_' or '$'
            return true
        }
        if let scalar = UnicodeScalar(unit) {
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return false
    }

    // MARK: - Bounded Workspace Scanner & mtime Cache

    private func ensureWorkspaceIndexed(workspaceRoot: String) async -> [WorkspaceFileCandidate] {
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let rootPath = rootURL.path
        let now = Date()

        let candidates: [WorkspaceFileCandidate]
        if let cachedWalk = directoryWalkCache[rootPath],
           now.timeIntervalSince(cachedWalk.scannedAt) < walkCacheTTL {
            candidates = cachedWalk.files
        } else {
            let discovered = await Task.detached(priority: .utility) {
                Self.scanWorkspaceFiles(rootURL: rootURL)
            }.value
            directoryWalkCache[rootPath] = CachedDirectoryWalk(scannedAt: now, files: discovered)
            candidates = discovered
        }

        // Parse only uncached or mtime/size-changed files off-actor in batches.
        var toParse: [WorkspaceFileCandidate] = []
        for candidate in candidates {
            if let existing = fileCache[candidate.path],
               existing.modificationDate == candidate.modificationDate,
               existing.fileSize == candidate.fileSize {
                continue
            }
            toParse.append(candidate)
        }

        if !toParse.isEmpty {
            let parsedEntries: [(String, CachedFileEntry)] = await Task.detached(priority: .utility) {
                var built: [(String, CachedFileEntry)] = []
                built.reserveCapacity(toParse.count)
                for item in toParse {
                    if Task.isCancelled { break }
                    guard let text = Self.readUTF8SourceFile(
                        atPath: item.path,
                        maxBytes: Self.maxFileSizeBytes
                    ) else {
                        continue
                    }
                    let lang = EditorLanguageID.detect(path: item.path)
                    let symbols = Self.extractAnnotatedSymbols(
                        from: text,
                        languageID: lang,
                        filePath: item.path
                    )
                    let entry = CachedFileEntry(
                        modificationDate: item.modificationDate,
                        fileSize: item.fileSize,
                        languageID: lang,
                        symbols: symbols
                    )
                    built.append((item.path, entry))
                }
                return built
            }.value

            for (path, entry) in parsedEntries {
                fileCache[path] = entry
            }
        }

        return candidates
    }

    nonisolated static func shouldSkipDirectory(named name: String) -> Bool {
        if exactSkippedDirectories.contains(name) {
            return true
        }
        if name.hasPrefix("build") {
            return true
        }
        return false
    }

    nonisolated private static func scanWorkspaceFiles(rootURL: URL) -> [WorkspaceFileCandidate] {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        var collected: [WorkspaceFileCandidate] = []
        var directoryQueue: [URL] = [rootURL]
        var queueIndex = 0

        while queueIndex < directoryQueue.count, collected.count < maxIndexedFiles {
            if Task.isCancelled { break }
            let dirURL = directoryQueue[queueIndex]
            queueIndex += 1

            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            let sortedChildren = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for childURL in sortedChildren {
                if collected.count >= maxIndexedFiles || Task.isCancelled {
                    break
                }
                let name = childURL.lastPathComponent
                guard let values = try? childURL.resourceValues(forKeys: resourceKeys) else {
                    continue
                }
                if values.isSymbolicLink == true {
                    continue
                }
                if values.isDirectory == true {
                    if !shouldSkipDirectory(named: name) {
                        directoryQueue.append(childURL)
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0
                guard size > 0, size <= maxFileSizeBytes else { continue }
                let path = childURL.path
                guard EditorLanguageID.isIndexableSourceFile(path: path) else { continue }
                let mtime = values.contentModificationDate ?? .distantPast
                collected.append(
                    WorkspaceFileCandidate(
                        path: path,
                        modificationDate: mtime,
                        fileSize: size
                    )
                )
            }
        }

        return collected
    }

    nonisolated private static func readUTF8SourceFile(atPath path: String, maxBytes: Int) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1),
              data.count <= maxBytes else {
            return nil
        }
        // Reject binary files cleanly.
        let sample = data.prefix(8_192)
        let hasBinaryByte = sample.contains { byte in
            byte == 0 || byte < 0x08 || (byte > 0x0D && byte < 0x20)
        }
        guard !hasBinaryByte, let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        if raw.contains("\r") {
            return raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        return raw
    }

    // MARK: - Single-Pass Multi-Language Symbol Extractor

    nonisolated static func extractAnnotatedSymbols(
        from text: String,
        languageID: String? = nil,
        filePath: String? = nil
    ) -> [AnnotatedSymbol] {
        let resolvedLanguage = EditorLanguageID.detect(path: filePath ?? "", explicitHint: languageID)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if resolvedLanguage == "markdown" {
            return extractMarkdownSymbols(lines: lines)
        }
        return extractCodeSymbols(lines: lines, languageID: resolvedLanguage)
    }

    nonisolated private static func extractMarkdownSymbols(lines: [Substring]) -> [AnnotatedSymbol] {
        var symbols: [AnnotatedSymbol] = []
        var inCodeFence = false
        var fenceMarker: Substring = ""

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmedLeft = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedLeft.hasPrefix("```") || trimmedLeft.hasPrefix("~~~") {
                let marker = trimmedLeft.prefix(3)
                if !inCodeFence {
                    inCodeFence = true
                    fenceMarker = marker
                } else if marker == fenceMarker {
                    inCodeFence = false
                }
                continue
            }
            guard !inCodeFence, trimmedLeft.first == "#" else { continue }

            let hashes = trimmedLeft.prefix(while: { $0 == "#" })
            guard hashes.count <= 6 else { continue }
            let afterHashes = trimmedLeft.dropFirst(hashes.count)
            guard afterHashes.first == " " || afterHashes.first == "\t" else { continue }

            let rawTitle = afterHashes.trimmingCharacters(in: .whitespaces)
            let title = rawTitle.replacingOccurrences(
                of: #"\s+#+\s*$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }

            let lineStr = String(rawLine)
            let lineUTF16Len = lineStr.utf16.count
            let selectionRange = locateSubstringRange(
                substring: title,
                inLine: lineStr,
                lineNumber: lineNumber
            ) ?? EditorRange(
                startLine: lineNumber,
                startColumn: 1,
                endLine: lineNumber,
                endColumn: max(1, lineUTF16Len + 1)
            )
            let fullRange = EditorRange(
                startLine: lineNumber,
                startColumn: 1,
                endLine: lineNumber,
                endColumn: max(1, lineUTF16Len + 1)
            )
            let docSymbol = EditorDocumentSymbol(
                name: title,
                detail: "H\(hashes.count)",
                kind: .heading,
                range: fullRange,
                selectionRange: selectionRange
            )
            symbols.append(
                AnnotatedSymbol(
                    symbol: docSymbol,
                    documentation: nil,
                    signatureLine: lineStr.trimmingCharacters(in: .whitespaces)
                )
            )
        }
        return symbols
    }

    private struct ParsedDeclaration {
        let name: String
        let kind: EditorDocumentSymbol.SymbolKind
    }

    nonisolated private static func extractCodeSymbols(
        lines: [Substring],
        languageID: String
    ) -> [AnnotatedSymbol] {
        var results: [AnnotatedSymbol] = []
        var inBlockComment = false
        var recentDocLines: [String] = []

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let lineString = String(rawLine)
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)

            if inBlockComment {
                if let closeRange = trimmed.range(of: "*/") {
                    inBlockComment = false
                    let remainder = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if remainder.isEmpty { continue }
                } else {
                    continue
                }
            }

            if trimmed.isEmpty {
                recentDocLines.removeAll()
                continue
            }

            if trimmed.hasPrefix("/*") && !trimmed.contains("*/") {
                inBlockComment = true
                recentDocLines.removeAll()
                continue
            }

            if let docText = extractDocCommentLine(trimmed: trimmed, languageID: languageID) {
                recentDocLines.append(docText)
                if recentDocLines.count > 5 {
                    recentDocLines.removeFirst(recentDocLines.count - 5)
                }
                continue
            }

            if isRegularCommentLine(trimmed: trimmed, languageID: languageID) {
                recentDocLines.removeAll()
                continue
            }

            // Attribute-only lines like `@MainActor` or `#[derive(...)]` preserve preceding doc comments.
            if (trimmed.hasPrefix("@") && !trimmed.contains(" ")) || trimmed.hasPrefix("#[") {
                continue
            }

            let leadingIndent = countLeadingIndentSpaces(lineString)
            if let parsed = parseDeclaration(in: trimmed, leadingIndent: leadingIndent, languageID: languageID) {
                let signature = cleanSignatureDetail(from: trimmed)
                let lineUTF16Len = lineString.utf16.count
                let fullRange = EditorRange(
                    startLine: lineNumber,
                    startColumn: min(leadingIndent + 1, max(1, lineUTF16Len)),
                    endLine: lineNumber,
                    endColumn: max(1, lineUTF16Len + 1)
                )
                let selectionRange = locateIdentifierRange(
                    identifier: parsed.name,
                    inLine: lineString,
                    lineNumber: lineNumber
                ) ?? fullRange

                let doc = recentDocLines.isEmpty ? nil : recentDocLines.joined(separator: "\n")
                let symbol = EditorDocumentSymbol(
                    name: parsed.name,
                    detail: signature,
                    kind: parsed.kind,
                    range: fullRange,
                    selectionRange: selectionRange
                )
                results.append(
                    AnnotatedSymbol(
                        symbol: symbol,
                        documentation: doc,
                        signatureLine: signature
                    )
                )
            }
            recentDocLines.removeAll()
        }

        return results
    }

    nonisolated private static func countLeadingIndentSpaces(_ line: String) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " {
                spaces += 1
            } else if ch == "\t" {
                spaces += 4
            } else {
                break
            }
        }
        return spaces
    }

    nonisolated private static func extractDocCommentLine(trimmed: String, languageID: String) -> String? {
        if trimmed.hasPrefix("///") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("//!") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        if languageID == "python" || languageID == "shellscript" || languageID == "ruby" {
            if trimmed.hasPrefix("#") && !trimmed.hasPrefix("#!") {
                return String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated private static func isRegularCommentLine(trimmed: String, languageID: String) -> Bool {
        if trimmed.hasPrefix("//") || (trimmed.hasPrefix("/*") && trimmed.hasSuffix("*/")) {
            return true
        }
        let isHashCommentLang = languageID == "python" || languageID == "shellscript" || languageID == "ruby"
        if isHashCommentLang, trimmed.hasPrefix("#") {
            return true
        }
        return false
    }

    private static let leadingModifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "package",
        "export", "default", "declare", "readonly", "abstract",
        "async", "pub", "unsafe", "extern", "static", "final", "override",
        "mutating", "nonmutating", "nonisolated", "convenience", "required",
        "lazy", "weak", "unowned", "indirect", "distributed",
        "inline", "comptime", "noinline", "constexpr", "virtual"
    ]

    nonisolated private static func stripLeadingAttributesAndModifiers(_ line: String) -> Substring {
        var rest = line[...]
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            // Strip Swift/TS/Java `@Attribute` or `@Attribute(...)`
            if rest.first == "@" {
                rest = rest.dropFirst()
                rest = rest.drop(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
                if rest.first == "(" {
                    var depth = 0
                    while let ch = rest.first {
                        rest = rest.dropFirst()
                        if ch == "(" { depth += 1 } else if ch == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                }
                continue
            }
            // Strip Rust `pub(crate)` / Swift `private(set)` visibility qualifiers
            if rest.hasPrefix("pub(") || rest.hasPrefix("private(") || rest.hasPrefix("internal(") || rest.hasPrefix("package(") {
                if let closeParen = rest.firstIndex(of: ")") {
                    rest = rest[rest.index(after: closeParen)...]
                    continue
                }
            }
            // Strip `extern "C"`
            if rest.hasPrefix("extern ") {
                var afterExtern = rest.dropFirst("extern ".count).drop(while: { $0 == " " })
                if afterExtern.first == "\"" {
                    afterExtern = afterExtern.dropFirst()
                    if let endQuote = afterExtern.firstIndex(of: "\"") {
                        rest = afterExtern[afterExtern.index(after: endQuote)...]
                        continue
                    }
                }
            }
            let word = rest.prefix(while: { $0.isLetter || $0 == "_" })
            if !word.isEmpty, leadingModifiers.contains(String(word)) {
                let afterWord = rest.dropFirst(word.count)
                if afterWord.first == " " || afterWord.first == "\t" {
                    rest = afterWord
                    continue
                }
            }
            break
        }
        return rest.drop(while: { $0 == " " || $0 == "\t" })
    }

    nonisolated private static func parseDeclaration(
        in trimmedLine: String,
        leadingIndent: Int,
        languageID: String
    ) -> ParsedDeclaration? {
        // C/C++ `#define MACRO_NAME`
        let isCLike = languageID == "c" || languageID == "cpp"
        if isCLike, trimmedLine.hasPrefix("#define ") {
            let afterDefine = trimmedLine.dropFirst("#define ".count).drop(while: { $0 == " " || $0 == "\t" })
            if let name = readIdentifier(from: afterDefine) {
                return ParsedDeclaration(name: name, kind: .constant)
            }
        }

        let stripped = stripLeadingAttributesAndModifiers(trimmedLine)
        let keyword = String(stripped.prefix(while: { $0.isLetter || $0 == "_" }))
        guard !keyword.isEmpty else { return nil }
        let afterKeywordRaw = stripped.dropFirst(keyword.count)

        // Handle `impl<T>` where `<` immediately follows `impl`
        let isImplHead = afterKeywordRaw.first == "<" || afterKeywordRaw.first == " " || afterKeywordRaw.first == "\t"
        if keyword == "impl", isImplHead {
            return parseRustImpl(afterImpl: afterKeywordRaw)
        }

        guard afterKeywordRaw.first == " " || afterKeywordRaw.first == "\t" else {
            return nil
        }
        let rest = afterKeywordRaw.drop(while: { $0 == " " || $0 == "\t" })

        switch keyword {
        case "func":
            // Go method receiver: `func (s *Server) Start(...)`
            if rest.first == "(" {
                var cursor = rest
                var depth = 0
                while let ch = cursor.first {
                    cursor = cursor.dropFirst()
                    if ch == "(" { depth += 1 } else if ch == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                let afterReceiver = cursor.drop(while: { $0 == " " || $0 == "\t" })
                if let name = readIdentifier(from: afterReceiver) {
                    return ParsedDeclaration(name: name, kind: .method)
                }
                return nil
            }
            if let name = readIdentifier(from: rest) {
                return ParsedDeclaration(name: name, kind: leadingIndent > 0 ? .method : .function)
            }

        case "fn", "function":
            // JS generator `function* foo()`
            let target = rest.first == "*" ? rest.dropFirst().drop(while: { $0 == " " }) : rest
            if let name = readIdentifier(from: target) {
                return ParsedDeclaration(name: name, kind: leadingIndent > 0 && languageID == "rust" ? .method : .function)
            }

        case "def":
            if let name = readIdentifier(from: rest) {
                let kind: EditorDocumentSymbol.SymbolKind
                if name == "__init__" || name == "initialize" {
                    kind = .constructor
                } else if leadingIndent > 0 {
                    kind = .method
                } else {
                    kind = .function
                }
                return ParsedDeclaration(name: name, kind: kind)
            }

        case "struct":
            if let name = readIdentifier(from: rest) {
                return ParsedDeclaration(name: name, kind: .struct)
            }

        case "class", "actor":
            if let name = readIdentifier(from: rest) {
                return ParsedDeclaration(name: name, kind: .class)
            }

        case "enum":
            // C++ `enum class Foo`
            let enumRest: Substring
            if rest.hasPrefix("class ") || rest.hasPrefix("struct ") {
                enumRest = rest.drop(while: { $0 != " " }).drop(while: { $0 == " " })
            } else {
                enumRest = rest
            }
            if let name = readIdentifier(from: enumRest) {
                return ParsedDeclaration(name: name, kind: .enum)
            }

        case "protocol":
            if let name = readIdentifier(from: rest) {
                return ParsedDeclaration(name: name, kind: .protocol)
            }

        case "interface":
            if let name = readIdentifier(from: rest) {
                return ParsedDeclaration(name: name, kind: .interface)
            }

        case "trait":
            if let name = readIdentifier(from: rest) {
                return ParsedDeclaration(name: name, kind: .trait)
            }

        case "type", "typealias":
            if let name = readIdentifier(from: rest) {
                let tail = rest.dropFirst(name.count).drop(while: { $0 == " " || $0 == "\t" })
                if tail.hasPrefix("struct") || tail.hasPrefix("= struct") {
                    return ParsedDeclaration(name: name, kind: .struct)
                }
                if tail.hasPrefix("interface") || tail.hasPrefix("= interface") {
                    return ParsedDeclaration(name: name, kind: .interface)
                }
                return ParsedDeclaration(name: name, kind: .typeParameter)
            }

        case "const":
            if let name = readIdentifier(from: rest) {
                let tail = rest.dropFirst(name.count)
                // Zig `const Foo = struct` / `enum` / `union`
                if let eqIdx = tail.firstIndex(of: "=") {
                    let rhs = tail[tail.index(after: eqIdx)...].drop(while: { $0 == " " || $0 == "\t" })
                    if rhs.hasPrefix("struct") || rhs.hasPrefix("packed struct") || rhs.hasPrefix("extern struct") || rhs.hasPrefix("union") {
                        return ParsedDeclaration(name: name, kind: .struct)
                    }
                    if rhs.hasPrefix("enum") || rhs.hasPrefix("error") {
                        return ParsedDeclaration(name: name, kind: .enum)
                    }
                    // JS/TS arrow function `const foo = (...) =>` or `const foo = async (...) =>`
                    if rhs.contains("=>") && (rhs.hasPrefix("(") || rhs.hasPrefix("async") || rhs.hasPrefix("<")) {
                        return ParsedDeclaration(name: name, kind: .function)
                    }
                }
                // Keep top-level / type-level / exported constants clean; skip deeply nested local `const` inside blocks.
                let isExportedOrPublic = trimmedLine.hasPrefix("pub ") || trimmedLine.hasPrefix("export ") || trimmedLine.hasPrefix("public ")
                if leadingIndent <= 4 || isExportedOrPublic {
                    return ParsedDeclaration(name: name, kind: .constant)
                }
            }

        default:
            break
        }

        return nil
    }

    nonisolated private static func parseRustImpl(afterImpl: Substring) -> ParsedDeclaration? {
        var cursor = afterImpl
        // Skip generic parameters `<...>` after `impl`
        if cursor.first == "<" {
            var depth = 0
            while let ch = cursor.first {
                cursor = cursor.dropFirst()
                if ch == "<" { depth += 1 } else if ch == ">" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
        }
        cursor = cursor.drop(while: { $0 == " " || $0 == "\t" })
        // Strip leading `{` onwards
        let headerPart: Substring
        if let brace = cursor.firstIndex(of: "{") {
            headerPart = cursor[..<brace]
        } else if let whereRange = cursor.range(of: " where ") {
            headerPart = cursor[..<whereRange.lowerBound]
        } else {
            headerPart = cursor
        }

        // If `impl Trait for Type`, extract `Type`; otherwise extract `Type` from `impl Type`.
        let targetSlice: Substring
        if let forRange = headerPart.range(of: " for ") {
            targetSlice = headerPart[forRange.upperBound...].drop(while: { $0 == " " || $0 == "&" || $0 == "*" })
        } else {
            targetSlice = headerPart.drop(while: { $0 == " " || $0 == "&" || $0 == "*" })
        }

        // Handle path prefixes like `crate::foo::MyType<T>` -> `MyType`
        var cleaned = targetSlice
        while let sep = cleaned.range(of: "::") {
            cleaned = cleaned[sep.upperBound...]
        }
        guard let name = readIdentifier(from: cleaned) else { return nil }
        return ParsedDeclaration(name: name, kind: .struct)
    }

    nonisolated private static func readIdentifier(from slice: Substring) -> String? {
        guard let first = slice.first, first.isLetter || first == "_" || first == "$" else {
            return nil
        }
        let ident = slice.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
        return ident.isEmpty ? nil : String(ident)
    }

    nonisolated private static func cleanSignatureDetail(from trimmedLine: String) -> String {
        var sig = trimmedLine
        if let commentIdx = sig.range(of: " //") {
            sig = String(sig[..<commentIdx.lowerBound])
        }
        sig = sig.trimmingCharacters(in: .whitespaces)
        if sig.hasSuffix("{") {
            sig = String(sig.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if sig.hasSuffix(":") && !sig.contains("::") {
            sig = String(sig.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if sig.count > 140 {
            sig = String(sig.prefix(137)) + "..."
        }
        return sig
    }

    nonisolated private static func locateIdentifierRange(
        identifier: String,
        inLine line: String,
        lineNumber: Int
    ) -> EditorRange? {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_$])"# + escaped + #"(?![\p{L}\p{N}_$])"#) else {
            return locateSubstringRange(substring: identifier, inLine: line, lineNumber: lineNumber)
        }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }
        return EditorRange(
            startLine: lineNumber,
            startColumn: match.range.location + 1,
            endLine: lineNumber,
            endColumn: match.range.location + match.range.length + 1
        )
    }

    nonisolated private static func locateSubstringRange(
        substring: String,
        inLine line: String,
        lineNumber: Int
    ) -> EditorRange? {
        let nsLine = line as NSString
        let found = nsLine.range(of: substring)
        guard found.location != NSNotFound else { return nil }
        return EditorRange(
            startLine: lineNumber,
            startColumn: found.location + 1,
            endLine: lineNumber,
            endColumn: found.location + found.length + 1
        )
    }

    nonisolated private static func collectWordOccurrences(
        in text: String,
        path: String,
        regex: NSRegularExpression,
        into results: inout [EditorDefinitionLocation],
        limit: Int
    ) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, rawLine) in lines.enumerated() {
            if results.count >= limit { break }
            let lineStr = String(rawLine)
            guard lineStr.count <= 4_000 else { continue }
            let nsLine = lineStr as NSString
            let matches = regex.matches(in: lineStr, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }
            let preview = lineStr.trimmingCharacters(in: .whitespaces)
            for match in matches {
                if results.count >= limit { break }
                let range = EditorRange(
                    startLine: idx + 1,
                    startColumn: match.range.location + 1,
                    endLine: idx + 1,
                    endColumn: match.range.location + match.range.length + 1
                )
                results.append(EditorDefinitionLocation(path: path, range: range, preview: preview))
            }
        }
    }

    nonisolated private static func formatHover(
        entry: AnnotatedSymbol,
        path: String,
        languageID: String,
        workspaceRoot: String?
    ) -> EditorHoverInfo {
        let fenceLang = languageID == "plaintext" ? "" : languageID
        var sections: [String] = [
            "```\(fenceLang)\n\(entry.signatureLine)\n```"
        ]
        if let doc = entry.documentation, !doc.isEmpty {
            sections.append(doc)
        }
        let displayPath: String
        if let workspaceRoot {
            displayPath = WorkspaceFileActions.relativePath(path, root: workspaceRoot)
        } else {
            displayPath = (path as NSString).lastPathComponent
        }
        sections.append("*`\(displayPath):\(entry.symbol.range.startLine)`*")
        return EditorHoverInfo(markdown: sections.joined(separator: "\n\n"), range: nil)
    }

    nonisolated private static func completionKind(for symbolKind: EditorDocumentSymbol.SymbolKind) -> CompletionItemKind {
        switch symbolKind {
        case .function, .method, .constructor:
            return .function
        case .struct, .class, .enum, .interface, .protocol, .trait, .typeParameter:
            return .type
        case .property, .field, .enumMember:
            return .property
        case .constant, .variable:
            return .variable
        default:
            return .text
        }
    }
}
