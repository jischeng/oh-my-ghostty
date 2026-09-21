import AppKit
import SwiftUI

@MainActor
enum GitTagDialog {
    static func present(repository: GitRepositoryIdentity, commit: GitHistoryCommit,
                        window: NSWindow?) async -> GitMutation? {
        await withCheckedContinuation { continuation in
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = GitL10n.text("New Tag…")
            panel.isReleasedWhenClosed = false
            panel.appearance = window?.appearance ?? NSApp.effectiveAppearance
            panel.backgroundColor = OMGThemeBackground.windowBackground()
            var finished = false
            let finish: (GitMutation?) -> Void = { mutation in
                guard !finished else { return }
                finished = true
                if let window { window.endSheet(panel) }
                panel.orderOut(nil)
                panel.contentViewController = nil
                continuation.resume(returning: mutation)
            }
            panel.contentViewController = NSHostingController(rootView: GitTagForm(
                repository: repository, commit: commit, finish: finish))
            if let window { window.beginSheet(panel) } else { panel.makeKeyAndOrderFront(nil) }
        }
    }
}

private struct GitTagForm: View {
    let repository: GitRepositoryIdentity
    let commit: GitHistoryCommit
    let finish: (GitMutation?) -> Void
    @State private var name = ""
    @State private var message = ""
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private var validName: Bool { (try? GitTagService.validate(name)) != nil && !name.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GitL10n.text("New Tag…")).font(.headline)
            Text(commit.id.shortSHA + " · " + commit.subject).font(.callout)
                .foregroundStyle(.secondary).lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(GitL10n.text("Tag name")).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                TextField("v1.2.0", text: $name).textFieldStyle(.roundedBorder)
                if busy { ProgressView().controlSize(.small) }
                Button { suggest() } label: { Label(GitL10n.text("Generate"), systemImage: "sparkles") }
                    .disabled(busy)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(GitL10n.text("Message")).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                TextField(GitL10n.text("Optional tag message"), text: $message)
                    .textFieldStyle(.roundedBorder)
            }
            Text(GitL10n.text("Create suggests the next minor version from the branch's tag history. The tag is pushed with the next push (--follow-tags)."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled) }
            HStack {
                Button(GitL10n.text("Cancel")) { task?.cancel(); finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(GitL10n.text("Create Tag")) { create() }
                    .disabled(!validName || busy).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500)
        .onAppear { message = commit.subject }
        .onDisappear { task?.cancel() }
    }

    private func tagsMergedAtCommit() async throws -> [String] {
        let result = try await repository.executor.execute(
            arguments: ["tag", "--merged", commit.id.rawValue, "--sort=-version:refname"],
            workingDirectory: repository.worktreePath, maxOutputBytes: 64_000)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        return result.stdoutString.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func suggest() {
        let settings = OhMyGhosttySettings.shared
        guard !settings.gitCommitAIRoutes.isEmpty else {
            // Without AI config, fall back to the deterministic next-minor suggestion.
            busy = true; error = nil
            task = Task { @MainActor in
                defer { busy = false }
                if let tags = try? await tagsMergedAtCommit(), let suggestion = GitTagService.suggestNextMinor(tags: tags) {
                    name = suggestion
                }
            }
            return
        }
        let routes = settings.gitCommitAIRoutes, style = settings.gitCommitAIPrompt
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let tags = try await tagsMergedAtCommit()
                let prompt = """
                Suggest the next Git tag for this branch. Existing tags merged at this commit:
                \(tags.prefix(40).joined(separator: "\n"))
                Increment the MINOR version of the latest version tag and reset patch (e.g. v1.6.124 -> v1.7.0).
                Return only the tag name, nothing else.
                """
                let generator = GitCommitAIService { route, text in
                    try await GitACPService.shared.generate(repository: repository, route: route,
                        style: "operation/tag/" + style, prompt: text)
                }
                let result = try await generator.generate(routes: routes, prompt: prompt)
                let candidate = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
                if (try? GitTagService.validate(candidate)) != nil, !Task.isCancelled {
                    name = candidate
                } else if let suggestion = GitTagService.suggestNextMinor(tags: tags) {
                    name = suggestion
                }
            } catch {
                if let tags = try? await tagsMergedAtCommit(), let suggestion = GitTagService.suggestNextMinor(tags: tags) {
                    name = suggestion
                } else if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func create() {
        let tagName = name, tagMessage = message.isEmpty ? name : message
        finish(.createTag(name: tagName, message: tagMessage, commit: commit.id))
    }
}
