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
        window.title = "Settings"
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
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var pluginManager: PluginInstallationManager
    @State private var selection: OhMyGhosttySettingsTab
    @State private var githubRepository = ""
    @State private var pluginOperation: String?
    @State private var pluginError: String?
    @State private var agentHookRevision = 0
    @State private var agentHookOperation: SupportedAgent?
    @State private var agentHookError: String?

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
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(OhMyGhosttySettingsTab.allCases) { tab in
                        SettingsSidebarRow(
                            tab: tab,
                            selected: selection == tab,
                            select: { selection = tab }
                        )
                    }
                }
                .padding(8)
            }
            .frame(width: 190)
            .background(sidebarBackground)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(selection.title)
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

    private var sidebarBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(nsColor: .controlBackgroundColor)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            Form {
                Section("Configuration") {
                    LabeledContent("OMG Settings", value: OhMyGhosttySettings.fileURL.path)
                    LabeledContent("Precedence", value: "Runtime → OMG → Ghostty → Defaults")
                    Text("Tab layout, appearance, and plugin preferences each have one canonical page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .appearance:
            appearanceForm

        case .tabs:
            Form {
                Section("Layout") {
                    Picker("Tab Layout", selection: $settings.tabLayout) {
                        Text("Horizontal").tag(Ghostty.Config.MacOSTabLayout.horizontal)
                        Text("Vertical").tag(Ghostty.Config.MacOSTabLayout.vertical)
                    }
                    .pickerStyle(.segmented)
                    Text("Applies to newly created windows; existing terminals are not rebuilt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Show Sidebar", isOn: $settings.sidebarVisible)
                    HStack {
                        Text("Sidebar Width")
                        Slider(value: $settings.defaultSidebarWidth, in: 176...480, step: 1)
                        Text("\(Int(settings.defaultSidebarWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    Toggle("Remember Resized Width", isOn: $settings.rememberSidebarWidth)
                }
                Section("Organization") {
                    Picker("Grouping", selection: $settings.groupingMode) {
                        ForEach(GhosttyTabGroupingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("Path Display", selection: $settings.tabPathDisplay) {
                        ForEach(OhMyGhosttyTabPathDisplay.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("Ordering", selection: $settings.orderingMode) {
                        ForEach(GhosttyTabOrderingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Show Shortcut Labels", isOn: $settings.showShortcutLabels)
                }
                HStack {
                    Spacer()
                    Button("Reset Tabs Settings") {
                        settings.resetTabs()
                    }
                }
            }

        case .terminal:
            Form {
                Section("Ghostty") {
                    Button("Open Ghostty Configuration") {
                        (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                    }
                }
            }

        case .keyboard:
            Form {
                Section("Ghostty Keybindings") {
                    Text("Keyboard shortcuts are defined by Ghostty configuration. Position labels are configured once in Tabs.")
                        .foregroundStyle(.secondary)
                    Button("Open Ghostty Configuration") {
                        (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                    }
                }
            }

        case .plugins:
            pluginsForm

        case .advanced:
            Form {
                Section("Fork Settings") {
                    LabeledContent("File", value: OhMyGhosttySettings.fileURL.path)
                    HStack {
                        Button("Open File") {
                            settings.ensureFileExists()
                            NSWorkspace.shared.open(OhMyGhosttySettings.fileURL)
                        }
                        Button("Reload") {
                            settings.reloadFromDisk()
                        }
                        Button("Reveal") {
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
            Section("Official Plugins") {
                ForEach(PluginInstallationManager.officialPlugins, id: \.id) { manifest in
                    PluginManagementRow(
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
                Text("Official plugins are installed independently from the OMG app. SSH uses your existing OpenSSH configuration and credentials. Built-in agent hook adapters are configured below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Install from GitHub") {
                TextField("https://github.com/owner/omg-plugin", text: $githubRepository)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Install") { installFromGitHub() }
                        .disabled(githubRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pluginOperation != nil)
                    if let pluginOperation {
                        ProgressView(pluginOperation)
                            .controlSize(.small)
                    }
                }
                Text("Only HTTPS GitHub repositories with a validated manifest.json are accepted. Installed external executables remain disabled until the supervised runtime is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let pluginError {
                    Text(pluginError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Agent Integration") {
                Toggle("Enable Normalized Status Events", isOn: $settings.agentStatusHooksEnabled)
                ForEach(SupportedAgent.allCases) { agent in
                    agentHookRow(agent)
                }
                Button("Export SSH Installer…", systemImage: "square.and.arrow.up") {
                    exportRemoteAgentInstaller()
                }
                .disabled(agentHookOperation != nil)
                Text("Hooks write bounded presentation-only OSC events to the owning terminal. Exported hooks can be reviewed and run explicitly in an SSH account. Agent icons and status are presented by Vertical Tabs; Horizontal keeps Ghostty's native tab UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let agentHookError {
                    Text(agentHookError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("Notifications") {
                Toggle("Task Complete", isOn: $settings.notifyTaskComplete)
                Toggle("Attention Required", isOn: $settings.notifyAttention)
                Toggle("Play Sound", isOn: $settings.notificationSound)
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
            pluginError = "Enter a valid HTTPS GitHub repository URL."
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
            Section("Window") {
                Picker("Appearance", selection: $settings.windowThemeOverride) {
                    Text("Ghostty config").tag(OhMyGhosttyWindowTheme?.none)
                    ForEach(OhMyGhosttyWindowTheme.allCases) { theme in
                        Text(theme.title).tag(Optional(theme))
                    }
                }
                resolutionRow(appearance.windowTheme)
            }

            Section("Terminal Theme") {
                GhosttyThemeField(
                    title: "Light Theme",
                    value: optionalStringBinding(\.lightThemeOverride)
                )
                GhosttyThemeField(
                    title: "Dark Theme",
                    value: optionalStringBinding(\.darkThemeOverride)
                )
                resolutionRow(appearance.theme)
                HStack {
                    Text("Resolved Background")
                    Spacer()
                    Circle()
                        .fill(inheritedGhosttyConfig.backgroundColor)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                        .frame(width: 18, height: 18)
                }
                Text("Foreground, selection, and palette remain owned by the selected Ghostty theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Font") {
                LabeledContent("Font Family") {
                    TextField(
                        "Inherit Ghostty config",
                        text: optionalStringBinding(\.fontFamilyOverride)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.trailing)
                }
                optionalSlider(
                    "Font Size",
                    value: $settings.fontSizeOverride,
                    inherited: appearance.fontSize.inheritedValue ?? appearance.fontSize.defaultValue,
                    range: 6...72,
                    step: 0.5,
                    suffix: "pt"
                )
                resolutionRow(appearance.fontFamily)
            }

            Section("Transparency") {
                optionalSlider(
                    "Background Opacity",
                    value: $settings.backgroundOpacityOverride,
                    inherited: appearance.backgroundOpacity.inheritedValue ?? 1,
                    range: 0.05...1,
                    step: 0.05,
                    suffix: "%",
                    displayScale: 100
                )
                Picker("Background Blur", selection: $settings.backgroundBlurOverride) {
                    Text("Ghostty config").tag(OhMyGhosttyBackgroundBlur?.none)
                    ForEach(OhMyGhosttyBackgroundBlur.allCases) { blur in
                        Text(blur.title).tag(Optional(blur))
                    }
                }
                resolutionRow(appearance.backgroundOpacity)
                resolutionRow(appearance.backgroundBlur)
            }

            Section("Cursor") {
                Picker("Style", selection: $settings.cursorStyleOverride) {
                    Text("Ghostty config").tag(OhMyGhosttyCursorStyle?.none)
                    ForEach(OhMyGhosttyCursorStyle.allCases) { cursor in
                        Text(cursor.title).tag(Optional(cursor))
                    }
                }
                resolutionRow(appearance.cursorStyle)
            }

            Section("Tabs") {
                Picker("Row Density", selection: $settings.tabRowDensity) {
                    ForEach(OhMyGhosttyTabRowDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                HStack {
                    Text("Icon Size")
                    Slider(value: $settings.tabIconSize, in: 12...20, step: 1)
                    Text("\(Int(settings.tabIconSize)) pt")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }

            HStack {
                Text("Changes apply live to existing terminals without restarting the shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Ghostty") {
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
            Text("Effective: \(String(describing: setting.effectiveValue))")
            Text("•")
            Text(setting.source.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func agentHookRow(_ agent: SupportedAgent) -> some View {
        let revision = agentHookRevision
        let installationState = AgentHookInstaller().installationState(agent)
        let installed = installationState.isInstalled
        let statusText: String = switch installationState {
        case .missing: "Hooks Not Installed"
        case .updateAvailable: "Hook Update Required"
        case .current: "Hooks Installed"
        }
        HStack {
            Image(systemName: agent.systemImage)
                .frame(width: 20)
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
            Button(installed ? "Update" : "Install") {
                updateAgentHook(agent, remove: false)
            }
            .disabled(agentHookOperation != nil)
            if installed {
                Button("Remove") {
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
                        Button(enabled ? "Disable" : "Enable", action: toggle)
                        Button("Update", action: update)
                        Divider()
                        Button("Uninstall", role: .destructive, action: uninstall)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                } else {
                    Button("Install", action: install)
                }
            }
            Text(manifest.id == SSHPlugin.pluginID
                ? "SSH aliases and remote Files through the system OpenSSH/SFTP client."
                : "OMG plugin")
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
        guard installed else { return "Not Installed" }
        return enabled ? "Enabled" : "Disabled"
    }
}

private struct GhosttyThemeField: View {
    let title: String
    @Binding var value: String
    private let themes = GhosttyThemeCatalog.availableThemes()

    init(title: String, value: Binding<String>) {
        self.title = title
        self._value = value
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("Inherit Ghostty config", text: $value)
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
                    .help("Reset to Ghostty config")
                }
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let tab: OhMyGhosttySettingsTab
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Label(tab.title, systemImage: tab.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(selected ? 0.20 : 0))
                )
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "")
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(settings: .shared)
    }
}
