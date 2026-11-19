import AppKit
import Foundation
import SwiftUI

struct SessionRuntimeRestoreNormalization: Equatable, Sendable {
    let descriptor: SessionRuntimeDescriptor
    /// Non-nil when a restored remote SSH descriptor had a previous revision
    /// whose snapshot-revision is incompatible with (or unavailable for) the
    /// current app bundle, so the previous revision's remote `omgd` may still
    /// hold a live PTY and Agent conversation lock.
    let handoffSourceDescriptor: SessionRuntimeDescriptor?
}

struct SessionRuntimeHandoffResume: Codable, Equatable, Sendable {
    let agent: String
    let conversationID: String
    let cwd: String

    enum CodingKeys: String, CodingKey {
        case agent, cwd
        case conversationID = "conversation_id"
    }

    init(agent: String, conversationID: String, cwd: String) {
        self.agent = agent
        self.conversationID = conversationID
        self.cwd = cwd
    }

    init?(from catalogResume: SessionRuntimeCatalogSession.Resume) {
        guard !catalogResume.agent.isEmpty,
              !catalogResume.conversationID.isEmpty,
              let validCwd = SessionRuntimeDescriptor.validWorkingDirectory(catalogResume.cwd) else {
            return nil
        }
        agent = catalogResume.agent
        conversationID = catalogResume.conversationID
        cwd = validCwd
    }

    init?(from agentResume: AgentResumeDescriptor, fallbackWorkingDirectory: String?) {
        guard agentResume.isValid,
              let conversationID = agentResume.conversationID?.rawValue,
              !conversationID.isEmpty,
              !agentResume.agent.definition.resume.resumeArguments.isEmpty,
              let validCwd = SessionRuntimeDescriptor.validWorkingDirectory(
                  agentResume.workingDirectory ?? fallbackWorkingDirectory
              ) else {
            return nil
        }
        agent = agentResume.agent.rawValue
        self.conversationID = conversationID
        cwd = validCwd
    }

    var agentDisplayName: String {
        SupportedAgent(rawValue: agent)?.displayName ?? agent.capitalized
    }

    var shortConversationID: String {
        conversationID.count <= 14 ? conversationID : String(conversationID.prefix(12)) + "…"
    }

    func agentResumeDescriptor(for connection: GitSSHConnection?) -> AgentResumeDescriptor? {
        guard let supported = SupportedAgent(rawValue: agent),
              let validID = AgentConversationID(conversationID) else {
            return nil
        }
        let replay = connection.map {
            SSHReplayDescriptor(
                version: 1,
                ssh: $0.executablePath,
                forwardEnv: true,
                terminfo: true,
                cache: true,
                args: $0.options + [$0.destination],
                localWorkingDirectory: $0.localWorkingDirectory
            )
        }
        return AgentResumeDescriptor(
            agent: supported,
            conversationID: validID,
            scope: .remote,
            workingDirectory: cwd,
            sshReplay: replay
        )
    }
}

struct SessionRuntimeRevisionHandoffContext: Equatable, Sendable {
    let paneID: UUID
    let sourceDescriptor: SessionRuntimeDescriptor
    let targetDescriptor: SessionRuntimeDescriptor
    let savedWorkingDirectory: String?
    let savedAgentResume: AgentResumeDescriptor?

    var shortSourceRevision: String {
        let rev = sourceDescriptor.revision
        return rev.count <= 12 ? rev : String(rev.prefix(12))
    }

    func fallbackResume(preferredWorkingDirectory: String? = nil) -> SessionRuntimeHandoffResume? {
        guard let savedAgentResume else { return nil }
        return SessionRuntimeHandoffResume(
            from: savedAgentResume,
            fallbackWorkingDirectory: preferredWorkingDirectory ?? savedWorkingDirectory
        )
    }
}

enum SessionRuntimeRevisionHandoffProbeResult: Equatable, Sendable {
    case gone
    case exited(ended: String?, cwd: String?, resume: SessionRuntimeHandoffResume?)
    case alive(pid: Int?, cwd: String?, resume: SessionRuntimeHandoffResume?)

