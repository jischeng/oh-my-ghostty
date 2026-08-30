import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum OhMyGhosttySettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case tabs
    case terminal
    case keyboard
    case plugins
    case advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .tabs: "rectangle.split.3x1"
        case .terminal: "terminal"
        case .keyboard: "keyboard"
        case .plugins: "puzzlepiece.extension"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
final class OhMyGhosttySettingsWindowController: NSWindowController {
    private var appearanceCancellable: AnyCancellable?

    init(
        settings: OhMyGhosttySettings,
        initialSelection: OhMyGhosttySettingsTab = .tabs
    ) {
        let root = SettingsView(settings: settings, initialSelection: initialSelection)
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hostingController)
        window.title = SettingsStrings(language: settings.language).windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("OhMyGhosttySettingsWindow")
        super.init(window: window)

        applyAppearance(settings)
        appearanceCancellable = settings.objectWillChange.sink { [weak self, weak settings] _ in
            DispatchQueue.main.async {
                guard let self, let settings else { return }
                self.applyAppearance(settings)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
            appearance = config.flatMap(NSAppearance.init(ghosttyConfig:))
        }
        if window.appearance?.name != appearance?.name {
            window.appearance = appearance
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @StateObject private var pluginManager: PluginInstallationManager
    @State private var selection: OhMyGhosttySettingsTab
    @State private var githubRepository = ""
    @State private var pluginOperation: String?
    @State private var pluginError: String?
    @State private var agentHookRevision = 0
    @State private var agentHookOperation: SupportedAgent?
    @State private var agentHookError: String?

    private var strings: SettingsStrings {
        SettingsStrings(language: settings.language)
    }

    private var sidebarSelection: Binding<OhMyGhosttySettingsTab?> {
        Binding(
            get: { selection },
            set: { if let selection = $0 { self.selection = selection } }
        )
    }

    init(
        settings: OhMyGhosttySettings,
        initialSelection: OhMyGhosttySettingsTab = .tabs
    ) {
        self.settings = settings
        self._pluginManager = StateObject(wrappedValue: .shared)
        self._selection = State(initialValue: initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(OhMyGhosttySettingsTab.allCases, selection: sidebarSelection) { tab in
                Label(strings.tabTitle(tab), systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 190)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(strings.tabTitle(selection))
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                Divider()
                detail
                    .formStyle(.grouped)
                    .frame(maxWidth: 680, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            Form {
                Section(strings.languageSection) {
                    Picker(strings.languageLabel, selection: $settings.language) {
                        Text(strings.languageSystem).tag(OhMyGhosttyLanguage.system)
                        Text("English").tag(OhMyGhosttyLanguage.english)
                        Text("简体中文").tag(OhMyGhosttyLanguage.simplifiedChinese)
                    }
                    Text(strings.languageCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(strings.sessionsSection) {
                    Toggle(
                        strings.restoreSessionsLabel,
                        isOn: $settings.restoreSessionsOnLaunch
                    )
                    Text(strings.restoreSessionsCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(strings.configurationSection) {
                    LabeledContent(strings.settingsFileLabel, value: OhMyGhosttySettings.fileURL.path)
                    LabeledContent(strings.precedenceLabel, value: strings.precedenceValue)
                    Text(strings.configurationCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .appearance:
            appearanceForm

        case .tabs:
            Form {
                Section(strings.layoutSection) {
                    Picker(strings.tabLayoutLabel, selection: $settings.tabLayout) {
                        Text(strings.horizontalOption).tag(Ghostty.Config.MacOSTabLayout.horizontal)
                        Text(strings.verticalOption).tag(Ghostty.Config.MacOSTabLayout.vertical)
                    }
                    .pickerStyle(.segmented)
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
                Section(strings.organizationSection) {
                    Picker(strings.groupingLabel, selection: $settings.groupingMode) {
                        ForEach(GhosttyTabGroupingMode.allCases, id: \.self) { mode in
                            Text(strings.groupingTitle(mode)).tag(mode)
                        }
                    }
                    Picker(strings.pathDisplayLabel, selection: $settings.tabPathDisplay) {
                        ForEach(OhMyGhosttyTabPathDisplay.allCases) { mode in
                            Text(strings.pathDisplayTitle(mode)).tag(mode)
                        }
                    }
                    Picker(strings.orderingLabel, selection: $settings.orderingMode) {
                        ForEach(GhosttyTabOrderingMode.allCases, id: \.self) { mode in
                            Text(strings.orderingTitle(mode)).tag(mode)
                        }
                    }
                    Toggle(strings.showShortcutLabelsLabel, isOn: $settings.showShortcutLabels)
                }
                HStack {
                    Spacer()
                    Button(strings.resetTabsButton) {
                        settings.resetTabs()
                    }
                }
            }

        case .terminal:
            Form {
                Section(strings.ghosttySection) {
                    Button(strings.openGhosttyConfigButton) {
                        (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                    }
                }
            }

        case .keyboard:
            Form {
                Section(strings.quickInputSection) {
                    LabeledContent(strings.quickInputShortcutLabel) {
                        HStack(spacing: 8) {
                            OMGShortcutRecorder(storageValue: $settings.quickInputShortcut)
                                .frame(width: 112, height: 24)
                            Button(strings.resetShortcutButton) {
                                settings.quickInputShortcut =
                                    OMGKeyboardShortcut.defaultQuickInput.storageValue
                            }
                        }
                    }
                    Text(strings.quickInputShortcutCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(strings.quickInputHeightLabel)
                        Slider(
                            value: $settings.quickInputHeight,
                            in: Double(AgentQuickInputMetrics.minimumHeight)...Double(
                                AgentQuickInputMetrics.maximumHeight
                            ),
                            step: 1
                        )
                        Text("\(Int(settings.quickInputHeight)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    Text(strings.quickInputHeightCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let shortcut = OMGKeyboardShortcut(
                        storageValue: settings.quickInputShortcut
                    ), let conflict = shortcut.conflictingMenuItemTitle() {
                        Label(
                            strings.shortcutConflictCaption(conflict),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                Section(strings.keybindingsSection) {
                    Text(strings.keybindingsCaption)
                        .foregroundStyle(.secondary)
                    Button(strings.openGhosttyConfigButton) {
                        (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                    }
                }
            }

        case .plugins:
            pluginsForm

        case .advanced:
            Form {
                Section(strings.forkSettingsSection) {
                    LabeledContent(strings.fileLabel, value: OhMyGhosttySettings.fileURL.path)
                    HStack {
                        Button(strings.openFileButton) {
                            settings.ensureFileExists()
                            NSWorkspace.shared.open(OhMyGhosttySettings.fileURL)
                        }
                        Button(strings.reloadButton) {
                            settings.reloadFromDisk()
                        }
                        Button(strings.revealButton) {
                            settings.ensureFileExists()
                            NSWorkspace.shared.activateFileViewerSelecting([
                                OhMyGhosttySettings.fileURL,
                            ])
                        }
                    }
                    if let error = settings.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var pluginsForm: some View {
        Form {
            Section(strings.officialPluginsSection) {
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

            Section(strings.installFromGitHubSection) {
                TextField("https://github.com/owner/omg-plugin", text: $githubRepository)
                    .textFieldStyle(.roundedBorder)
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

            Section(strings.agentIntegrationSection) {
                Toggle(strings.agentStatusHooksLabel, isOn: $settings.agentStatusHooksEnabled)
                ForEach(SupportedAgent.allCases) { agent in
                    agentHookRow(agent)
                }
                Button(strings.exportSSHInstallerButton, systemImage: "square.and.arrow.up") {
                    exportRemoteAgentInstaller()
                }
                .disabled(agentHookOperation != nil)
                Text(strings.agentHooksCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let agentHookError {
                    Text(agentHookError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section(strings.notificationsSection) {
                Toggle(strings.notifyTaskCompleteLabel, isOn: $settings.notifyTaskComplete)
                Toggle(strings.notifyAttentionLabel, isOn: $settings.notifyAttention)
                Toggle(strings.notificationSoundLabel, isOn: $settings.notificationSound)
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

    private var appearanceForm: some View {
        let appearance = settings.effectiveAppearance(using: inheritedGhosttyConfig)
        return Form {
            Section(strings.windowSection) {
                Picker(strings.appearancePickerLabel, selection: $settings.windowThemeOverride) {
                    Text(strings.ghosttyConfigOption).tag(OhMyGhosttyWindowTheme?.none)
                    ForEach(OhMyGhosttyWindowTheme.allCases) { theme in
                        Text(strings.windowThemeTitle(theme)).tag(Optional(theme))
                    }
                }
                resolutionRow(appearance.windowTheme)
            }

            Section(strings.terminalThemeSection) {
                GhosttyThemeField(
                    strings: strings,
                    title: strings.lightThemeLabel,
                    value: optionalStringBinding(\.lightThemeOverride)
                )
                GhosttyThemeField(
                    strings: strings,
                    title: strings.darkThemeLabel,
                    value: optionalStringBinding(\.darkThemeOverride)
                )
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

            Section(strings.fontSection) {
                LabeledContent(strings.fontFamilyLabel) {
                    TextField(
                        strings.inheritGhosttyPlaceholder,
                        text: optionalStringBinding(\.fontFamilyOverride)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.trailing)
                }
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

            Section(strings.transparencySection) {
                optionalSlider(
                    strings.backgroundOpacityLabel,
                    value: $settings.backgroundOpacityOverride,
                    inherited: appearance.backgroundOpacity.inheritedValue ?? 1,
                    range: 0.05...1,
                    step: 0.05,
                    suffix: "%",
                    displayScale: 100
                )
                Picker(strings.backgroundBlurLabel, selection: $settings.backgroundBlurOverride) {
                    Text(strings.ghosttyConfigOption).tag(OhMyGhosttyBackgroundBlur?.none)
                    ForEach(OhMyGhosttyBackgroundBlur.allCases) { blur in
                        Text(strings.blurTitle(blur)).tag(Optional(blur))
                    }
                }
                resolutionRow(appearance.backgroundOpacity)
                resolutionRow(appearance.backgroundBlur)
            }

            Section(strings.cursorSection) {
                Picker(strings.cursorStyleLabel, selection: $settings.cursorStyleOverride) {
                    Text(strings.ghosttyConfigOption).tag(OhMyGhosttyCursorStyle?.none)
                    ForEach(OhMyGhosttyCursorStyle.allCases) { cursor in
                        Text(strings.cursorTitle(cursor)).tag(Optional(cursor))
                    }
                }
                resolutionRow(appearance.cursorStyle)
            }

            Section(strings.appearanceTabsSection) {
                Picker(strings.rowDensityLabel, selection: $settings.tabRowDensity) {
                    ForEach(OhMyGhosttyTabRowDensity.allCases) { density in
                        Text(strings.densityTitle(density)).tag(density)
                    }
                }
                HStack {
                    Text(strings.tabIconSizeLabel)
                    Slider(value: $settings.tabIconSize, in: 12...20, step: 1)
                    Text("\(Int(settings.tabIconSize)) pt")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }

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

    @ViewBuilder
    private func agentHookRow(_ agent: SupportedAgent) -> some View {
        let revision = agentHookRevision
        let installationState = AgentHookInstaller().installationState(agent)
        let detectorOnly = agent.definition.hook.kind == .none
        let installed = installationState.isInstalled
        let statusText: String = switch (detectorOnly, installationState) {
        case (true, .missing): strings.agentDetectorMissing
        case (true, .updateAvailable): strings.agentDetectorUpdateRequired
        case (true, .current): strings.agentDetectorCurrent
        case (false, .missing): strings.agentHooksMissing
        case (false, .updateAvailable): strings.agentHooksUpdateRequired
        case (false, .current): strings.agentHooksCurrent
        }
        HStack {
            Image(agent.assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if agentHookOperation == agent {
                ProgressView()
                    .controlSize(.small)
            }
            Button(installed ? strings.agentUpdateButton : strings.agentInstallButton) {
                updateAgentHook(agent, remove: false)
            }
            .disabled(agentHookOperation != nil)
            if installed {
                Button(strings.agentRemoveButton) {
                    updateAgentHook(agent, remove: true)
                }
                .disabled(agentHookOperation != nil)
            }
        }
        .id("\(agent.id)-\(revision)")
    }

    private func updateAgentHook(
        _ agent: SupportedAgent,
        remove: Bool
    ) {
        agentHookError = nil
        agentHookOperation = agent
        defer {
            agentHookOperation = nil
            agentHookRevision &+= 1
        }
        do {
            let installer = AgentHookInstaller()
            if remove {
                try installer.uninstall(agent)
            } else {
                try installer.install(agent)
            }
        } catch {
            agentHookError = error.localizedDescription
        }
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
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(strings.inheritGhosttyPlaceholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.trailing)
                if !themes.isEmpty {
                    Menu {
                        ForEach(themes, id: \.self) { theme in
                            Button(theme) { value = theme }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if !value.isEmpty {
                    Button {
                        value = ""
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(strings.resetThemeHelp)
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(settings: .shared)
    }
}
