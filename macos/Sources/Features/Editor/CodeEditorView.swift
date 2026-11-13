import AppKit
import SwiftUI

/// SwiftUI wrapper around `MonacoWorkbenchSurface` for standalone code views and diff panes.
///
/// Multi-tab `EditorWorkspaceHost` instances share a single workspace-owned
/// `MonacoWorkbenchController`; standalone callers (such as diff panes and isolated
/// tests) automatically get a dedicated lifecycle-managed controller.
struct CodeEditorView: View {
    @Binding var text: String
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @Environment(\.colorScheme) private var colorScheme

    let fileURL: URL?
    var diffLines: [Int: Bool] = [:]
    var isEditable = true
    var isActive = true
    var isPreview = false
    var isSurfaceFocused: () -> Bool = { true }
    var terminalBackground: NSColor = .textBackgroundColor
    var terminalBackgroundOpacity: Double = 1.0
    var terminalForeground: NSColor = .textColor
    var terminalTheme: EditorTheme?
    var wordWrapOverride: Bool?
    var onFocus: () -> Void = {}
    var onSave: () -> Void = {}
    var onClose: () -> Void = {}
    var onOpen: () -> Void = {}
    var onNextDocument: () -> Void = {}
    var onPreviousDocument: () -> Void = {}
    var onSaveAll: () -> Void = {}
    var onHide: () -> Void = {}
    var onAskAgent: (EditorAskAgentRequest) -> Void = { _ in }
    var navigationRequest: EditorNavigationRequest?
    var onConsumeNavigation: (UUID) -> Void = { _ in }
    var externalController: MonacoWorkbenchController?

    @StateObject private var ownedController = MonacoWorkbenchController()
    @State private var standaloneID = UUID().uuidString

    private var controller: MonacoWorkbenchController {
        externalController ?? ownedController
    }

    private var modelURI: String {
        if let fileURL {
            let encoded = fileURL.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            return "omg-model://standalone-\(standaloneID)/\(encoded)"
        }
        return "omg-model://standalone-\(standaloneID)/untitled"
    }

    private var editorSettings: EditorSettings { settings.editorSettings }

    private var resolvedTheme: EditorTheme {
        var theme = terminalTheme ?? (editorSettings.followsOMG
            ? .adaptive(background: terminalBackground, foreground: terminalForeground)
            : editorSettings.syntaxTheme.preset)
        theme.background = EditorTheme.transparentBackground
        return theme
    }

    private var isDarkTheme: Bool {
        let luminance = (terminalBackground.usingColorSpace(.sRGB) ?? terminalBackground).brightnessComponent
        if terminalTheme != nil || editorSettings.followsOMG {
            return luminance < 0.55
        }
        if editorSettings.syntaxTheme == .oneLight {
            return false
        }
        return colorScheme == .dark || editorSettings.syntaxTheme != .oneLight
    }

    var body: some View {
        MonacoWorkbenchSurface(controller: controller)
            .background(Color.clear)
            .clipped()
            .onAppear {
                syncAll(preserveView: false)
                applyPendingNavigation()
            }
            .onDisappear {
                if externalController == nil {
                    ownedController.tearDown()
                }
            }
            .onChange(of: text) { _ in
                syncModel(preserveView: true)
            }
            .onChange(of: fileURL) { _ in
                syncAll(preserveView: false)
            }
            .onChange(of: diffLines) { newDiffLines in
                controller.setDiffHighlightMap(uri: modelURI, zeroBasedHighlights: newDiffLines)
            }
            .onChange(of: isEditable) { _ in
                syncActivation()
            }
            .onChange(of: isActive) { _ in
                syncActivation()
            }
            .onChange(of: isPreview) { _ in
                syncActivation()
                if !isPreview {
                    applyPendingNavigation()
                }
            }
            .onChange(of: wordWrapOverride) { _ in
                syncActivation()
            }
            .onChange(of: editorSettings) { _ in
                syncAppearanceAndActivation()
            }
            .onChange(of: resolvedTheme) { _ in
                controller.setTheme(resolvedTheme, isDark: isDarkTheme)
            }
            .onChange(of: navigationRequest) { _ in
                applyPendingNavigation()
            }
    }

    private func syncAll(preserveView: Bool) {
        configureCallbacks()
        controller.setTheme(resolvedTheme, isDark: isDarkTheme)
        controller.setFont(family: editorSettings.fontFamily, size: editorSettings.fontSize)
        syncModel(preserveView: preserveView)
        syncActivation()
        controller.setDiffHighlightMap(uri: modelURI, zeroBasedHighlights: diffLines)
    }

    private func syncAppearanceAndActivation() {
        configureCallbacks()
        controller.setTheme(resolvedTheme, isDark: isDarkTheme)
        controller.setFont(family: editorSettings.fontFamily, size: editorSettings.fontSize)
        syncActivation()
    }

    private func syncModel(preserveView: Bool) {
        let path = fileURL?.path ?? ""
        let readOnly = !(isEditable && isActive && !isPreview)
        controller.openOrUpdateModel(
            uri: modelURI,
            path: path,
            text: text,
            readOnly: readOnly,
            preserveView: preserveView
        )
    }

    private func syncActivation() {
        configureCallbacks()
        let path = fileURL?.path ?? ""
        let readOnly = !(isEditable && isActive && !isPreview)
        let insertSpaces = !EditorLanguageMapping.usesHardTabs(forPath: path)
        controller.isPreview = isPreview
        controller.keymap = editorSettings.keymap
        controller.isSurfaceFocused = isSurfaceFocused
        controller.isActive = isActive
        controller.activateModel(
            uri: modelURI,
            readOnly: readOnly,
            wordWrap: wordWrapOverride ?? editorSettings.wordWrap,
            tabSize: max(1, editorSettings.tabWidth),
            insertSpaces: insertSpaces,
            keymapProfile: editorSettings.keymapProfile
        )
    }

    private func configureCallbacks() {
        controller.onFocus = onFocus
        controller.onAskAgent = onAskAgent
        controller.onTextChange = { uri, updated in
            guard uri == modelURI, text != updated else { return }
            text = updated
        }
        controller.onCommand = { action in
            switch action {
            case .save: onSave()
            case .saveAll: onSaveAll()
            case .close: onClose()
            case .open: onOpen()
            case .nextDocument: onNextDocument()
            case .previousDocument: onPreviousDocument()
            case .hide: onHide()
            default: return false
            }
            return true
        }
    }

    private func applyPendingNavigation() {
        guard !isPreview, let request = navigationRequest else { return }
        controller.revealLocation(request.location, in: modelURI)
        onConsumeNavigation(request.id)
    }
}
