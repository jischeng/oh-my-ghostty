import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// Regression coverage for issue #14: hiding the editor must really hide its
/// native hierarchy (`NSView.isHidden`), not just fade it out, so WebKit and
/// the scroll-view editors stop all visibility/occlusion activity while the
/// terminal underneath is scrolled.
@MainActor
struct EditorVisibilityHostTests {
    private var items: [EditorContentItem] {
        [.init(id: .terminal, content: AnyView(Text("terminal"))),
         .init(id: .workspace, content: AnyView(Text("editor")))]
    }

    @Test func restoredVisibleEditorStillMountsTheTerminal() throws {
        let deck = EditorContentDeckController()
        deck.update(items: items, selectedID: .workspace)
        #expect(try #require(deck.hosts[.terminal]).isHidden)
        #expect(try #require(deck.hosts[.workspace]).isHidden == false)
    }

    @Test func retogglingVisibilityKeepsSameNativeHierarchy() throws {
        let deck = EditorContentDeckController()
        deck.update(items: items, selectedID: .workspace)
        let editor = try #require(deck.hosts[.workspace])
        let terminal = try #require(deck.hosts[.terminal])
        deck.update(items: items, selectedID: .terminal)
        #expect(editor.isHidden)
        #expect(!terminal.isHidden)
        deck.update(items: items, selectedID: .workspace)
        #expect(!editor.isHidden)
        #expect(terminal.isHidden)
        #expect(deck.hosts[.workspace] === editor)
        #expect(deck.hosts[.terminal] === terminal)
    }

    @Test func closingDocumentsBoundsTheCacheAndPreservesVisitedSelection() throws {
        let deck = EditorContentDeckController()
        let first = EditorContentKey.diff(UUID()), second = EditorContentKey.diff(UUID())
        let documents = [EditorContentItem(id: first, content: AnyView(Text("first"))),
                         EditorContentItem(id: second, content: AnyView(Text("second")))]
        deck.update(items: documents, selectedID: first)
        #expect(deck.hosts[second] == nil)
        let original = try #require(deck.hosts[first])
        deck.update(items: documents, selectedID: second)
        #expect(original.isHidden)
        deck.update(items: documents, selectedID: first)
        #expect(deck.hosts[first] === original)
        deck.update(items: [documents[1]], selectedID: second)
        #expect(deck.hosts[first] == nil)
        #expect(original.superview == nil)
    }

    @Test func hostDoesNotSelfSizeFromAppKitConstraints() throws {
        let deck = EditorContentDeckController()
        deck.view.setFrameSize(CGSize(width: 640, height: 480))
        deck.update(items: items, selectedID: .workspace)
        deck.view.layoutSubtreeIfNeeded()
        let editor = try #require(deck.hosts[.workspace])
        #expect(editor.sizingOptions.isEmpty)
        #expect(editor.frame == deck.view.bounds)
        deck.view.setFrameSize(CGSize(width: 800, height: 600))
        deck.view.layoutSubtreeIfNeeded()
        #expect(editor.frame == deck.view.bounds)
    }

    @Test func surfaceOcclusionTracksEditorVisibilitySplitZoomAndTabSelection() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        guard let coreApp = app.app else {
            Issue.record("Ghostty core app unavailable in test harness")
            return
        }
        let editorStore = EditorWorkspaceStore()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        let secondSurface = Ghostty.SurfaceView(coreApp, baseConfig: config)
        defer {
            window.delegate = nil
            window.close()
        }

        controller.editorWorkspaceStore = editorStore
        controller.windowOcclusionOverrideForTesting = true

        let primarySurface = try #require(controller.surfaceTree.first)
        controller.syncSurfaceTreeOcclusionState()
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(primarySurface.lastReportedOcclusionState == true)

