import AppKit
import SwiftUI

// MARK: - Working directory

/// Where the pane's shell currently is, as the Info pane presents it.
struct InfoWorkingDirectory: Equatable, Sendable {
    let path: String
    /// SSH alias for a remote directory; nil for a directory on this Mac.
    let host: String?

    var isRemote: Bool { host != nil }

    var displayPath: String {
        isRemote ? path : (path as NSString).abbreviatingWithTildeInPath
    }

    enum Action: Equatable {
        case copyPath
        case revealInFinder
        case open(InfoExternalApp)
    }

    /// Finder and local editors cannot reach a directory on an SSH host.
    func actions(apps: [InfoExternalApp]) -> [Action] {
        isRemote ? [.copyPath] : [.copyPath, .revealInFinder] + apps.map(Action.open)
    }

    static func resolve(_ context: InspectorPaneContext) -> Self? {
        switch context.session.state {
        case .local:
            guard let path = context.session.workingDirectory ?? context.workingDirectory,
                  path.hasPrefix("/") else { return nil }
            return .init(path: path, host: nil)
        case .sshConnecting:
            // The local directory no longer describes this pane, and the
            // remote one is not known yet.
            return nil
        case .sshReady(let ssh, let workingDirectory):
            guard !workingDirectory.isEmpty else { return nil }
            return .init(path: workingDirectory, host: ssh.alias)
        }
    }
}

/// An installed application that can open a folder.
struct InfoExternalApp: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL

    /// Editors offered for the working directory, in display order.
    static let candidateBundleIDs = [
        "dev.zed.Zed",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.apple.dt.Xcode",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.rustrover",
        "com.jetbrains.CLion",
        "com.google.android.studio",
        "com.sublimetext.4",
        "com.panic.Nova",
    ]
    static let displayLimit = 4

    static func installed(
        limit: Int = displayLimit,
        locate: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> [Self] {
        var apps: [Self] = []
        for bundleID in candidateBundleIDs where apps.count < limit {
            guard let url = locate(bundleID) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard !apps.contains(where: { $0.name == name }) else { continue }
            apps.append(.init(id: bundleID, name: name, url: url))
        }
        return apps
    }
}

/// Side effects of the working-directory rows, injectable for tests.
struct InfoDirectoryActions {
    var copy: @MainActor (String) -> Void = { CopyFeedback.copy($0) }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var open: @MainActor (URL, InfoExternalApp) -> Void = { url, app in
        NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: .init())
    }
    var installedApps: @MainActor () -> [InfoExternalApp] = { InfoExternalApp.installed() }
}

// MARK: - Layout

enum InfoLayout {
    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 28
    static let detailHeight: CGFloat = 16
    /// Hover highlights stop short of the pane edges, as in the file tree.
    static let rowOuterInset = InspectorContentMetrics.treeOuterInset
    static let rowInnerInset = InspectorContentMetrics.leadingInset - rowOuterInset
    static let rowCornerRadius: CGFloat = 5
    static let sectionBottomInset: CGFloat = 6
}

enum InfoHistoryLayout {
    static func portHeight(count: Int, detailCount: Int = 0) -> CGFloat {
        guard count > 0 else { return 64 }
        let rows = CGFloat(count) * InfoLayout.rowHeight + CGFloat(detailCount) * InfoLayout.detailHeight
        return min(180, InfoLayout.headerHeight + rows + InfoLayout.sectionBottomInset + 2)
    }

    /// The remote-target column hugs its widest value so short ports do not
    /// leave a gap before the forwarded address.
    static func targetColumnWidth(_ targets: [String]) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let widest = targets
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        return min(120, max(36, widest + 2))
    }
}

// MARK: - Shared pieces

private struct InfoSectionHeader<Accessory: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let count, count > 0 {
                Text(String(count))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.leading, InspectorContentMetrics.leadingInset)
        .padding(.trailing, InfoLayout.rowOuterInset + 2)
        .frame(height: InfoLayout.headerHeight)
    }
}

extension InfoSectionHeader where Accessory == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

private struct InfoSectionDivider: View {
    let color: Color

    var body: some View {
        Rectangle().fill(color).frame(height: TerminalShellStyle.dividerWidth)
    }
}

/// Full-width row background that lights up under the pointer.
private struct InfoRowBackground: ViewModifier {
    let hovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, InfoLayout.rowInnerInset)
            .frame(maxWidth: .infinity, minHeight: InfoLayout.rowHeight, alignment: .leading)
            .background(
                hovered ? Color.primary.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: InfoLayout.rowCornerRadius)
            )
            .padding(.horizontal, InfoLayout.rowOuterInset)
            .contentShape(Rectangle())
    }
}