    static func decode(_ data: Data) throws -> Self {
        struct Payload: Decodable {
            let status: String
            let pid: Int?
            let ended: String?
            let cwd: String?
            let resume: SessionRuntimeCatalogSession.Resume?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let validCwd = SessionRuntimeDescriptor.validWorkingDirectory(payload.cwd)
        let validResume = payload.resume.flatMap(SessionRuntimeHandoffResume.init(from:))
        switch payload.status {
        case "gone":
            return .gone
        case "exited":
            return .exited(ended: payload.ended, cwd: validCwd, resume: validResume)
        case "alive":
            return .alive(pid: payload.pid, cwd: validCwd, resume: validResume)
        default:
            throw NSError(
                domain: "OMGSessionRuntimeHandoff",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected handoff probe status: \(payload.status)"]
            )
        }
    }
}

enum SessionRuntimeRevisionHandoffState: Equatable, Sendable {
    case probing
    case awaitingUser(
        isConfirmedAlive: Bool,
        pid: Int?,
        cwd: String?,
        resume: SessionRuntimeHandoffResume?,
        probeError: String?
    )
    case handingOff(cwd: String?, resume: SessionRuntimeHandoffResume?)
    case closeFailed(
        message: String,
        cwd: String?,
        resume: SessionRuntimeHandoffResume?
    )

    var effectiveWorkingDirectory: String? {
        switch self {
        case .probing: nil
        case .awaitingUser(_, _, let cwd, let resume, _): cwd ?? resume?.cwd
        case .handingOff(let cwd, let resume): cwd ?? resume?.cwd
        case .closeFailed(_, let cwd, let resume): cwd ?? resume?.cwd
        }
    }

    var effectiveResume: SessionRuntimeHandoffResume? {
        switch self {
        case .probing: nil
        case .awaitingUser(_, _, _, let resume, _): resume
        case .handingOff(_, let resume): resume
        case .closeFailed(_, _, let resume): resume
        }
    }
}

struct SessionRuntimeRevisionHandoffLaunchPlan: Equatable, Sendable {
    let paneID: UUID
    let descriptor: SessionRuntimeDescriptor
    let workingDirectory: String?
    let resume: SessionRuntimeHandoffResume?

    func configure(_ config: inout Ghostty.SurfaceConfiguration) throws {
        var effectiveDescriptor = descriptor
        if let validCwd = SessionRuntimeDescriptor.validWorkingDirectory(workingDirectory ?? resume?.cwd) {
            effectiveDescriptor.initialWorkingDirectory = validCwd
        }
        try effectiveDescriptor.configureSavedRestore(&config, createRuntime: true, recreateIfGone: false)
        if let resume {
            let encoded = try JSONEncoder().encode(resume)
            config.environmentVariables[SessionRuntimeDescriptor.handoffResumeEnvironmentKey] =
                String(data: encoded, encoding: .utf8)
        } else {
            config.environmentVariables.removeValue(
                forKey: SessionRuntimeDescriptor.handoffResumeEnvironmentKey
            )
        }
    }
}

protocol SessionRuntimeRevisionHandoffTransport: Sendable {
    func probe(
        sourceDescriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        interactive: Bool
    ) async throws -> SessionRuntimeRevisionHandoffProbeResult

    func closeSession(
        sourceDescriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        interactive: Bool,
        timeoutSeconds: Int
    ) async throws
}

final class OMGDRevisionHandoffTransport: SessionRuntimeRevisionHandoffTransport {
    static let shared = OMGDRevisionHandoffTransport()

    func probe(
        sourceDescriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        interactive: Bool
    ) async throws -> SessionRuntimeRevisionHandoffProbeResult {
        var args = ["handoff-probe", "{config}", paneID.uuidString.lowercased()]
        if interactive { args.append("--interactive") }
        let result = try await runOMGD(
            sourceDescriptor: sourceDescriptor,
            interactive: interactive,
            argumentsTemplate: args,
            timeout: 35
        )
        return try SessionRuntimeRevisionHandoffProbeResult.decode(result.stdout)
    }

    func closeSession(
        sourceDescriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        interactive: Bool,
        timeoutSeconds: Int = 15
    ) async throws {
        let clampedTimeout = max(1, min(timeoutSeconds, 60))
        var args = [
            "handoff-close",
            "{config}",
            paneID.uuidString.lowercased(),
            "--timeout-secs",
            String(clampedTimeout),
        ]
        if interactive { args.append("--interactive") }
        _ = try await runOMGD(
            sourceDescriptor: sourceDescriptor,
            interactive: interactive,
            argumentsTemplate: args,
            timeout: TimeInterval(clampedTimeout + 25)
        )
    }

