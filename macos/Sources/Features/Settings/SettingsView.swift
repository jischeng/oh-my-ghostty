import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum OhMyGhosttySettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case tabs
    case terminal
    case controls
    case editor
    case keyboard
    case git
    case ssh
    case agents
    case plugins
    case advanced

    static let primary: [Self] = [.general, .terminal, .controls, .editor, .tabs, .appearance, .keyboard]
    static let integrations: [Self] = [.agents, .git, .ssh, .plugins]

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .tabs: "rectangle.split.3x1"
        case .terminal: "terminal"
        case .controls: "cursorarrow"
        case .editor: "curlybraces.square"
        case .keyboard: "keyboard"
        case .git: "point.3.connected.trianglepath.dotted"
        case .ssh: "network"
        case .agents: "sparkles"
        case .plugins: "puzzlepiece.extension"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
final class OhMyGhosttySettingsWindowController: NSWindowController {
    private var appearanceCancellables: Set<AnyCancellable> = []

    init(
        settings: OhMyGhosttySettings,
        initialSelection: OhMyGhosttySettingsTab = .tabs
    ) {
        let root = SettingsView(settings: settings, initialSelection: initialSelection)
        let hostingController = NSHostingController(rootView: root)
        let window = SettingsWindow(contentViewController: hostingController)
        window.title = SettingsStrings(language: settings.language).windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("OhMyGhosttySettingsWindow")
        super.init(window: window)

        applyAppearance(settings)
        settings.objectWillChange.sink { [weak self, weak settings] _ in
            DispatchQueue.main.async {
                guard let self, let settings else { return }
                self.applyAppearance(settings)
            }
        }.store(in: &appearanceCancellables)
        // Re-apply when the app appearance changes (theme/config switches), so a
        // settings window opened before the change follows the new OMG theme.
        NSApp.publisher(for: \.effectiveAppearance).sink { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            self.applyAppearance(settings)
        }.store(in: &appearanceCancellables)
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .filter { $0.object == nil }
            .sink { [weak self, weak settings] _ in
                // The notification precedes replacement of the app's config.
                DispatchQueue.main.async {
                    guard let self, let settings else { return }
                    self.applyAppearance(settings)
                }
            }.store(in: &appearanceCancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // Capture the invoking terminal before Settings becomes the key window.
        let source = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { $0.windowController is TerminalController }
        if let screen = source?.screen, let window, window.screen != screen {
            window.setFrame(Self.frame(window.frame, on: screen.visibleFrame), display: false)
        }
        super.showWindow(sender)
    }

    static func frame(_ frame: NSRect, on visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(frame.width, visibleFrame.width),
            height: min(frame.height, visibleFrame.height)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func applyAppearance(_ settings: OhMyGhosttySettings) {
        guard let window else { return }
        let title = SettingsStrings(language: settings.language).windowTitle
        if window.title != title {
            window.title = title
        }
        let appearance: NSAppearance?
        switch settings.windowThemeOverride {
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        case .system:
            appearance = nil
        case nil:
            // Follow the same effective appearance as terminal windows so the
            // settings window tracks OMG's theme, including automatic switches.
            appearance = NSApp.effectiveAppearance
        }
        // Follow the OMG/terminal theme background color (e.g. Atom One Dark),
        // not the default aqua/darkAqua window background.
        window.backgroundColor = OMGThemeBackground.windowBackground()
        window.appearance = appearance
    }
}

final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @StateObject private var pluginManager: PluginInstallationManager
    @State private var selection: OhMyGhosttySettingsTab
    private let themeNames = GhosttyThemeCatalog.availableThemes()
    @State private var githubRepository = ""
    @State private var pluginOperation: String?
    @State private var pluginError: String?
    @State private var agentHookError: String?
    @State private var palette: OMGThemePalette
    @State private var searchText = ""
    @State private var integrationsExpanded = true
    @State private var jumpTarget: String?

    private var strings: SettingsStrings {
        SettingsStrings(language: settings.language)
    }

    init(
        settings: OhMyGhosttySettings,
        initialSelection: OhMyGhosttySettingsTab = .tabs,
        palette: OMGThemePalette? = nil,
        initialSearch: String = ""
    ) {
        self._searchText = State(initialValue: initialSearch)
        self._palette = State(initialValue: palette ?? OMGThemeBackground.palette())
        self.settings = settings
        self._pluginManager = StateObject(wrappedValue: .shared)
        self._selection = State(initialValue: initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(strings.settingsSearch, text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(9).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.top, 16)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(OhMyGhosttySettingsTab.primary) { navigationRow($0) }
                        DisclosureGroup(isExpanded: $integrationsExpanded) {
                            ForEach(OhMyGhosttySettingsTab.integrations) { navigationRow($0) }
                        } label: {
                            Text(strings.integrationsGroup).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 8).padding(.vertical, 10)
                        navigationRow(.advanced)
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
            .frame(width: 206)
            .background(Color(palette.sidebar).opacity(0.5))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings.tabTitle(selection) : strings.settingsSearch)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                Divider()
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollViewReader { proxy in
                        detail
                            .formStyle(OMGSettingsFormStyle())
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .task(id: jumpTarget) {
                                guard let jumpTarget else { return }
                                await Task.yield()
                                proxy.scrollTo(jumpTarget, anchor: .top)
                            }
                    }
                } else {
                    searchResults
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // Opaque theme background so the whole settings window renders the
        // theme color (e.g. Atom One Dark), not the content behind it.
        .omgThemedSurface(palette: palette)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)) { notification in
            guard notification.object == nil,
                  let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config else { return }
            palette = OMGThemeBackground.palette(config: config)
        }
        .onReceive(NotificationCenter.default.publisher(for: .omgSelectSettingsTab)) { notification in
            if let tab = notification.object as? OhMyGhosttySettingsTab {
                searchText = ""
                jumpTarget = nil
                if OhMyGhosttySettingsTab.integrations.contains(tab) { integrationsExpanded = true }
                selection = tab
            }
        }
    }

    private func navigationRow(_ tab: OhMyGhosttySettingsTab) -> some View {
        Button {
            searchText = ""
            jumpTarget = nil
            selection = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage).frame(width: 20)
                Text(strings.tabTitle(tab))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(selection == tab ? Color(palette.foreground).opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var searchResults: some View {
        let matches = SettingsSearchCatalog.entries(strings: strings).filter { $0.matches(searchText) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if matches.isEmpty { Text(strings.settingsNoResults).foregroundStyle(.secondary).padding(.vertical, 20) }
                ForEach(matches) { entry in
                    Button {
                        selection = entry.tab
                        if OhMyGhosttySettingsTab.integrations.contains(entry.tab) { integrationsExpanded = true }
                        jumpTarget = entry.anchor
                        searchText = ""
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.tab.systemImage).frame(width: 24).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).fontWeight(.medium)
                                Text(strings.tabTitle(entry.tab)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(24)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            Form {
                OMGSettingsSection(strings.languageSection) {
                    OMGSettingsRow(strings.languageLabel, subtitle: strings.languageCaption) {
                        OMGSettingsPicker(title: strings.languageLabel, selection: $settings.language,
                                          options: [.init(.system, strings.languageSystem), .init(.english, "English"),
                                                    .init(.simplifiedChinese, "简体中文")], showsTitle: false)
                    }
                }
                CoreSettingsSection(group: .lifecycle, settings: settings)
                OMGSettingsSection(strings.quitSection) {
                    OMGSettingsRow(strings.quitWithoutConfirmationLabel, subtitle: strings.quitWithoutConfirmationCaption) {
                        Toggle(strings.quitWithoutConfirmationLabel, isOn: $settings.quitWithoutConfirmation)
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            }

        case .appearance:
            appearanceForm

        case .tabs:
            Form {
                OMGSettingsSection(strings.layoutSection) {
                    OMGSettingsRow(strings.tabLayoutLabel) {
                        OMGSettingsSegments(title: strings.tabLayoutLabel, selection: $settings.tabLayout,
                                            options: [.init(.horizontal, strings.horizontalOption), .init(.vertical, strings.verticalOption)])
                            .frame(width: 210)
                    }
                    Text(strings.tabLayoutCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(strings.showSidebarLabel, isOn: $settings.sidebarVisible)
                    HStack {
                        Text(strings.sidebarWidthLabel)
                        Slider(value: $settings.defaultSidebarWidth, in: 176...480, step: 1)
                        Text("\(Int(settings.defaultSidebarWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    Toggle(strings.rememberSidebarWidthLabel, isOn: $settings.rememberSidebarWidth)
                }
                OMGSettingsSection(strings.organizationSection) {
                    OMGSettingsRow(strings.groupingLabel) {
                        OMGSettingsPicker(title: strings.groupingLabel, selection: $settings.groupingMode,
                                          options: GhosttyTabGroupingMode.allCases.map { .init($0, strings.groupingTitle($0)) }, showsTitle: false)
                    }
                    Divider()
                    OMGSettingsRow(strings.pathDisplayLabel) {
                        OMGSettingsPicker(title: strings.pathDisplayLabel, selection: $settings.tabPathDisplay,
                                          options: OhMyGhosttyTabPathDisplay.allCases.map { .init($0, strings.pathDisplayTitle($0)) }, showsTitle: false)
                    }
                    Divider()
                    OMGSettingsRow(strings.orderingLabel) {
                        OMGSettingsPicker(title: strings.orderingLabel, selection: $settings.orderingMode,
                                          options: GhosttyTabOrderingMode.allCases.map { .init($0, strings.orderingTitle($0)) }, showsTitle: false)
                    }
                    Divider()
                    Toggle(strings.showShortcutLabelsLabel, isOn: $settings.showShortcutLabels)
                }
                tabAppearanceSection
                resizeRenderingSection
                HStack {
                    Spacer()
                    Button(strings.resetTabsButton) {
                        settings.resetTabs()
                    }
                }
            }

        case .terminal:
            Form {
                CoreSettingsSection(group: .shell, settings: settings)
                OMGSettingsSection(strings.sessionRecoverySection) {
                    OMGSettingsRow(strings.startupModeLabel, subtitle: strings.sessionRecoveryCaption) {
                        OMGSettingsPicker(title: strings.startupModeLabel, selection: $settings.startupMode,
                                          options: OMGStartupMode.allCases.map { .init($0, strings.startupModeTitle($0)) }, showsTitle: false, width: 190)
                    }
                }
                CoreSettingsSection(group: .notifications, settings: settings)
            }

        case .controls:
            Form {
                OMGSettingsSection(strings.quickInputSection) { QuickInputSettingsView(settings: settings) }
                CoreSettingsSection(group: .selection, settings: settings)
                CoreSettingsSection(group: .clipboard, settings: settings)
                CoreSettingsSection(group: .mouse, settings: settings)
                CoreSettingsSection(group: .keyboard, settings: settings)
            }

        case .editor:
            Form {
                OMGSettingsSection(strings.editorOpeningSection) {
                    OMGSettingsRow(strings.editorFileOpenDestinationLabel) {
                        OMGSettingsPicker(title: strings.editorFileOpenDestinationLabel, selection: $settings.editorFileOpenDestination,
                                          options: EditorOpenDestination.allCases.map { .init($0, strings.editorOpenDestinationTitle($0)) }, showsTitle: false)
                    }
                    Divider()
                    OMGSettingsRow(strings.editorDirectoryOpenDestinationLabel) {
                        OMGSettingsPicker(title: strings.editorDirectoryOpenDestinationLabel, selection: $settings.editorDirectoryOpenDestination,
                                          options: EditorOpenDestination.allCases.map { .init($0, strings.editorOpenDestinationTitle($0)) }, showsTitle: false)
                    }
                    Text(strings.editorOpeningCaption).font(.caption).foregroundStyle(.secondary)
                }
                OMGSettingsSection(strings.editorBehaviorSection) {
                    OMGSettingsRow(strings.editorKeymapPresetLabel, subtitle: strings.editorKeymapPresetCaption) {
                        OMGSettingsSegments(title: strings.editorKeymapPresetLabel, selection: $settings.editorKeymapPreset,
                                            options: EditorKeymapPreset.allCases.map { .init($0, strings.editorKeymapPresetTitle($0)) }).frame(width: 180)
                    }
                    Divider()
                    Toggle(strings.editorWordWrapLabel, isOn: $settings.editorWordWrap)
                    Divider()
                    Toggle(strings.editorAutoClosePairsLabel, isOn: $settings.editorAutoClosePairs)
                }
                OMGSettingsSection(strings.editorThemeSection) {
                    OMGSettingsRow(strings.editorSyntaxThemeLabel, subtitle: strings.editorCatalogCaption) {
                        OMGSettingsPicker(title: strings.editorSyntaxThemeLabel, selection: editorThemeSelection,
                                          options: [.init("follow", strings.editorSyntaxThemeTitle(.followTerminal))] +
                                            themeNames.map { .init("catalog:" + $0, $0) } +
                                            EditorSyntaxTheme.allCases.filter { $0 != .followTerminal }.map { .init("builtin:" + $0.rawValue, $0.title) },
                                          showsTitle: false, width: 210)
                    }
                    if !settings.editorSettings.followsOMG {
                        HStack {
                            Text(strings.backgroundOpacityLabel)
                            Slider(value: editorOpacityBinding, in: 0.05...1, step: 0.05)
                            Text("\(Int(editorOpacityBinding.wrappedValue * 100))%")
                                .monospacedDigit().frame(width: 45)
                        }
                        OMGSettingsPicker(title: strings.backgroundBlurLabel, selection: editorBlurBinding,
                                          options: OhMyGhosttyBackgroundBlur.allCases.map { .init($0, strings.blurTitle($0)) })
                    }
                    if settings.editorSettings.followsOMG {
                        Text(strings.editorThemeInheritedCaption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                OMGSettingsSection(strings.editorTypographySection) {
                    OMGSettingsRow(strings.editorFontFamilyLabel) {
                        OMGSettingsPicker(title: strings.editorFontFamilyLabel, selection: $settings.editorFontFamily,
                                          options: EditorFontFamily.allCases.map { .init($0, strings.editorFontFamilyTitle($0)) }, showsTitle: false)
                    }
                    Divider()
                    HStack {
                        Text(strings.editorFontSizeLabel)
                        Slider(value: $settings.editorFontSize, in: 8...36, step: 0.5)
                        Text(String(format: "%.1f pt", settings.editorFontSize))
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                    OMGSettingsRow(strings.editorTabWidthLabel) {
                        OMGSettingsNumberControl(title: strings.editorTabWidthLabel, value: $settings.editorTabWidth, range: 1...12)
                    }
                }
                HStack {
                    Spacer()
                    Button(strings.resetEditorButton) {
                        settings.editorFileOpenDestination = .currentPane
                        settings.editorDirectoryOpenDestination = .currentPane
                        settings.editorKeymapPreset = .idea
                        settings.editorBackgroundMode = .followTerminal
                        settings.editorSyntaxTheme = .followTerminal
                        settings.editorThemeName = nil
                        settings.editorAutoClosePairs = true
                        settings.editorOpacity = 1
                        settings.editorBlur = .disabled
                        settings.editorFontFamily = .jetbrainsMono
                        settings.editorFontSize = 13
                        settings.editorTabWidth = 4
                        settings.editorWordWrap = false
                    }
                }
            }

        case .keyboard:
            Form {
                OMGSettingsSection(WorkspaceL10n.text("Workspaces", "工作区")) {
                    WorkspaceShortcutSettingsView()
                }
                OMGSettingsSection(strings.quickInputShortcutLabel) { QuickInputShortcutSettingsView(settings: settings) }
                OMGSettingsSection(strings.rightSidebarShortcutsSection) {
                    Text(strings.rightSidebarShortcutsCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(1...4, id: \.self) { slot in
                        LabeledContent(strings.inspectorPanelSlotLabel(slot: slot)) {
                            HStack(spacing: 8) {
                                OMGShortcutRecorder(
                                    storageValue: Binding(
                                        get: { settings.inspectorPanelShortcut(slot: slot) },
                                        set: { settings.setInspectorPanelShortcut(slot: slot, value: $0) }
                                    )
                                )
                                .frame(width: 112, height: 24)
                                Button(strings.resetShortcutButton) {
                                    settings.setInspectorPanelShortcut(
                                        slot: slot,
                                        value: OMGKeyboardShortcut.defaultInspectorPanel(slot: slot).storageValue
                                    )
                                }
                            }
                        }
                        if let shortcut = OMGKeyboardShortcut(
                            storageValue: settings.inspectorPanelShortcut(slot: slot)
                        ), let conflict = shortcut.conflictingMenuItemTitle() {
                            Label(
                                strings.shortcutConflictCaption(conflict),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                OMGSettingsSection(strings.keybindingsSection) {
                    Text(strings.keybindingsCaption)
                        .foregroundStyle(.secondary)
                    Button(strings.openGhosttyConfigButton) {
                        (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                    }
                }
            }

        case .git:
            Form {
                OMGSettingsSection(strings.gitSection) {
                    OMGSettingsRow(strings.gitAutoFetchLabel, subtitle: strings.gitAutoFetchCaption) {
                        OMGSettingsPicker(title: strings.gitAutoFetchLabel, selection: $settings.gitAutoFetchInterval,
                                          options: Array(Set([0, 1, 2, 5, 10, 15, 30, 60, settings.gitAutoFetchInterval])).sorted().map {
                                              .init($0, strings.gitAutoFetchIntervalTitle($0))
                                          }, showsTitle: false)
                    }
                }
                GitCommitAISettingsView(settings: settings).id("gitAI")
            }
        case .ssh:
            Form {
                OMGSettingsSection(strings.sshSettingsTitle) {
                    SSHRegistrationSettingsView(strings: strings)
                }.id("sshRegistration")
            }
        case .agents:
            Form {
                AgentIntegrationSettingsView(
                    strings: strings, settings: settings,
                    exportInstaller: exportRemoteAgentInstaller, exportError: agentHookError
                ).id("agentIntegrations")
                OMGSettingsSection(strings.agentBehaviorSection) {
                    Toggle(strings.openQuickInputOnAgentStartLabel, isOn: $settings.openQuickInputOnAgentStart)
                        .help(strings.openQuickInputOnAgentStartCaption)
                    Toggle(strings.openQuickInputOnAgentCompleteLabel, isOn: $settings.openQuickInputOnAgentComplete)
                        .help(strings.openQuickInputOnAgentCompleteCaption)
                }
                OMGSettingsSection(strings.agentHistorySection) {
                    OMGSettingsRow(strings.agentHistoryLimitLabel, subtitle: strings.agentHistoryLimitCaption) {
                        HStack {
                            Slider(value: $settings.agentHistoryLimit, in: 100...50000, step: 100)
                            Text("\(Int(settings.agentHistoryLimit))").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }.frame(width: 220)
                    }
                }
                OMGSettingsSection(strings.notificationsSection) {
                    Toggle(strings.notifyTaskCompleteLabel, isOn: $settings.notifyTaskComplete)
                    Toggle(strings.notifyAttentionLabel, isOn: $settings.notifyAttention)
                    Toggle(strings.notificationSoundLabel, isOn: $settings.notificationSound)
                }
            }
        case .plugins:
            pluginsForm

        case .advanced:
            Form {
                OMGSettingsSection(strings.settingsLocationsSection) {
                    OMGSettingsRow(strings.settingsFileLabel, subtitle: OhMyGhosttySettings.fileURL.path) {
                        Button(strings.openFileButton) {
                            settings.ensureFileExists()
                            NSWorkspace.shared.open(OhMyGhosttySettings.fileURL)
                        }
                    }
                    Divider()
                    OMGSettingsRow(strings.reloadButton) {
                        Button(strings.reloadButton) { settings.reloadFromDisk() }
                    }
                    Divider()
                    OMGSettingsRow(strings.revealButton) {
                        Button(strings.revealButton) {
                            settings.ensureFileExists()
                            NSWorkspace.shared.activateFileViewerSelecting([OhMyGhosttySettings.fileURL])
                        }
                    }
                    Divider()
                    OMGSettingsRow(strings.ghosttySection, subtitle: strings.coreInheritanceCaption) {
                        Button(strings.openGhosttyConfigButton) {
                            (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                        }
                    }
                    Text(strings.precedenceLabel + " · " + strings.precedenceValue).font(.caption).foregroundStyle(.secondary)
                    if let error = settings.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }.id("settingsFiles")
            }
        }
    }

    private var pluginsForm: some View {
        Form {
            OMGSettingsSection(strings.officialPluginsSection) {
                ForEach(PluginInstallationManager.officialPlugins, id: \.id) { manifest in
                    PluginManagementRow(
                        strings: strings,
                        manifest: manifest,
                        installed: pluginManager.isInstalled(manifest.id),
                        enabled: pluginManager.isEnabled(manifest.id),
                        operation: pluginOperation,
                        install: { installOfficial(manifest) },
                        update: { installOfficial(manifest) },
                        toggle: { togglePlugin(manifest) },
                        uninstall: { uninstall(manifest) }
                    )
                }
                Text(strings.officialPluginsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OMGSettingsSection(strings.installFromGitHubSection) {
                TextField("https://github.com/owner/omg-plugin", text: $githubRepository)
                    .textFieldStyle(OMGSettingsTextFieldStyle())
                HStack {
                    Button(strings.installButton) { installFromGitHub() }
                        .disabled(githubRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pluginOperation != nil)
                    if let pluginOperation {
                        ProgressView(strings.pluginOperationLabel(pluginOperation))
                            .controlSize(.small)
                    }
                }
                Text(strings.installFromGitHubCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let pluginError {
                    Text(pluginError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

        }
    }

    private func installOfficial(_ manifest: PluginManifest) {
        performPluginOperation("Installing") {
            try pluginManager.installOfficial(manifest.id)
        }
    }

    private func togglePlugin(_ manifest: PluginManifest) {
        performPluginOperation(pluginManager.isEnabled(manifest.id) ? "Disabling" : "Enabling") {
            if pluginManager.isEnabled(manifest.id) {
                try pluginManager.disable(manifest.id)
            } else {
                try pluginManager.enable(manifest.id)
            }
        }
    }

    private func uninstall(_ manifest: PluginManifest) {
        performPluginOperation("Uninstalling") {
            try pluginManager.uninstall(manifest.id)
        }
    }

    private func performPluginOperation(
        _ label: String,
        operation: () throws -> Void
    ) {
        pluginError = nil
        pluginOperation = label
        defer { pluginOperation = nil }
        do { try operation() } catch { pluginError = error.localizedDescription }
    }

    private func installFromGitHub() {
        guard let url = URL(string: githubRepository.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            pluginError = strings.invalidGitHubURL
            return
        }
        pluginError = nil
        pluginOperation = "Downloading"
        Task {
            do {
                _ = try await pluginManager.install(from: url)
                githubRepository = ""
            } catch {
                pluginError = error.localizedDescription
            }
            pluginOperation = nil
        }
    }

    private var editorThemeSelection: Binding<String> {
        Binding(
            get: {
                if let name = settings.editorThemeName { return "catalog:" + name }
                return settings.editorSettings.followsOMG ? "follow" : "builtin:" + settings.editorSyntaxTheme.rawValue
            },
            set: { value in
                if value.hasPrefix("catalog:") {
                    settings.editorThemeName = String(value.dropFirst(8))
                } else {
                    settings.editorThemeName = nil
                    settings.editorSyntaxTheme = value == "follow" ? .followTerminal
                        : EditorSyntaxTheme(rawValue: String(value.dropFirst(8))) ?? .followTerminal
                }
            }
        )
    }

    private var editorOpacityBinding: Binding<Double> {
        Binding(
            get: {
                settings.editorSettings.followsOMG
                    ? settings.effectiveAppearance(using: inheritedGhosttyConfig).backgroundOpacity.effectiveValue
                    : settings.editorOpacity
            },
            set: { if !settings.editorSettings.followsOMG { settings.editorOpacity = $0 } }
        )
    }

    private var editorBlurBinding: Binding<OhMyGhosttyBackgroundBlur> {
        Binding(
            get: {
                settings.editorSettings.followsOMG
                    ? settings.backgroundBlurOverride ?? inheritedGhosttyConfig.editorBackgroundBlur
                    : settings.editorBlur
            },
            set: { if !settings.editorSettings.followsOMG { settings.editorBlur = $0 } }
        )
    }

    private var followsSystemTheme: Binding<Bool> {
        Binding(
            get: {
                if let mode = settings.windowThemeOverride { return mode == .system }
                return !["light", "dark"].contains(inheritedGhosttyConfig.windowTheme ?? "auto")
            },
            set: { follows in
                settings.windowThemeOverride = follows ? .system
                    : (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
            }
        )
    }

    private var tabAppearanceSection: some View {
        OMGSettingsSection(strings.appearanceTabsSection) {
            OMGSettingsPicker(title: strings.rowDensityLabel, selection: $settings.tabRowDensity,
                              options: OhMyGhosttyTabRowDensity.allCases.map { .init($0, strings.densityTitle($0)) })
            HStack {
                Text(strings.tabIconSizeLabel)
                Slider(value: $settings.tabIconSize, in: 12...20, step: 1)
                Text("\(Int(settings.tabIconSize)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }

    private var resizeRenderingSection: some View {
        OMGSettingsSection(strings.resizeRenderingSection) {
            OMGSettingsRow(strings.terminalResizeRenderingLabel, subtitle: strings.terminalResizeRenderingCaption) {
                OMGSettingsPicker(title: strings.terminalResizeRenderingLabel, selection: $settings.terminalResizeRendering,
                                  options: TerminalResizeRenderingMode.allCases.map { .init($0, strings.terminalResizeRenderingTitle($0)) },
                                  showsTitle: false, width: 190)
            }
        }
    }

    private var appearanceForm: some View {
        let appearance = settings.effectiveAppearance(using: inheritedGhosttyConfig)
        return Form {
            OMGSettingsSection(strings.terminalThemeSection) {
                Toggle(strings.followSystemThemeLabel, isOn: followsSystemTheme)
                if followsSystemTheme.wrappedValue {
                    GhosttyThemeField(strings: strings, title: strings.lightThemeLabel,
                                      value: optionalStringBinding(\.lightThemeOverride))
                    GhosttyThemeField(strings: strings, title: strings.darkThemeLabel,
                                      value: optionalStringBinding(\.darkThemeOverride))
                } else {
                    OMGSettingsPicker(title: strings.appearancePickerLabel, selection: $settings.windowThemeOverride,
                                      options: [.init(nil, strings.ghosttyConfigOption), .init(.light, strings.windowThemeTitle(.light)),
                                                .init(.dark, strings.windowThemeTitle(.dark))])
                    GhosttyThemeField(
                        strings: strings,
                        title: strings.unifiedThemeLabel,
                        value: Binding(
                            get: { settings.windowThemeOverride == .light ? settings.lightThemeOverride ?? "" : settings.darkThemeOverride ?? "" },
                            set: { value in
                                settings.lightThemeOverride = value.isEmpty ? nil : value
                                settings.darkThemeOverride = value.isEmpty ? nil : value
                            }
                        )
                    )
                }
                resolutionRow(appearance.theme)
                HStack {
                    Text(strings.resolvedBackgroundLabel)
                    Spacer()
                    Circle()
                        .fill(inheritedGhosttyConfig.backgroundColor)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                        .frame(width: 18, height: 18)
                }
                Text(strings.themeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OMGSettingsSection(strings.fontSection) {
                OMGSettingsPicker(title: strings.fontFamilyLabel, selection: optionalStringBinding(\.fontFamilyOverride),
                                  options: [.init("", strings.inheritGhosttyPlaceholder)] +
                                    NSFontManager.shared.availableFontFamilies.sorted().map { .init($0, $0) }, width: 210)
                optionalSlider(
                    strings.fontSizeLabel,
                    value: $settings.fontSizeOverride,
                    inherited: appearance.fontSize.inheritedValue ?? appearance.fontSize.defaultValue,
                    range: 6...72,
                    step: 0.5,
                    suffix: "pt"
                )
                resolutionRow(appearance.fontFamily)
            }

            OMGSettingsSection(strings.transparencySection) {
                optionalSlider(
                    strings.backgroundOpacityLabel,
                    value: $settings.backgroundOpacityOverride,
                    inherited: appearance.backgroundOpacity.inheritedValue ?? 1,
                    range: 0.05...1,
                    step: 0.05,
                    suffix: "%",
                    displayScale: 100
                )
                OMGSettingsPicker(title: strings.backgroundBlurLabel, selection: $settings.backgroundBlurOverride,
                                  options: [.init(nil, strings.ghosttyConfigOption)] +
                                    OhMyGhosttyBackgroundBlur.allCases.map { .init(Optional($0), strings.blurTitle($0)) }, width: 210)
                resolutionRow(appearance.backgroundOpacity)
                resolutionRow(appearance.backgroundBlur)
            }

            OMGSettingsSection(strings.cursorSection) {
                OMGSettingsPicker(title: strings.cursorStyleLabel, selection: $settings.cursorStyleOverride,
                                  options: [.init(nil, strings.ghosttyConfigOption)] +
                                    OhMyGhosttyCursorStyle.allCases.map { .init(Optional($0), strings.cursorTitle($0)) })
                resolutionRow(appearance.cursorStyle)
            }

            CoreSettingsSection(group: .cursor, settings: settings)

            HStack {
                Text(strings.appearanceLiveCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(strings.resetAppearanceButton) {
                    settings.resetAppearance()
                }
            }
        }
    }

    private var inheritedGhosttyConfig: Ghostty.Config {
        (NSApp.delegate as? AppDelegate)?.ghostty.inheritedConfig ?? Ghostty.Config(at: nil)
    }

    private func optionalStringBinding(
        _ keyPath: ReferenceWritableKeyPath<OhMyGhosttySettings, String?>
    ) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] ?? "" },
            set: { settings[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func optionalSlider(
        _ title: String,
        value: Binding<Double?>,
        inherited: Double,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String,
        displayScale: Double = 1
    ) -> some View {
        let isOverridden = Binding(
            get: { value.wrappedValue != nil },
            set: { enabled in value.wrappedValue = enabled ? inherited : nil }
        )
        let sliderValue = Binding(
            get: { value.wrappedValue ?? inherited },
            set: { value.wrappedValue = $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(title, isOn: isOverridden)
                Slider(value: sliderValue, in: range, step: step)
                    .disabled(!isOverridden.wrappedValue)
                Text(formattedSliderValue(
                    sliderValue.wrappedValue,
                    scale: displayScale,
                    suffix: suffix
                ))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    private func formattedSliderValue(
        _ value: Double,
        scale: Double,
        suffix: String
    ) -> String {
        String(format: scale == 1 ? "%.1f%@" : "%.0f%@", value * scale, suffix)
    }

    private func resolutionRow<Value>(_ setting: ResolvedSetting<Value>) -> some View {
        HStack(spacing: 5) {
            Text("\(strings.effectivePrefix): \(String(describing: setting.effectiveValue))")
            Text("•")
            Text(strings.appearanceSourceTitle(setting.source))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func exportRemoteAgentInstaller() {
        agentHookError = nil
        do {
            let script = try AgentHookInstaller.remoteInstallerScript()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "omg-agent-hooks.py"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            agentHookError = error.localizedDescription
        }
    }

    private func capabilityRow(_ title: String, status: String) -> some View {
        LabeledContent(title) {
            Text(status)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PluginManagementRow: View {
    let strings: SettingsStrings
    let manifest: PluginManifest
    let installed: Bool
    let enabled: Bool
    let operation: String?
    let install: () -> Void
    let update: () -> Void
    let toggle: () -> Void
    let uninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: pluginSystemImage)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pluginTitle)
                        .font(.headline)
                    Text("v\(manifest.version) · \(status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if installed {
                    Menu {
                        Button(enabled ? strings.pluginDisableButton : strings.pluginEnableButton, action: toggle)
                        Button(strings.pluginUpdateButton, action: update)
                        Divider()
                        Button(strings.pluginUninstallButton, role: .destructive, action: uninstall)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                } else {
                    Button(strings.installButton, action: install)
                }
            }
            Text(manifest.id == SSHPlugin.pluginID
                ? strings.sshPluginCaption
                : strings.genericPluginCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(operation == nil ? 1 : 0.7)
    }

    private var pluginTitle: String {
        switch manifest.id {
        case SSHPlugin.pluginID: "SSH"
        default: manifest.id
        }
    }

    private var pluginSystemImage: String {
        switch manifest.id {
        case SSHPlugin.pluginID: "cloud"
        default: "puzzlepiece.extension"
        }
    }

    private var status: String {
        guard installed else { return strings.pluginNotInstalled }
        return enabled ? strings.pluginEnabled : strings.pluginDisabled
    }
}

private struct GhosttyThemeField: View {
    let strings: SettingsStrings
    let title: String
    @Binding var value: String
    private let themes = GhosttyThemeCatalog.availableThemes()

    init(strings: SettingsStrings, title: String, value: Binding<String>) {
        self.strings = strings
        self.title = title
        self._value = value
    }

    var body: some View {
        OMGSettingsPicker(title: title, selection: $value,
                          options: [.init("", strings.inheritGhosttyPlaceholder)] +
                            (!value.isEmpty && !themes.contains(value) ? [.init(value, value)] : []) +
                            themes.map { .init($0, $0) }, width: 210)
    }

}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(settings: .shared)
    }
}