private struct InfoActionRow: View {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    let icon: Icon
    let title: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    switch icon {
                    case .symbol(let name):
                        Image(systemName: name)
                            .font(.system(size: 12))
                            .foregroundStyle(tint)
                    case .image(let image):
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                    }
                }
                .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .modifier(InfoRowBackground(hovered: hovered))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct InspectorHoverIconButton: View {
    let systemImage: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16, height: 16)
                .padding(3)
                .background(
                    hovered && enabled ? Color.primary.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .onHover { inside in
            hovered = inside
            if enabled {
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .onDisappear {
            if hovered { NSCursor.arrow.set() }
        }
        .help(help)
    }
}

// MARK: - Info pane

struct InspectorInfoView: View {
    let info: InspectorInfoContent
    var directory: InfoWorkingDirectory?
    var directoryActions = InfoDirectoryActions()
    let dividerColor: Color
    let perform: (InspectorPaneActionKind) -> Void

    init(
        info: InspectorInfoContent,
        directory: InfoWorkingDirectory? = nil,
        directoryActions: InfoDirectoryActions = .init(),
        dividerColor: Color,
        perform: @escaping (InspectorPaneActionKind) -> Void
    ) {
        self.info = info
        self.directory = directory
        self.directoryActions = directoryActions
        self.dividerColor = dividerColor
        self.perform = perform
    }

    var body: some View {
        VStack(spacing: 0) {
            if info.status != nil || !info.fields.isEmpty {
                if let status = info.status {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.green)
                        Text(status.label)
                        Spacer()
                        Text(status.value)
                            .foregroundStyle(.secondary)
                    }
                    .padding(InspectorContentMetrics.leadingInset)
                }

                if !info.fields.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(info.fields) { field in
                            GridRow {
                                Text(field.label)
                                    .foregroundStyle(.secondary)
                                Text(field.value)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(InspectorContentMetrics.leadingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                InfoSectionDivider(color: dividerColor)
            }

            if let directory {
                InspectorWorkingDirectoryView(directory: directory, actions: directoryActions)
                InfoSectionDivider(color: dividerColor)
            }

            if !info.portForwards.hostAlias.isEmpty {
                InspectorPortForwardListView(forwards: info.portForwards, perform: perform)
                    .frame(height: InfoHistoryLayout.portHeight(
                        count: info.portForwards.items.count,
                        detailCount: info.portForwards.items.count(where: InspectorPortForwardListView.hasDetail)
                    ))
                InfoSectionDivider(color: dividerColor)
            }

            InspectorTerminalHistoryListView(
                items: info.historyItems.filter { $0.kind == .command },
                isAgent: false,
                agentName: nil,
                state: .ready,
                perform: perform
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct InspectorWorkingDirectoryView: View {
    let directory: InfoWorkingDirectory
    let actions: InfoDirectoryActions
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var apps: [InfoExternalApp] = []
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    private var strings: InfoStrings { .init(language: settings.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InfoSectionHeader(title: strings.workingDirectoryTitle) {
                if let host = directory.host {
                    Label(host, systemImage: "network")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, InspectorContentMetrics.leadingInset - InfoLayout.rowOuterInset - 2)
                }
            }

            Text(directory.displayPath)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .help(directory.path)
                .padding(.horizontal, InspectorContentMetrics.leadingInset)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            let rows = directory.actions(apps: apps)
            ForEach(rows.indices, id: \.self) { index in
                switch rows[index] {
                case .copyPath:
                    InfoActionRow(
                        icon: .symbol(copied ? "checkmark" : "doc.on.doc"),
                        title: copied ? CopyFeedback.confirmationText() : strings.copyPath,
                        tint: copied ? .green : .secondary
                    ) {
                        actions.copy(directory.path)
                        flashCopied()
                    }
                case .revealInFinder:
                    InfoActionRow(icon: .symbol("folder"), title: strings.revealInFinder) {
                        withLocalDirectory(actions.reveal)
                    }
                case .open(let app):
                    InfoActionRow(
                        icon: .image(NSWorkspace.shared.icon(forFile: app.url.path)),
                        title: strings.openIn(app.name)
                    ) {
                        withLocalDirectory { actions.open($0, app) }
                    }
                }
            }
        }
        .padding(.bottom, InfoLayout.sectionBottomInset)
        .onAppear { apps = actions.installedApps() }
        .onDisappear { copyReset?.cancel() }
    }

    /// The shell may have removed its own directory since it was reported.
    @MainActor private func withLocalDirectory(_ body: @MainActor (URL) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        body(URL(fileURLWithPath: directory.path, isDirectory: true))
    }

    private func flashCopied() {
        copyReset?.cancel()
        copied = true
        copyReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(CopyFeedback.duration))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

private struct InspectorTerminalHistoryListView: View {
    let items: [InspectorHistoryItem]
    let isAgent: Bool
    let agentName: String?
    let state: PaneAgentHistoryService.State
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared

    private var strings: InfoStrings { .init(language: settings.language) }
    private var statusMessage: String? {
        switch state {
        case .loading: strings.historyLoading
        case .unavailable: strings.historyUnavailable
        case .limited: strings.historyLimited
        case .ready: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InfoSectionHeader(
                title: isAgent ? (agentName ?? strings.agentPromptsTitle) : strings.historyTitle,
                count: items.count
            )

            if isAgent && !items.isEmpty {
                note(strings.noTerminalAnchor)
            }
            if let statusMessage {
                note(statusMessage)
            }
            if items.isEmpty {
                if state == .ready {
                    note(isAgent ? strings.noAgentPromptsMessage : strings.noHistoryMessage)
                }
                Spacer(minLength: 0)
            } else {
                TerminalHistoryTable(items: items) { perform(.jumpToHistoryItem($0)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.bottom, 6)
    }
}

private struct InspectorPortForwardListView: View {
    private static let actionsWidth: CGFloat = 70

    let forwards: InspectorPortForwardList
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var isAdding = false
    @State private var targetValue = ""
    @State private var hoveredID: String?

    private var strings: InfoStrings {
        .init(language: settings.language)
    }

    /// Whether a row carries a second line (progress, process or failure).
    static func hasDetail(_ item: InspectorPortForwardItem) -> Bool {
        switch item.status {
        case .starting, .failed: true
        case .active: item.processName != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            InfoSectionHeader(title: strings.portsTitle, count: forwardedCount) {
                InspectorHoverIconButton(
                    systemImage: "plus",
                    help: forwards.canCreate
                        ? strings.forwardAPort
                        : strings.waitingForHost(forwards.hostAlias),
                    enabled: forwards.canCreate
                ) {
                    targetValue = ""
                    isAdding = true
                }
                .accessibilityLabel(strings.forwardAPort)
            }
            .help(forwards.hostAlias)

            if forwards.items.isEmpty {
                Text(strings.noForwardedPorts)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, InspectorContentMetrics.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                let targetWidth = InfoHistoryLayout.targetColumnWidth(forwards.items.map(remoteTarget))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(forwards.items) { item in
                            portRow(item, targetWidth: targetWidth)
                        }
                    }
                    .padding(.bottom, InfoLayout.sectionBottomInset)
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            VStack(alignment: .leading, spacing: 16) {
                Text(strings.forwardAPort)
                    .font(.headline)
                Text(strings.targetHelp(alias: forwards.hostAlias))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(strings.targetPlaceholder, text: $targetValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addForward)
                HStack {
                    Spacer()
                    Button(strings.cancel) { isAdding = false }
                    Button(strings.forward) { addForward() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsedTarget == nil)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private func portRow(_ item: InspectorPortForwardItem, targetWidth: CGFloat) -> some View {
        let hovered = hoveredID == item.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(item.status))
                    .frame(width: 7, height: 7)
                    .frame(width: 8)
                Text(remoteTarget(item))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: targetWidth, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(strings.remoteTargetColumn)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(localAddress(item))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(strings.forwardedAddressColumn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Actions take the address's trailing room only while
                    // they are visible, so narrow panes keep the full value.
                    .padding(.trailing, hovered ? Self.actionsWidth : 0)
            }
            .frame(height: InfoLayout.rowHeight - 2)

            if let detail = detailTitle(item) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor(item.status))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
                    .padding(.leading, 16)
                    .frame(height: InfoLayout.detailHeight - 2, alignment: .top)
            }
        }
        .padding(.vertical, 1)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 1) {
                InspectorHoverIconButton(
                    systemImage: "safari",
                    help: strings.openInBrowser,
                    enabled: item.status == .active
                ) {
                    perform(.openPortForward(id: item.id))
                }
                InspectorHoverIconButton(
                    systemImage: "doc.on.doc",
                    help: strings.copyForwardedAddress,
                    enabled: item.status == .active
                ) {
                    perform(.copyPortForward(id: item.id))
                }
                InspectorHoverIconButton(
                    systemImage: "xmark",
                    help: strings.stopForwarding
                ) {
                    perform(.removePortForward(id: item.id))
                }
            }
            .frame(height: InfoLayout.rowHeight)
            .padding(.trailing, -4)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
        .modifier(InfoRowBackground(hovered: hovered))
        .onHover { inside in
            hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.remotePortAccessibility(
            item.remotePort,
            detail: detailTitle(item) ?? localAddress(item)
        ))
    }

    private var forwardedCount: Int {
        forwards.items.count { $0.status == .active }
    }

    private var parsedTarget: PortForwardTarget? {
        PortForwardTarget.parse(targetValue)
    }

    private func addForward() {
        guard parsedTarget != nil else { return }
        perform(.createPortForward(target: targetValue))
        isAdding = false
    }

    private func remoteTarget(_ item: InspectorPortForwardItem) -> String {
        PortForwardTarget(
            host: item.remoteHost,
            port: item.remotePort
        ).displayValue
    }

    private func localAddress(_ item: InspectorPortForwardItem) -> String {
        item.localPort.map { "localhost:\($0)" } ?? "—"
    }

    private func detailTitle(_ item: InspectorPortForwardItem) -> String? {
        switch item.status {
        case .starting: strings.startingForward
        case .active: item.processName
        case .failed(let message): message
        }
    }

    private func statusColor(_ status: InspectorPortForwardStatus) -> Color {
        switch status {
        case .starting: .secondary
        case .active: .green
        case .failed: .red
        }
    }

    private func detailColor(_ status: InspectorPortForwardStatus) -> Color {
        if case .failed = status { return .red }
        return .secondary
    }
}
