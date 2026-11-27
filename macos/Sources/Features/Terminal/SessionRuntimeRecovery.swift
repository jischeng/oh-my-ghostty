import AppKit
import GhosttyKit
import SwiftUI

extension TerminalController {
    /// Ask the host-scoped relay to retry transport and reattach this same UUID.
    func retryRuntimeConnection(
        for surface: Ghostty.SurfaceView,
        using retryer: SessionRuntimeRetrying = SessionRuntimeConnections.shared
    ) {
        guard surface.surface != nil, let descriptor = surface.runtimeDescriptor,
              surfaceTree.contains(where: { $0 === surface }),
              surface.runtimeConnectionState?.canRetry != false else { return }
        let attempt = (surface.runtimeConnectionState?.attempt ?? 0) + 1
        let requestedState = SessionRuntimeConnectionState.reconnecting(
            attempt: attempt,
            retryInMilliseconds: nil
        )
        surface.runtimeConnectionState = requestedState
        do {
            try retryer.retry(descriptor) { [weak surface] message in
                guard let surface,
                      surface.runtimeDescriptor == descriptor,
                      surface.runtimeConnectionState == requestedState else { return }
                surface.runtimeConnectionState = .failed(message: message)
            }
        } catch {
            surface.runtimeConnectionState = .failed(message: error.localizedDescription)
        }
    }

    func buildRecreateRequest(
        for surface: Ghostty.SurfaceView,
        paneID: UUID,
        descriptor: SessionRuntimeDescriptor,
        inlineWorkingDirectory: String?,
        isInline: Bool
    ) -> SessionRuntimeRecreateRequest {
        let contextRemoteCwd = paneSessionContext(for: surface)?.remoteWorkingDirectory
        let resolvedCwd: String? = if isInline {
            contextRemoteCwd
                ?? SessionRuntimeDescriptor.validWorkingDirectory(inlineWorkingDirectory)
                ?? SessionRuntimeDescriptor.validWorkingDirectory(descriptor.initialWorkingDirectory)
        } else {
            contextRemoteCwd
                ?? SessionRuntimeDescriptor.validWorkingDirectory(surface.pwd)
                ?? SessionRuntimeDescriptor.validWorkingDirectory(descriptor.initialWorkingDirectory)
        }
        let rawSize: ghostty_surface_size_s? = surface.surfaceSize ?? surface.surface.map { ghostty_surface_size($0) }
        let cols: UInt16? = rawSize.flatMap { $0.columns > 0 ? min($0.columns, 500) : nil }
        let rows: UInt16? = rawSize.flatMap { $0.rows > 0 ? min($0.rows, 300) : nil }
        let pixelWidth: UInt16? = rawSize.flatMap { $0.width_px > 0 ? UInt16(min($0.width_px, 16_000)) : nil }
        let pixelHeight: UInt16? = rawSize.flatMap { $0.height_px > 0 ? UInt16(min($0.height_px, 16_000)) : nil }
        let colors = ghostty.config.terminalColorContext
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activeAgent = agentResumeDescriptor(for: surface) ?? surface.agentResumeDescriptor
        let resume = activeAgent.flatMap { candidate -> SessionRuntimeHandoffResume? in
            guard candidate.scope == .remote else { return nil }
            return SessionRuntimeHandoffResume(from: candidate, fallbackWorkingDirectory: resolvedCwd)
        }
        return SessionRuntimeRecreateRequest(
            id: paneID.uuidString.lowercased(),
            cwd: resolvedCwd,
            cols: cols,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            term: ghostty.config.configuredTerm,
            colorterm: "truecolor",
            termProgram: "ghostty",
            termProgramVersion: bundleVersion?.isEmpty == false ? bundleVersion : nil,
            colorScheme: colors.colorScheme,
            foreground: colors.foreground,
            background: colors.background,
            cursor: colors.cursor,
            resume: resume,
            interactive: true
        )
    }

