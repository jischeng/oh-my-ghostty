import Foundation

/// Computes 1-based line-level Git working-tree gutter annotations (`added`, `modified`, `deleted`)
/// by parsing zero-context unified diffs (`git diff --no-ext-diff --no-color -U0 HEAD -- <file>`).
struct EditorGitGutterService: Sendable {
    static let defaultTimeout: TimeInterval = 2.0
    private static let maxDiffOutputBytes = 2 * 1_024 * 1_024

    private let gitExecutablePath: String?

    init(gitExecutablePath: String? = nil) {
        self.gitExecutablePath = gitExecutablePath
    }

    /// Computes gutter diff markers for a local file off the main thread with a bounded 2-second timeout.
    /// Returns `[:]` when the file is clean, untracked, outside a Git repository, or if `git` times out.
    func diffLines(
        forFileAt path: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = Self.defaultTimeout
    ) async -> [Int: EditorGutterLineKind] {
        guard path.hasPrefix("/"), !path.contains("\0") else { return [:] }

        return await Task.detached(priority: .utility) { [gitExecutablePath] in
            let resolvedFileURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let resolvedDirPath: String
            if let workingDirectory, workingDirectory.hasPrefix("/") {
                resolvedDirPath = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path
            } else {
                resolvedDirPath = resolvedFileURL.deletingLastPathComponent().path
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedDirPath, isDirectory: &isDir),
                  isDir.boolValue else {
                return [:]
            }

            let env = Self.gitEnvironment()
            let executable = gitExecutablePath ?? "/usr/bin/env"
            let prefixArgs = gitExecutablePath == nil ? ["git"] : []
            let headArgs = prefixArgs + [
                "--literal-pathspecs",
                "diff",
                "--no-ext-diff",
                "--no-color",
                "--no-renames",
                "-U0",
                "HEAD",
                "--",
                resolvedFileURL.path
            ]

            let runner = GitProcessRunner()
            if let result = try? await runner.run(
                executablePath: executable,
                arguments: headArgs,
                workingDirectory: resolvedDirPath,
                environment: env,
                maxOutputBytes: Self.maxDiffOutputBytes,
                timeout: timeout
            ) {
                if result.exitCode == 0 || result.exitCode == 1 {
                    return Self.parseUnifiedDiff(result.stdoutString)
                }
                // Unborn branch (`HEAD` does not exist yet): fall back to index vs working tree diff.
                if result.exitCode == 128, result.stderrString.contains("HEAD") {
                    let indexArgs = prefixArgs + [
                        "--literal-pathspecs",
                        "diff",
                        "--no-ext-diff",
                        "--no-color",
                        "--no-renames",
                        "-U0",
                        "--",
                        resolvedFileURL.path
                    ]
                    if let fallback = try? await runner.run(
                        executablePath: executable,
                        arguments: indexArgs,
                        workingDirectory: resolvedDirPath,
                        environment: env,
                        maxOutputBytes: Self.maxDiffOutputBytes,
                        timeout: timeout
                    ), fallback.exitCode == 0 || fallback.exitCode == 1 {
                        return Self.parseUnifiedDiff(fallback.stdoutString)
                    }
                }
            }
            return [:]
        }.value
    }

    /// Computes gutter diff markers through any `GitExecutor` (supporting SSH workspaces seamlessly).
    func diffLines(
        forFileAt path: String,
        repositoryRoot: String,
        executor: any GitExecutor
    ) async -> [Int: EditorGutterLineKind] {
        let relativePath = WorkspaceFileActions.relativePath(path, root: repositoryRoot)
        guard !relativePath.isEmpty, !relativePath.contains("\0") else { return [:] }
        let args = [
            "--literal-pathspecs",
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--no-renames",
            "-U0",
            "HEAD",
            "--",
            relativePath
        ]
        guard let result = try? await executor.execute(
            arguments: args,
            workingDirectory: repositoryRoot,
            stdin: nil,
            maxOutputBytes: Self.maxDiffOutputBytes
        ), result.exitCode == 0 || result.exitCode == 1 else {
            return [:]
        }
        return await Task.detached(priority: .utility) {
            Self.parseUnifiedDiff(result.stdoutString)
        }.value
    }