    private func runOMGD(
        sourceDescriptor: SessionRuntimeDescriptor,
        interactive: Bool,
        argumentsTemplate: [String],
        timeout: TimeInterval
    ) async throws -> GitExecutionResult {
        let data = try SessionRuntimeConnections.handoffConnectionConfiguration(
            sourceDescriptor,
            interactive: interactive
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-revision-handoff-\(UUID().uuidString)", isDirectory: true)
        try SessionRuntimeBridgeStorage.ensurePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("connection.json")
        try SessionRuntimeBridgeStorage.writePrivateFile(at: configURL, data: data, permissions: 0o600)

        let helper = SessionRuntimeConnections.resources.appendingPathComponent("omgd")
        var environment = SessionRuntimeHostLauncher.applyingHostBundleEnvironment(
            ProcessInfo.processInfo.environment
        )
        environment["OMG_APP_SUPPORT"] = OMGApplicationEnvironment.applicationSupportURL().path
        environment["SSH_ASKPASS"] = SessionRuntimeConnections.resources
            .appendingPathComponent("askpass").path
        environment["SSH_ASKPASS_REQUIRE"] = interactive ? "force" : "never"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "omg:0"

        let arguments = argumentsTemplate.map { $0 == "{config}" ? configURL.path : $0 }
        let result = try await GitProcessRunner().run(
            executablePath: helper.path,
            arguments: arguments,
            workingDirectory: sourceDescriptor.launchWorkingDirectory,
            environment: environment,
            maxOutputBytes: 262_144,
            timeout: timeout
        )
        guard result.isSuccess else {
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty
                ? "The session runtime helper exited with code \(result.exitCode)."
                : stderr
            throw NSError(
                domain: "OMGSessionRuntimeHandoff",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return result
    }
}

/// Pure, testable coordinator for one pane's cross-snapshot-revision handoff.
@MainActor
final class SessionRuntimeRevisionHandoffCoordinator {
    enum Resolution: Equatable, Sendable {
        case stay(SessionRuntimeRevisionHandoffState)
        case launch(SessionRuntimeRevisionHandoffLaunchPlan)
    }

    let context: SessionRuntimeRevisionHandoffContext
    private(set) var state: SessionRuntimeRevisionHandoffState = .probing

    init(context: SessionRuntimeRevisionHandoffContext) {
        self.context = context
    }

    func runProbe(
        interactive: Bool,
        transport: SessionRuntimeRevisionHandoffTransport
    ) async -> Resolution {
        state = .probing
        do {
            let result = try await transport.probe(
                sourceDescriptor: context.sourceDescriptor,
                paneID: context.paneID,
                interactive: interactive
            )
            switch result {
            case .gone:
                let fallbackResume = context.fallbackResume()
                let plan = SessionRuntimeRevisionHandoffLaunchPlan(
                    paneID: context.paneID,
                    descriptor: context.targetDescriptor,
                    workingDirectory: fallbackResume?.cwd ?? context.savedWorkingDirectory,
                    resume: fallbackResume
                )
                return .launch(plan)
            case .exited(_, let cwd, let remoteResume):
                let effectiveResume = remoteResume ?? context.fallbackResume(preferredWorkingDirectory: cwd)
                let effectiveCwd = cwd ?? effectiveResume?.cwd ?? context.savedWorkingDirectory
                let plan = SessionRuntimeRevisionHandoffLaunchPlan(
                    paneID: context.paneID,
                    descriptor: context.targetDescriptor,
                    workingDirectory: effectiveCwd,
                    resume: effectiveResume
                )
                return .launch(plan)
            case .alive(let pid, let cwd, let remoteResume):
                let effectiveResume = remoteResume ?? context.fallbackResume(preferredWorkingDirectory: cwd)
                let effectiveCwd = cwd ?? effectiveResume?.cwd ?? context.savedWorkingDirectory
                let nextState = SessionRuntimeRevisionHandoffState.awaitingUser(
                    isConfirmedAlive: true,
                    pid: pid,
                    cwd: effectiveCwd,
                    resume: effectiveResume,
                    probeError: nil
                )
                state = nextState
                return .stay(nextState)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .stay(state)
            }
            let fallbackResume = context.fallbackResume()
            let nextState = SessionRuntimeRevisionHandoffState.awaitingUser(
                isConfirmedAlive: false,
                pid: nil,
                cwd: fallbackResume?.cwd ?? context.savedWorkingDirectory,
                resume: fallbackResume,
                probeError: error.localizedDescription
            )
            state = nextState
            return .stay(nextState)
        }
    }

    func performGracefulHandoff(
        transport: SessionRuntimeRevisionHandoffTransport,
        timeoutSeconds: Int = 15
    ) async -> Resolution {
        let cwd = state.effectiveWorkingDirectory ?? context.savedWorkingDirectory
        let resume = state.effectiveResume ?? context.fallbackResume(preferredWorkingDirectory: cwd)
        state = .handingOff(cwd: cwd, resume: resume)
        do {
            try await transport.closeSession(
                sourceDescriptor: context.sourceDescriptor,
                paneID: context.paneID,
                interactive: true,
                timeoutSeconds: timeoutSeconds
            )
            let plan = SessionRuntimeRevisionHandoffLaunchPlan(
                paneID: context.paneID,
                descriptor: context.targetDescriptor,
                workingDirectory: cwd ?? resume?.cwd,
                resume: resume
            )
            return .launch(plan)
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .stay(state)
            }
            let failedState = SessionRuntimeRevisionHandoffState.closeFailed(
                message: error.localizedDescription,
                cwd: cwd,
                resume: resume
            )
            state = failedState
            return .stay(failedState)
        }
    }

    func freshShellPlan(newPaneID: UUID = UUID()) -> SessionRuntimeRevisionHandoffLaunchPlan {
        SessionRuntimeRevisionHandoffLaunchPlan(
            paneID: newPaneID,
            descriptor: context.targetDescriptor,
            workingDirectory: state.effectiveWorkingDirectory ?? context.savedWorkingDirectory,
            resume: nil
        )
    }
}

@MainActor
private enum SessionRuntimeRevisionHandoffTasks {
    private static var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private static var coordinators: [UUID: SessionRuntimeRevisionHandoffCoordinator] = [:]

    static func coordinator(
        for context: SessionRuntimeRevisionHandoffContext
    ) -> SessionRuntimeRevisionHandoffCoordinator {
        if let existing = coordinators[context.paneID], existing.context == context {
            return existing
        }
        let coordinator = SessionRuntimeRevisionHandoffCoordinator(context: context)
        coordinators[context.paneID] = coordinator
        return coordinator
    }

    static func setTask(_ task: Task<Void, Never>, token: UUID, for paneID: UUID) {
        tasks[paneID]?.task.cancel()
        tasks[paneID] = (token: token, task: task)
    }

    static func finishTask(token: UUID, for paneID: UUID) {
        if tasks[paneID]?.token == token {
            tasks.removeValue(forKey: paneID)
        }
    }

    static func cancel(for paneID: UUID) {
        tasks.removeValue(forKey: paneID)?.task.cancel()
        coordinators.removeValue(forKey: paneID)
    }

    static func hasStarted(for paneID: UUID) -> Bool {
        tasks[paneID] != nil || coordinators[paneID] != nil
    }
}

extension TerminalController {
    func startRevisionHandoffProbeIfNeeded(
        for surface: Ghostty.SurfaceView,
        interactive: Bool = false,
        transport: SessionRuntimeRevisionHandoffTransport = OMGDRevisionHandoffTransport.shared
    ) {
        guard let context = surface.pendingRevisionHandoff,
              surfaceTree.contains(where: { $0 === surface }),
              !SessionRuntimeRevisionHandoffTasks.hasStarted(for: context.paneID) else {
            return
        }
        runRevisionHandoffProbe(for: surface, context: context, interactive: interactive, transport: transport)
    }

    func retryRevisionHandoffProbe(
        for surface: Ghostty.SurfaceView,
        transport: SessionRuntimeRevisionHandoffTransport = OMGDRevisionHandoffTransport.shared
    ) {
        guard let context = surface.pendingRevisionHandoff,
              surfaceTree.contains(where: { $0 === surface }) else {
            return
        }
        runRevisionHandoffProbe(for: surface, context: context, interactive: true, transport: transport)
    }

    func performRevisionHandoff(
        for surface: Ghostty.SurfaceView,
        transport: SessionRuntimeRevisionHandoffTransport = OMGDRevisionHandoffTransport.shared
    ) {
        guard let context = surface.pendingRevisionHandoff,
              surfaceTree.contains(where: { $0 === surface }) else {
            return
        }
        let coordinator = SessionRuntimeRevisionHandoffTasks.coordinator(for: context)
        surface.revisionHandoffState = .handingOff(
            cwd: coordinator.state.effectiveWorkingDirectory ?? context.savedWorkingDirectory,
            resume: coordinator.state.effectiveResume ?? context.fallbackResume()
        )
        let token = UUID()
        let task = Task { @MainActor [weak self, weak surface] in
            defer { SessionRuntimeRevisionHandoffTasks.finishTask(token: token, for: context.paneID) }
            let resolution = await coordinator.performGracefulHandoff(transport: transport)
            guard !Task.isCancelled,
                  let self,
                  let surface,
                  self.surfaceTree.contains(where: { $0 === surface }),
                  surface.pendingRevisionHandoff == context else {
                return
            }
            self.applyRevisionHandoffResolution(resolution, to: surface)
        }
        SessionRuntimeRevisionHandoffTasks.setTask(task, token: token, for: context.paneID)
    }

    func openFreshShellForRevisionHandoff(for surface: Ghostty.SurfaceView) {
        guard let context = surface.pendingRevisionHandoff,
              surfaceTree.contains(where: { $0 === surface }) else {
            return
        }
        let coordinator = SessionRuntimeRevisionHandoffTasks.coordinator(for: context)
        let plan = coordinator.freshShellPlan()
        SessionRuntimeRevisionHandoffTasks.cancel(for: context.paneID)
        replacePendingRevisionHandoffSurface(surface, using: plan)
    }

    func cancelRevisionHandoff(for surfaceID: UUID) {
        SessionRuntimeRevisionHandoffTasks.cancel(for: surfaceID)
    }

    private func runRevisionHandoffProbe(
        for surface: Ghostty.SurfaceView,
        context: SessionRuntimeRevisionHandoffContext,
        interactive: Bool,
        transport: SessionRuntimeRevisionHandoffTransport
    ) {
        let coordinator = SessionRuntimeRevisionHandoffTasks.coordinator(for: context)
        surface.revisionHandoffState = .probing
        let token = UUID()
        let task = Task { @MainActor [weak self, weak surface] in
            defer { SessionRuntimeRevisionHandoffTasks.finishTask(token: token, for: context.paneID) }
            let resolution = await coordinator.runProbe(interactive: interactive, transport: transport)
            guard !Task.isCancelled,
                  let self,
                  let surface,
                  self.surfaceTree.contains(where: { $0 === surface }),
                  surface.pendingRevisionHandoff == context else {
                return
            }
            self.applyRevisionHandoffResolution(resolution, to: surface)
        }
        SessionRuntimeRevisionHandoffTasks.setTask(task, token: token, for: context.paneID)
    }

    private func applyRevisionHandoffResolution(
        _ resolution: SessionRuntimeRevisionHandoffCoordinator.Resolution,
        to surface: Ghostty.SurfaceView
    ) {
        switch resolution {
        case .stay(let nextState):
            surface.revisionHandoffState = nextState
        case .launch(let plan):
            if let context = surface.pendingRevisionHandoff {
                SessionRuntimeRevisionHandoffTasks.cancel(for: context.paneID)
            }
            replacePendingRevisionHandoffSurface(surface, using: plan)
        }
    }

    private func replacePendingRevisionHandoffSurface(
        _ surface: Ghostty.SurfaceView,
        using plan: SessionRuntimeRevisionHandoffLaunchPlan
    ) {
        guard let ghosttyApp = ghostty.app,
              let node = surfaceTree.find(id: surface.id),
              !surfaceTree.contains(where: { $0 !== surface && $0.id == surface.id }) else {
            return
        }
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["OH_MY_GHOSTTY_CHANNEL"] = OMGApplicationEnvironment.channel()
        do {
            try plan.configure(&config)
        } catch {
            surface.revisionHandoffState = .closeFailed(
                message: error.localizedDescription,
                cwd: plan.workingDirectory,
                resume: plan.resume
            )
            return
        }
        config = Self.injectingSessionID(tabSessionID, into: config)
        let replacement = Ghostty.SurfaceView(ghosttyApp, baseConfig: config, uuid: plan.paneID)
        let preservedTitle = surface.title.isEmpty ? nil : surface.title
        if let agentDescriptor = plan.resume?.agentResumeDescriptor(for: plan.descriptor.connection) {
            replacement.agentResumeDescriptor = agentDescriptor
        }
        guard let newTree = try? surfaceTree.replacing(node: node, with: .leaf(view: replacement)) else {
            return
        }
        replaceSurfaceTree(
            newTree,
            moveFocusTo: focusedSurface === surface ? replacement : nil,
            moveFocusFrom: surface,
            undoAction: nil
        )
        if focusedSurface === surface {
            focusedSurface = replacement
        }
        if let agentDescriptor = replacement.agentResumeDescriptor {
            adoptAgentResumeDescriptor(agentDescriptor, for: replacement, title: preservedTitle)
        }
        invalidateRestorableState()
    }
}

struct SessionRuntimeRevisionHandoffStrings: Equatable, Sendable {
    private let settings: SettingsStrings

    init(language: OhMyGhosttyLanguage) {
        settings = SettingsStrings(language: language)
    }

    func t(_ english: String, _ chinese: String) -> String {
        settings.t(english, chinese)
    }

    var probingTitle: String {
        t("Checking previous runtime session…", "正在检查旧版本会话…")
    }

    var probingDetail: String {
        t(
            "Verifying whether the session on the previous runtime version is still running before resuming.",
            "正在确认旧版运行时中的会话是否仍在运行，避免重复打开同一对话。"
        )
    }

    var handoffRequiredTitle: String {
        t("Session Handoff Required", "需要移交旧版本会话")
    }

    var unverifiedTitle: String {
        t("Could Not Verify Previous Session", "无法确认旧版本会话状态")
    }

    var handingOffTitle: String {
        t("Handing Off Session…", "正在优雅接管会话…")
    }

    var handingOffDetail: String {
        t(
            "Gracefully closing only this session on the previous runtime and waiting for it to exit cleanly.",
            "正在仅关闭旧版运行时中的这一个会话，并等待其正常退出释放对话锁。"
        )
    }

    var closeFailedTitle: String {
        t("Could Not Close Previous Session", "无法关闭旧版本会话")
    }

    func aliveDetail(revision: String, resume: SessionRuntimeHandoffResume?) -> String {
        if let resume {
            let agent = resume.agentDisplayName
            return t(
                "This session is still running \(agent) on an older runtime version (\(revision)). Handing off closes only this session so \(agent) releases its conversation lock, then resumes it on the updated runtime.",
                "此会话仍在旧版运行时（\(revision)）中运行 \(agent)。优雅接管会仅关闭旧运行时中的这一个会话，待 \(agent) 正常退出释放对话锁后，再在新版运行时中自动恢复。"
            )
        }
        return t(
            "This session is still running on an older runtime version (\(revision)) with an incompatible terminal snapshot format. Hand off to close only this session and reopen in the updated runtime, or open a fresh shell leaving the old session running.",
            "此会话仍在旧版运行时（\(revision)）中运行，其终端快照格式与当前版本不兼容。你可以优雅接管（仅关闭此旧会话并在新版运行时重新打开），或仅打开新终端并保留旧会话。"
        )
    }

    func unverifiedDetail(probeError: String?) -> String {
        let base = t(
            "Automatic resume is paused so the same conversation is not opened twice.",
            "已暂停自动恢复，以避免同一对话被重复打开。"
        )
        guard let probeError, !probeError.isEmpty else { return base }
        return "\(base) \(probeError)"
    }

    func closeFailedDetail(message: String) -> String {
        t(
            "Automatic resume was not started because the previous session may still be running. \(message)",
            "由于旧版本会话可能仍在运行，未自动恢复对话。\(message)"
        )
    }

    func handoffActionTitle(hasResume: Bool) -> String {
        hasResume
            ? t("Hand Off & Resume", "优雅接管并恢复")
            : t("Hand Off Session", "优雅接管会话")
    }

    var retryHandoffTitle: String {
        t("Retry Handoff", "重试接管")
    }

    var retryCheckTitle: String {
        t("Retry Check", "重新检查")
    }

    var openFreshShellTitle: String {
        t("Open Fresh Shell", "仅打开新终端")
    }
}

struct SessionRuntimeRevisionHandoffOverlay: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var settings = OhMyGhosttySettings.shared
    @ObservedObject var surface: Ghostty.SurfaceView

    private var strings: SessionRuntimeRevisionHandoffStrings {
        .init(language: settings.language)
    }

    var body: some View {
        if let context = surface.pendingRevisionHandoff {
            let state = surface.revisionHandoffState ?? .probing
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.88)
                card(context: context, state: state)
                    .padding(24)
            }
            .accessibilityIdentifier("sessionRuntimeRevisionHandoffOverlay")
        }
    }

