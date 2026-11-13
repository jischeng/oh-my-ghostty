import AppKit
import SwiftUI

@MainActor
final class GitDiffScrollLink {
    var enabled = true
    var presentation = GitDiffPresentation(before: "", after: "", patch: "")
    private var endpoints: [Int: Endpoint] = [:]
    private var pendingLines: [Int: Int] = [:]
    private(set) var lastRevealedLines: [Int: Int] = [:]

    final class Endpoint {
        weak var controller: MonacoWorkbenchController?
        let uri: String

        init(controller: MonacoWorkbenchController, uri: String) {
            self.controller = controller
            self.uri = uri
        }
    }

    func register(controller: MonacoWorkbenchController, uri: String, side: Int) {
        endpoints[side] = Endpoint(controller: controller, uri: uri)
        applyPendingJump(side: side)
    }

    func unregister(controller: MonacoWorkbenchController?, side: Int) {
        if endpoints[side]?.controller === controller {
            endpoints.removeValue(forKey: side)
        }
    }

    func jump(to lines: [Int: Int]) {
        pendingLines.merge(lines) { _, new in new }
        for side in lines.keys {
            applyPendingJump(side: side)
        }
    }

    func queueJump(to lines: [Int: Int]) {
        pendingLines = lines
    }

    private func applyPendingJump(side: Int) {
        guard let zeroBasedIndex = pendingLines[side],
              let endpoint = endpoints[side],
              let controller = endpoint.controller else { return }
        let oneBasedLine = max(1, zeroBasedIndex + 1)
        controller.revealRange(uri: endpoint.uri, startLine: oneBasedLine, startColumn: 1)
        lastRevealedLines[side] = zeroBasedIndex
        pendingLines.removeValue(forKey: side)

        guard enabled else { return }
        let partnerSide = 1 - side
        guard partnerSide == 0 || partnerSide == 1,
              pendingLines[partnerSide] == nil,
              let partner = endpoints[partnerSide],
              let partnerController = partner.controller else { return }
        let mapping = side == 0 ? presentation.beforeToAfter : presentation.afterToBefore
        if let mappedIndex = mapping[zeroBasedIndex] {
            partnerController.revealRange(uri: partner.uri, startLine: max(1, mappedIndex + 1), startColumn: 1)
            lastRevealedLines[partnerSide] = mappedIndex
        }
    }
}

/// Read-only Monaco-backed diff pane connected to `GitDiffScrollLink`.
struct GitDiffLinkedEditor: View {
    let text: String
    let path: String
    let highlights: [Int: Bool]
    let isActive: Bool
    let theme: EditorTheme
    let wordWrap: Bool
    let link: GitDiffScrollLink
    let side: Int
    let close: () -> Void
    let actions: GitDiffEditorActions

    @StateObject private var controller = MonacoWorkbenchController()
    @State private var instanceID = UUID().uuidString

    init(
        text: String,
        path: String,
        highlights: [Int: Bool],
        isActive: Bool,
        theme: EditorTheme,
        wordWrap: Bool = true,
        link: GitDiffScrollLink,
        side: Int,
        actions: GitDiffEditorActions = GitDiffEditorActions(),
        close: @escaping () -> Void
    ) {
        self.text = text
        self.path = path
        self.highlights = highlights
        self.isActive = isActive
        self.theme = theme
        self.wordWrap = wordWrap
        self.link = link
        self.side = side
        self.actions = actions
        self.close = close
    }

    private var modelURI: String {
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "omg-model://standalone-\(instanceID)/\(encoded.isEmpty ? "diff" : encoded)"
    }

    var body: some View {
        CodeEditorView(
            text: .constant(text),
            fileURL: URL(fileURLWithPath: path, isDirectory: false),
            diffLines: highlights,
            isEditable: false,
            isActive: isActive,
            isSurfaceFocused: actions.isSurfaceFocused,
            terminalTheme: theme,
            wordWrapOverride: wordWrap,
            onFocus: actions.focus,
            onClose: close,
            onOpen: actions.open,
            onNextDocument: actions.nextDocument,
            onPreviousDocument: actions.previousDocument,
            onSaveAll: actions.saveAll,
            onHide: actions.hide,
            externalController: controller
        )
        .onAppear {
            link.register(controller: controller, uri: modelURI, side: side)
        }
        .onDisappear {
            link.unregister(controller: controller, side: side)
            controller.tearDown()
        }
    }
}
