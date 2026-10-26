import AppKit
import SwiftUI

struct GitCommitComposer: View {
    @Binding var message: String
    let stagedCount: Int
    let isBusy: Bool
    let canCommit: Bool
    let isUpdatingIndex: Bool
    let commit: () -> Void
    var repository: GitRepositoryIdentity?
    var unstagedCount = 0
    var canStageAll = true
    var hasHead = false
    var submit: (Bool, Bool) -> Void = { _, _ in }
    @Environment(\.gitCollectionColors) private var colors
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var generation: Task<Void, Never>?
    @State private var generationID: UUID?
    @State private var draftRevision = 0
    @State private var notice: String?
    @State private var noticeID = UUID()
    @State private var noticeExpires = false
    @State private var confirmReplace = false
    @State private var editorHeight: CGFloat = 44
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { self.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(GitL10n.text("Dismiss message"))
                }
            }
            GitCommitMessageEditor(text: $message, height: $editorHeight, focusChanged: { focused = $0 })
                .frame(height: editorHeight)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text(GitL10n.text("Commit message")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            .padding(.leading, 9).padding(.top, 6).allowsHitTesting(false)
                    }
                }
                .modifier(GitInputSurface(focused: focused))
            HStack(spacing: 6) {
                Button {
                    if generationID != nil { cancelGeneration() } else { requestGeneration() }
                } label: {
                    Image(systemName: generationID == nil ? "sparkles" : "stop.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(GitCommitActionStyle(colors: colors, prominent: false))
                .disabled(generationID == nil && (isBusy || isUpdatingIndex || !canCommit || stagedCount == 0 || repository == nil))
                .help(GitL10n.text(generationID == nil ? "Generate a commit message using your configured agents" : "Cancel"))
                .accessibilityLabel(GitL10n.text(generationID == nil ? "Generate" : "Cancel"))
                HStack(spacing: 0) {
                    Button(action: commit) {
                        HStack(spacing: 5) {
                            if isBusy || generationID != nil { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark") }
                            Text(GitL10n.text("Commit Staged"))
                        }
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(GitCommitActionStyle(colors: colors, prominent: true))
                    .disabled(!allowsSubmit(stageAll: false, amend: false))
                    Color.clear.frame(width: 4, height: 28)
                    Menu {
                        commitOption("Commit Staged", stageAll: false, amend: false)
                        commitOption("Stage All and Commit", stageAll: true, amend: false)
                        Divider()
                        commitOption("Amend Last Commit", stageAll: false, amend: true)
                        commitOption("Stage All and Amend", stageAll: true, amend: true)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color(menuEnabled ? colors.accent : colors.secondary))
                    .background(Color(colors.text).opacity(menuEnabled ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(colors.text).opacity(menuEnabled ? 0.22 : 0.06)))
                    .disabled(!menuEnabled)
                    .help(GitL10n.text("Commit options"))
                    .accessibilityLabel(GitL10n.text("Commit options"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))

            }
            Text(GitL10n.format("{0} staged", String(stagedCount)))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .confirmationDialog(GitL10n.text("Replace the existing commit message?"), isPresented: $confirmReplace) {
            Button(GitL10n.text("Generate and Replace")) { startGeneration() }
            Button(GitL10n.text("Cancel"), role: .cancel) {}
        }
        .onChange(of: message) { _ in draftRevision += 1 }
        .onChange(of: repository) { _ in cancelGeneration(); notice = nil }
        .onDisappear { cancelGeneration() }
        .task(id: noticeID) {
            guard noticeExpires else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private var menuEnabled: Bool {
        allowsSubmit(stageAll: false, amend: false) || allowsSubmit(stageAll: true, amend: false) ||
        allowsSubmit(stageAll: false, amend: true) || allowsSubmit(stageAll: true, amend: true)
    }

    private func allowsSubmit(stageAll: Bool, amend: Bool) -> Bool {
        guard generationID == nil, !isBusy, !isUpdatingIndex, canCommit,
              !stageAll || canStageAll, !amend || hasHead else { return false }
        let hasChanges = stagedCount > 0 || (stageAll && unstagedCount > 0)
        return (amend || hasChanges) && (amend || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func commitOption(_ title: String, stageAll: Bool, amend: Bool) -> some View {
        Button(GitL10n.text(title)) { submit(stageAll, amend) }
            .disabled(!allowsSubmit(stageAll: stageAll, amend: amend))
    }

    private func requestGeneration() {
        guard !settings.gitCommitAIRoutes.isEmpty else { SettingsNavigation.open(.git); return }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { startGeneration() } else { confirmReplace = true }
    }

    private func cancelGeneration() {
        generation?.cancel()
        generation = nil
        generationID = nil
    }

    private func startGeneration() {
        guard let repository, generationID == nil, !isBusy, !isUpdatingIndex, canCommit, stagedCount > 0 else { return }
        let id = UUID()
        let revision = draftRevision
        let routes = settings.gitCommitAIRoutes
        generationID = id
        notice = nil
        noticeExpires = false
        noticeID = UUID()
        let customPrompt = settings.gitCommitAIPrompt
        generation = Task { @MainActor in
            defer {
                if generationID == id { generationID = nil; generation = nil }
            }
            do {
                let result = try await GitCommitAIService().generate(repository: repository, routes: routes, customPrompt: customPrompt)
                guard !Task.isCancelled, generationID == id else { return }
                guard draftRevision == revision else {
                    notice = GitL10n.text("Your draft changed during generation. It was not replaced; generate again.")
                    return
                }
                message = result.message
                notice = (result.attempt > 1 ? GitL10n.text("Generated using fallback: ") : GitL10n.text("Generated using: ")) + result.route.title
                noticeExpires = true
                noticeID = UUID()
            } catch {
                guard !Task.isCancelled, generationID == id else { return }
                if case GitExecutionError.outputLimitExceeded = error {
                    notice = GitL10n.text("Staged changes are too large for AI generation (200 KB patch limit). Split the commit and try again.")
                } else { notice = error.localizedDescription }
            }
        }
    }
}

private struct GitCommitActionStyle: ButtonStyle {
    let colors: GitCollectionColors
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? (prominent ? Color.white : Color(colors.accent)) : Color(colors.secondary).opacity(0.55))
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color(enabled ? colors.accent : colors.text).opacity(enabled ? 0.55 : 0.06)))
            .onHover { hovered = $0 }
    }

    private func background(pressed: Bool) -> Color {
        guard enabled else { return Color(colors.text).opacity(0.035) }
        if prominent { return Color(colors.accent).opacity(pressed ? 0.65 : hovered ? 0.95 : 0.82) }
        return Color(colors.accent).opacity(pressed ? 0.28 : hovered ? 0.20 : 0.10)
    }
}

/// Keep the text view and its selection/undo stack alive through status updates.
struct GitCommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(\.gitCollectionColors) private var colors
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = GitCommitTextView(frame: scroll.bounds)
        editor.focusChanged = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.focusChanged(focused) }
        }
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 11)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(GitL10n.text("Commit message"))
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.textColor = colors.text
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let location = min(selection.location, (text as NSString).length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, (text as NSString).length - location)))
        }
        context.coordinator.measure(editor)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GitCommitMessageEditor
        init(_ parent: GitCommitMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = min(112, max(44, ceil(manager.usedRect(for: container).height) + 10))
            guard abs(parent.height - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - height) > 0.5 else { return }
                self.parent.height = height
            }
        }
    }
}