    /// Explicitly authorize one-shot recreation of a gone remote session in this same pane.
    func recreateRuntimeSession(
        for surface: Ghostty.SurfaceView,
        using retryer: SessionRuntimeRetrying = SessionRuntimeConnections.shared
    ) {
        guard surface.surface != nil,
              surfaceTree.contains(where: { $0 === surface }) else { return }

        if let inline = surface.runtimeInlineSession,
           let inlineState = surface.inlineRuntimeConnectionState,
           inlineState.isSessionGone {
            let request = buildRecreateRequest(
                for: surface,
                paneID: inline.pane,
                descriptor: inline.descriptor,
                inlineWorkingDirectory: inline.workingDirectory,
                isInline: true
            )
            let requestedState = SessionRuntimeConnectionState.reconnecting(
                attempt: 1,
                retryInMilliseconds: nil
            )
            surface.inlineRuntimeConnectionState = requestedState
            let connectionID = inline.connectionID
            do {
                try retryer.recreate(
                    inline.descriptor,
                    socketOverride: inline.socket,
                    request: request
                ) { [weak surface] message in
                    guard let surface,
                          surface.runtimeInlineSession?.connectionID == connectionID,
                          surface.inlineRuntimeConnectionState == requestedState else { return }
                    surface.inlineRuntimeConnectionState = .sessionGone(message: message)
                }
            } catch {
                surface.inlineRuntimeConnectionState = .sessionGone(message: error.localizedDescription)
            }
            return
        }

        guard let descriptor = surface.runtimeDescriptor,
              !descriptor.isLocal,
              let currentState = surface.runtimeConnectionState,
              currentState.isSessionGone else { return }
        let request = buildRecreateRequest(
            for: surface,
            paneID: surface.id,
            descriptor: descriptor,
            inlineWorkingDirectory: nil,
            isInline: false
        )
        let requestedState = SessionRuntimeConnectionState.reconnecting(
            attempt: 1,
            retryInMilliseconds: nil
        )
        surface.runtimeConnectionState = requestedState
        do {
            try retryer.recreate(
                descriptor,
                socketOverride: nil,
                request: request
            ) { [weak surface] message in
                guard let surface,
                      surface.runtimeDescriptor == descriptor,
                      surface.runtimeConnectionState == requestedState else { return }
                surface.runtimeConnectionState = .sessionGone(message: message)
            }
        } catch {
            surface.runtimeConnectionState = .sessionGone(message: error.localizedDescription)
        }
    }
}

struct SessionRuntimeRecoveryBanner: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var settings = OhMyGhosttySettings.shared
    @ObservedObject var surface: Ghostty.SurfaceView
    @StateObject private var presentation = SessionRuntimeRecoveryPresentation()

    private struct BannerBinding: Equatable {
        let endpoint: String
        let state: SessionRuntimeConnectionState?
        let isInline: Bool
    }

    private var activeBinding: BannerBinding? {
        if let descriptor = surface.runtimeDescriptor,
           let state = surface.runtimeConnectionState,
           state != .ready {
            if case .exited = state {} else {
                return BannerBinding(endpoint: descriptor.displayEndpoint, state: state, isInline: false)
            }
        }
        if let inline = surface.runtimeInlineSession,
           let inlineState = surface.inlineRuntimeConnectionState {
            return BannerBinding(endpoint: inline.descriptor.displayEndpoint, state: inlineState, isInline: true)
        }
        if let descriptor = surface.runtimeDescriptor {
            return BannerBinding(endpoint: descriptor.displayEndpoint, state: surface.runtimeConnectionState, isInline: false)
        }
        return nil
    }

    var body: some View {
        let binding = activeBinding
        Group {
            if surface.surface != nil, let binding, let state = presentation.state {
                NativeSessionRuntimeRecoveryBanner(
                    endpoint: binding.endpoint,
                    state: state,
                    strings: SettingsStrings(language: settings.language)
                ) { [weak controller, weak surface] in
                    guard let controller, let surface,
                          controller.surfaceTree.contains(where: { $0 === surface }) else { return }
                    if state.isSessionGone {
                        controller.recreateRuntimeSession(for: surface)
                    } else if !binding.isInline {
                        controller.retryRuntimeConnection(for: surface)
                    }
                }
                .frame(maxWidth: 360)
                .padding(8)
            }
        }
        .allowsHitTesting(presentation.state != nil)
        .onAppear { presentation.update(binding?.state) }
        .onChange(of: surface.runtimeConnectionState) { _ in presentation.update(activeBinding?.state) }
        .onChange(of: surface.inlineRuntimeConnectionState) { _ in presentation.update(activeBinding?.state) }
        .onDisappear { presentation.update(nil) }
    }
}

@MainActor
final class SessionRuntimeRecoveryPresentation: ObservableObject {
    @Published private(set) var state: SessionRuntimeConnectionState?
    private var latest: SessionRuntimeConnectionState?
    private var pending: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.4) { self.delay = delay }

    func update(_ next: SessionRuntimeConnectionState?) {
        latest = next
        switch next {
        case nil, .ready, .exited:
            pending?.cancel()
            pending = nil
            state = nil
        case .connecting, .reconnecting:
            if state != nil { state = next; return }
            guard pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.state = self.latest
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .attention, .failed, .sessionGone:
            pending?.cancel()
            pending = nil
            state = next
        }
    }

    deinit { pending?.cancel() }
}

private struct NativeSessionRuntimeRecoveryBanner: NSViewRepresentable {
    let endpoint: String
    let state: SessionRuntimeConnectionState
    let strings: SettingsStrings
    let retry: () -> Void

    func makeNSView(context: Context) -> SessionRuntimeRecoveryView {
        SessionRuntimeRecoveryView()
    }

    func updateNSView(_ view: SessionRuntimeRecoveryView, context: Context) {
        view.update(endpoint: endpoint, state: state, strings: strings, retry: retry)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SessionRuntimeRecoveryView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: nsView.height(for: width))
    }
}