    @ViewBuilder
    private func card(
        context: SessionRuntimeRevisionHandoffContext,
        state: SessionRuntimeRevisionHandoffState
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(context: context, state: state)
            detailText(context: context, state: state)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            metadataRow(state: state)
            actionButtons(state: state)
        }
        .padding(18)
        .frame(maxWidth: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func header(
        context: SessionRuntimeRevisionHandoffContext,
        state: SessionRuntimeRevisionHandoffState
    ) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .probing, .handingOff:
                ProgressView()
                    .controlSize(.small)
            case .awaitingUser(let alive, _, _, _, _):
                Image(systemName: alive ? "arrow.triangle.swap" : "exclamationmark.triangle")
                    .foregroundStyle(alive ? Color.accentColor : Color.orange)
            case .closeFailed:
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: state))
                    .font(.headline)
                Text(context.sourceDescriptor.displayEndpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func title(for state: SessionRuntimeRevisionHandoffState) -> String {
        switch state {
        case .probing:
            return strings.probingTitle
        case .awaitingUser(let isConfirmedAlive, _, _, _, _):
            return isConfirmedAlive ? strings.handoffRequiredTitle : strings.unverifiedTitle
        case .handingOff:
            return strings.handingOffTitle
        case .closeFailed:
            return strings.closeFailedTitle
        }
    }

    private func detailText(
        context: SessionRuntimeRevisionHandoffContext,
        state: SessionRuntimeRevisionHandoffState
    ) -> Text {
        switch state {
        case .probing:
            return Text(strings.probingDetail)
        case .awaitingUser(let isConfirmedAlive, _, _, let resume, let probeError):
            if isConfirmedAlive {
                return Text(strings.aliveDetail(revision: context.shortSourceRevision, resume: resume))
            }
            return Text(strings.unverifiedDetail(probeError: probeError))
        case .handingOff:
            return Text(strings.handingOffDetail)
        case .closeFailed(let message, _, _):
            return Text(strings.closeFailedDetail(message: message))
        }
    }

    @ViewBuilder
    private func metadataRow(state: SessionRuntimeRevisionHandoffState) -> some View {
        let resume = state.effectiveResume
        let cwd = state.effectiveWorkingDirectory
        let pid: Int? = if case .awaitingUser(_, let pidValue, _, _, _) = state { pidValue } else { nil }
        if resume != nil || cwd != nil || pid != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let resume {
                    Text("\(resume.agentDisplayName) · \(resume.shortConversationID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let cwd {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let pid {
                    Text("PID \(pid)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private func actionButtons(state: SessionRuntimeRevisionHandoffState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .probing:
                Button(strings.openFreshShellTitle) {
                    controller.openFreshShellForRevisionHandoff(for: surface)
                }
            case .awaitingUser(let isConfirmedAlive, _, _, let resume, _):
                Button(strings.handoffActionTitle(hasResume: resume != nil)) {
                    controller.performRevisionHandoff(for: surface)
                }
                .buttonStyle(.borderedProminent)
                if !isConfirmedAlive {
                    Button(strings.retryCheckTitle) {
                        controller.retryRevisionHandoffProbe(for: surface)
                    }
                }
                Button(strings.openFreshShellTitle) {
                    controller.openFreshShellForRevisionHandoff(for: surface)
                }
            case .handingOff:
                Button(strings.openFreshShellTitle) {
                    controller.openFreshShellForRevisionHandoff(for: surface)
                }
                .disabled(true)
            case .closeFailed:
                Button(strings.retryHandoffTitle) {
                    controller.performRevisionHandoff(for: surface)
                }
                .buttonStyle(.borderedProminent)
                Button(strings.openFreshShellTitle) {
                    controller.openFreshShellForRevisionHandoff(for: surface)
                }
            }
        }
    }
}