    /// Pure unified-diff (`-U0`) hunk parser shared by local `git` and remote SSH diffs.
    ///
    /// Rules for `@@ -oldStart[,oldCount] +newStart[,newCount] @@`:
    /// - `oldCount == 0 && newCount > 0`: lines `newStart ..< newStart + newCount` are `.added`
    /// - `oldCount > 0 && newCount == 0`: line `max(1, newStart)` is `.deleted`
    /// - `oldCount > 0 && newCount > 0`: lines `newStart ..< newStart + newCount` are `.modified`
    nonisolated static func parseUnifiedDiff(_ diffText: String) -> [Int: EditorGutterLineKind] {
        guard !diffText.isEmpty else { return [:] }
        var gutter: [Int: EditorGutterLineKind] = [:]

        for rawLine in diffText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.hasPrefix("@@ ") else { continue }
            guard let hunk = parseHunkHeader(rawLine) else { continue }

            if hunk.oldCount == 0 && hunk.newCount > 0 {
                let start = max(1, hunk.newStart)
                for line in start ..< (start + hunk.newCount) {
                    gutter[line] = .added
                }
            } else if hunk.oldCount > 0 && hunk.newCount == 0 {
                let anchor = max(1, hunk.newStart)
                if gutter[anchor] == nil {
                    gutter[anchor] = .deleted
                }
            } else if hunk.oldCount > 0 && hunk.newCount > 0 {
                let start = max(1, hunk.newStart)
                for line in start ..< (start + hunk.newCount) {
                    gutter[line] = .modified
                }
            }
        }
        return gutter
    }

    /// Formats 1-based gutter map into string-keyed dictionary expected by `window.omgEditor.setGitDiffLines`.
    nonisolated static func bridgePayload(from lines: [Int: EditorGutterLineKind]) -> [String: String] {
        var payload: [String: String] = [:]
        payload.reserveCapacity(lines.count)
        for (line, kind) in lines {
            payload[String(line)] = kind.rawValue
        }
        return payload
    }

    // MARK: - Private Helpers

    private struct HunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    private struct SpanSpec {
        let start: Int
        let count: Int
    }

    nonisolated private static func parseHunkHeader(_ line: Substring) -> HunkHeader? {
        // Expected format: `@@ -<oldStart>[,<oldCount>] +<newStart>[,<newCount>] @@...`
        let afterAt = line.dropFirst(3).drop(while: { $0 == " " })
        guard afterAt.first == "-" else { return nil }
        let afterMinus = afterAt.dropFirst()
        guard let spaceIdx = afterMinus.firstIndex(of: " ") else { return nil }
        let oldPart = afterMinus[..<spaceIdx]

        let restAfterOld = afterMinus[afterMinus.index(after: spaceIdx)...].drop(while: { $0 == " " })
        guard restAfterOld.first == "+" else { return nil }
        let afterPlus = restAfterOld.dropFirst()
        guard let endSpaceIdx = afterPlus.firstIndex(of: " ") else { return nil }
        let newPart = afterPlus[..<endSpaceIdx]

        let trailing = afterPlus[endSpaceIdx...].drop(while: { $0 == " " })
        guard trailing.hasPrefix("@@") else { return nil }

        guard let oldSpan = parseSpan(oldPart),
              let newSpan = parseSpan(newPart) else {
            return nil
        }
        return HunkHeader(
            oldStart: oldSpan.start,
            oldCount: oldSpan.count,
            newStart: newSpan.start,
            newCount: newSpan.count
        )
    }

    nonisolated private static func parseSpan(_ token: Substring) -> SpanSpec? {
        if let comma = token.firstIndex(of: ",") {
            guard let start = Int(token[..<comma]),
                  let count = Int(token[token.index(after: comma)...]),
                  start >= 0, count >= 0 else {
                return nil
            }
            return SpanSpec(start: start, count: count)
        }
        guard let start = Int(token), start >= 0 else { return nil }
        return SpanSpec(start: start, count: 1)
    }

    nonisolated private static func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.contains("/opt/homebrew/bin") && !path.contains("/usr/local/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C.UTF-8"
        return environment
    }
}