        // 1. Showing a full-pane EditorWorkspace immediately occludes the covered terminal surface,
        //    and hiding it immediately restores redraw visibility.
        let editorWorkspace = editorStore.workspace(for: controller.tabSessionID, surfaceID: primarySurface.id)
        editorWorkspace.isVisible = true
        #expect(editorWorkspace.isVisible)
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastReportedOcclusionState == false)

        editorWorkspace.isVisible = false
        #expect(!editorWorkspace.isVisible)
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(primarySurface.lastReportedOcclusionState == true)

        // 2. Split zoom occludes non-zoomed siblings and restores them immediately on unzoom.
        let leftLeaf = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: primarySurface)
        let rightLeaf = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: secondSurface)
        let splitNode = SplitTree<Ghostty.SurfaceView>.Node.split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: leftLeaf,
            right: rightLeaf
        ))
        controller.surfaceTree = .init(root: splitNode, zoomed: nil)
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreOcclusionState == true)

        controller.surfaceTree = .init(root: splitNode, zoomed: leftLeaf)
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreOcclusionState == false)

        controller.surfaceTree = .init(root: splitNode, zoomed: nil)
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreOcclusionState == true)

        // 3. Background tabs and parked workspace controllers mark their surfaces occluded
        //    and wake immediately when reselected / unparked.
        let siblingController = TerminalController(app, withBaseConfig: config)
        defer {
            siblingController.window?.delegate = nil
            siblingController.window?.close()
        }
        controller.applyWorkspaceTabProjection([controller, siblingController], selected: siblingController)
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(secondSurface.lastSentCoreOcclusionState == false)

        controller.applyWorkspaceTabProjection([controller, siblingController], selected: controller)
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreOcclusionState == true)

        controller.workspacePresentationIsParked = true
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(secondSurface.lastSentCoreOcclusionState == false)

        controller.workspacePresentationIsParked = false
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreOcclusionState == true)
    }

    @Test func submittingAskAgentOrQuickInputCollapsesCoveringEditorToRevealTerminal() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        guard app.app != nil else {
            Issue.record("Ghostty core app unavailable in test harness")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-agent-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sample.swift")
        try Data("let x = 42\n".utf8).write(to: file)

        let editorStore = EditorWorkspaceStore()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer {
            editorStore.remove(surfaceIDs: controller.surfaceTree.map(\.id))
            window.delegate = nil
            window.close()
        }
        controller.editorWorkspaceStore = editorStore
        let surface = try #require(controller.surfaceTree.first)
        let workspace = editorStore.workspace(for: controller.tabSessionID, surfaceID: surface.id)
        workspace.open(path: file.path, filesystem: LocalWorkspaceFilesystem(workingDirectory: root.path))
        for _ in 0..<50 {
            if !workspace.isLoading, workspace.documents.count == 1 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(workspace.isVisible)
        #expect(editorStore.isEditorCovering(surfaceID: surface.id))

        // 1. Submitting Ask Agent collapses the covering EditorWorkspace (leaving open documents
        //    intact for 1-keystroke Shift+Esc restore) and opens QuickInput with the prompt.
        EditorQuickInputBridge.send(
            EditorAskAgentRequest(
                path: file.path,
                startLine: 1,
                endLine: 1,
                selectedText: "let x = 42",
                comment: "Explain this constant"
            ),
            workingDirectory: root.path,
            to: controller,
            surface: surface
        )
        #expect(!workspace.isVisible)
        #expect(!editorStore.isEditorCovering(surfaceID: surface.id))
        #expect(workspace.documents.count == 1)
        #expect(controller.quickInputModel.isPresented)
        #expect(controller.quickInputModel.draft.contains("@Sample.swift#L1"))
        #expect(controller.quickInputModel.draft.contains("Explain this constant"))

        // 2. If the user re-opens the editor while QuickInput is open and submits/queues a draft,
        //    the covering editor also collapses immediately so the terminal is visible.
        workspace.isVisible = true
        #expect(editorStore.isEditorCovering(surfaceID: surface.id))
        controller.queueQuickInputDraft()
        #expect(!workspace.isVisible)
        #expect(!editorStore.isEditorCovering(surfaceID: surface.id))
        #expect(workspace.documents.count == 1)
    }
}