/// Native status and retry controls stay attached to the session's pane.
final class SessionRuntimeRecoveryView: NSVisualEffectView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let reconnectButton = NSButton(title: "", target: nil, action: nil)
    private let icon = NSImageView()
    private var retry: (() -> Void)?
    private var showsDetail = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setAccessibilityIdentifier("sessionRuntimeRecoveryBanner")
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        icon.contentTintColor = .secondaryLabelColor
        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(performRetry)
        reconnectButton.setAccessibilityIdentifier("sessionRuntimeReconnect")
        // No Return key equivalent: this passive banner must not intercept terminal input.
        for child in [icon, titleLabel, detailLabel, reconnectButton] {
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(endpoint: String, state: SessionRuntimeConnectionState,
                strings: SettingsStrings, retry: @escaping () -> Void) {
        titleLabel.stringValue = strings.runtimeStatusTitle(state) + " · " + endpoint
        titleLabel.toolTip = endpoint
        detailLabel.stringValue = strings.runtimeStatusDetail(state)
        if case .sessionGone(let diagnostic) = state, let diagnostic, !diagnostic.isEmpty {
            detailLabel.toolTip = detailLabel.stringValue + "\n" + diagnostic
        } else {
            detailLabel.toolTip = detailLabel.stringValue
        }
        showsDetail = !state.isInProgress
        detailLabel.isHidden = !showsDetail
        reconnectButton.title = state.isSessionGone ? strings.runtimeRecreateSession : strings.runtimeRetryNow
        reconnectButton.toolTip = state.isSessionGone ? strings.runtimeRecreateHelp : strings.runtimeRetryHelp
        reconnectButton.isHidden = !state.canRetry
        icon.image = NSImage(
            systemSymbolName: state.isInProgress ? "arrow.triangle.2.circlepath" : "network.slash",
            accessibilityDescription: nil
        )
        self.retry = retry
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        32 + (showsDetail ? 4 + detailHeight(for: width) : 0)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width))
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 46)
        icon.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
        let titleHeight = titleLabel.intrinsicContentSize.height
        let buttonSize = reconnectButton.intrinsicContentSize
        let buttonWidth = reconnectButton.isHidden ? 0 : min(width, buttonSize.width)
        titleLabel.frame = NSRect(x: 36, y: (32 - titleHeight) / 2,
                                 width: max(0, width - buttonWidth - (buttonWidth > 0 ? 8 : 0)), height: titleHeight)
        let textHeight = detailHeight(for: bounds.width)
        detailLabel.frame = NSRect(x: 36, y: 32, width: width, height: textHeight)
        reconnectButton.frame = NSRect(
            x: bounds.width - buttonWidth - 10,
            y: (32 - buttonSize.height) / 2,
            width: buttonWidth,
            height: buttonSize.height
        )
    }

    private func detailHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 46)
        return min(32, ceil((detailLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: detailLabel.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        ).height))
    }

    @objc private func performRetry() {
        retry?()
    }
}

private extension SessionRuntimeConnectionState {
    var isInProgress: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .attention, .sessionGone, .ready, .failed, .exited: false
        }
    }
}

private extension SettingsStrings {
    func runtimeStatusTitle(_ state: SessionRuntimeConnectionState) -> String {
        switch state {
        case .connecting: t("Connecting", "正在连接")
        case .reconnecting: t("Reconnecting", "正在重连")
        case .attention: t("Connection needs attention", "连接需要处理")
        case .sessionGone: t("Remote session no longer exists", "远端会话已不存在")
        case .ready: t("Connected", "已连接")
        case .failed: t("Session connection failed", "会话连接失败")
        case .exited: t("Session ended", "会话已结束")
        }
    }

    func runtimeStatusDetail(_ state: SessionRuntimeConnectionState) -> String {
        switch state {
        case .connecting:
            return t("Starting the session runtime.", "正在启动会话运行时。")
        case .reconnecting(let attempt, let retryInMilliseconds):
            let attemptText = t("Attempt \(attempt)", "第 \(attempt) 次尝试")
            guard let retryInMilliseconds else { return attemptText }
            let seconds = max(1, (retryInMilliseconds + 999) / 1_000)
            return attemptText + " · " + t("retry in \(seconds)s", "\(seconds) 秒后重试")
        case .attention(let attempt, let message):
            let fallback = t("Automatic retries stopped. Retry when the host is reachable.", "自动重试已暂停；主机恢复后可手动重试。")
            let reason = message?.isEmpty == false ? message! : fallback
            return attempt > 0 ? t("Attempt \(attempt) · \(reason)", "第 \(attempt) 次尝试 · \(reason)") : reason
        case .sessionGone:
            return t(
                "The remote host or container may have restarted. Recreate the session in this pane.",
                "远端主机或容器可能已重启，可在当前面板重建会话。"
            )
        case .ready:
            return t("The original session is attached.", "已连接到原会话。")
        case .failed(let message, _):
            return message?.isEmpty == false ? message! : t("The session could not be attached.", "无法连接到原会话。")
        case .exited(let exitCode):
            return t("The session process exited with code \(exitCode).", "会话进程以退出码 \(exitCode) 结束。")
        }
    }
}
