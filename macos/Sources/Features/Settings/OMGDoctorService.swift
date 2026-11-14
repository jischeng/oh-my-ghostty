import AppKit
import Combine
import Darwin
import Foundation
import GhosttyKit

enum OMGDoctorHealthStatus: String, Codable, Equatable, Sendable {
    case healthy
    case warning
}

struct OMGDoctorAccessibilityCheck: Equatable, Sendable {
    let status: OMGDoctorHealthStatus
    let hasGlobalKeybinds: Bool
    let isTrusted: Bool
    let isEventTapEnabled: Bool

    var needsGrantAction: Bool {
        hasGlobalKeybinds && !isTrusted
    }

    func summary(strings: SettingsStrings) -> String {
        if hasGlobalKeybinds && !isTrusted {
            return strings.t(
                "Global keybinds are configured, but macOS Accessibility permission is missing (common after Sparkle updates).",
                "已配置全局快捷键，但尚未获得 macOS 辅助功能权限（常见于版本更新后）。"
            )
        }
        if hasGlobalKeybinds {
            let tapNote = isEventTapEnabled
                ? strings.t("event tap active", "事件监听已激活")
                : strings.t("permission granted", "权限已授予")
            return strings.t(
                "Accessibility trusted · \(tapNote).",
                "辅助功能权限已就绪 · \(tapNote)。"
            )
        }
        return isTrusted
            ? strings.t(
                "Accessibility permission granted · no global keybinds configured.",
                "已获得辅助功能权限 · 当前未配置全局快捷键。"
            )
            : strings.t(
                "No global keybinds configured · Accessibility permission not required.",
                "当前未配置全局快捷键 · 无需辅助功能权限。"
            )
    }
}

struct OMGDoctorRuntimeSSHCheck: Equatable, Sendable {
    let status: OMGDoctorHealthStatus
    let omgdAvailable: Bool
    let omgdRevision: String?
    let activeRuntimeSessions: Int
    let totalRuntimeSessionRecords: Int
    let sshControlDirectoryPath: String
    let sshControlDirectoryExists: Bool
    let sshControlDirectoryHealthy: Bool
    let activeSSHSockets: Int

    func summary(strings: SettingsStrings) -> String {
        let runtimePart: String
        if omgdAvailable {
            let rev = omgdRevision.map { String($0.prefix(12)) } ?? "bundled"
            runtimePart = strings.t(
                "omgd (\(rev)): \(activeRuntimeSessions) active / \(totalRuntimeSessionRecords) recorded sessions",
                "omgd（\(rev)）：\(activeRuntimeSessions) 个活跃 / 共 \(totalRuntimeSessionRecords) 条会话记录"
            )
        } else {
            runtimePart = strings.t(
                "omgd helper not bundled in current build",
                "当前构建未内置 omgd 运行时组件"
            )
        }

        let sshPart: String
        if !sshControlDirectoryExists {
            sshPart = strings.t(
                "SSH ControlMaster dir on-demand (0 sockets)",
                "SSH 复用目录按需创建（0 个连接套接字）"
            )
        } else if sshControlDirectoryHealthy {
            sshPart = strings.t(
                "SSH ControlMaster dir 0700 (\(activeSSHSockets) sockets)",
                "SSH 复用目录权限 0700（\(activeSSHSockets) 个连接套接字）"
            )
        } else {
            sshPart = strings.t(
                "SSH ControlMaster dir has unsafe ownership or permissions (\(sshControlDirectoryPath))",
                "SSH 复用目录属主或权限异常（\(sshControlDirectoryPath)）"
            )
        }
        return "\(runtimePart) · \(sshPart)"
    }
}

struct OMGDoctorAgentBackupCheck: Equatable, Sendable {
    let status: OMGDoctorHealthStatus
    let detectedCLICount: Int
    let installedHookCount: Int
    let outdatedHookCount: Int
    let backupFileCount: Int
    let insecureBackupCount: Int

    func summary(strings: SettingsStrings) -> String {
        let cliPart = strings.t(
            "\(detectedCLICount) detected CLIs · \(installedHookCount) hooks active",
            "已识别 \(detectedCLICount) 个 CLI · \(installedHookCount) 项 Hook 已启用"
        )
        let updatePart = outdatedHookCount > 0
            ? strings.t(" (\(outdatedHookCount) need update)", "（\(outdatedHookCount) 项待更新）")
            : ""
        let backupPart: String
        if insecureBackupCount > 0 {
            backupPart = strings.t(
                "\(backupFileCount) .omg.bak backups (\(insecureBackupCount) not 0600)",
                "\(backupFileCount) 份 .omg.bak 备份（\(insecureBackupCount) 份非 0600 权限）"
            )
        } else {
            backupPart = strings.t(
                "\(backupFileCount) private 0600 .omg.bak backups",
                "\(backupFileCount) 份 0600 私有 .omg.bak 备份"
            )
        }
        return "\(cliPart)\(updatePart) · \(backupPart)"
    }
}

struct OMGDoctorResourceCheck: Equatable, Sendable {
    let status: OMGDoctorHealthStatus
    let residentMemoryBytes: UInt64
    let activeWebViews: Int
    let reclaimableWebViews: Int
    let activeLSPServers: Int
    let idleLSPServers: Int
    let visibleSurfaces: Int
    let occludedSurfaces: Int

    var canReclaimIdleResources: Bool {
        reclaimableWebViews > 0 || idleLSPServers > 0
    }

    func summary(strings: SettingsStrings) -> String {
        let memoryMB = Double(residentMemoryBytes) / (1_024.0 * 1_024.0)
        let memText = String(format: "%.1f MB RSS", memoryMB)
        return strings.t(
            "\(memText) · WebViews: \(activeWebViews) (\(reclaimableWebViews) idle) · LSP: \(activeLSPServers) (\(idleLSPServers) idle) · Surfaces: \(visibleSurfaces) visible / \(occludedSurfaces) occluded",
            "\(memText) · 编辑器 WebView：\(activeWebViews)（\(reclaimableWebViews) 空闲） · 语言服务：\(activeLSPServers)（\(idleLSPServers) 空闲） · 终端面板：\(visibleSurfaces) 可见 / \(occludedSurfaces) 遮挡"
        )
    }
}

struct OMGDoctorReport: Equatable, Sendable {
    let accessibility: OMGDoctorAccessibilityCheck
    let runtimeSSH: OMGDoctorRuntimeSSHCheck
    let agentBackups: OMGDoctorAgentBackupCheck
    let resources: OMGDoctorResourceCheck

    var overallStatus: OMGDoctorHealthStatus {
        let checks = [
            accessibility.status,
            runtimeSSH.status,
            agentBackups.status,
            resources.status,
        ]
        return checks.contains(.warning) ? .warning : .healthy
    }
}

struct OMGDoctorReclaimResult: Equatable, Sendable {
    let reclaimedWebViews: Int
    let reclaimedLSPServers: Int
}

struct OMGDoctorSurfaceCounts: Equatable, Sendable {
    let visible: Int
    let occluded: Int
}

@MainActor
final class OMGDoctorService: ObservableObject {
    struct Dependencies {
        var hasGlobalKeybinds: @MainActor () -> Bool = OMGDoctorService.defaultHasGlobalKeybinds
        var isAccessibilityTrusted: @MainActor () -> Bool = { GlobalEventTap.isAccessibilityTrusted() }
        var isEventTapEnabled: @MainActor () -> Bool = { GlobalEventTap.shared.isTapEnabled }
        var requestAccessibility: @MainActor () -> Bool = { GlobalEventTap.requestAccessibilityPermission() }
        var resourcesURL: URL? = Bundle.main.resourceURL
        var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        var sshControlDirectoryPath: String = "/tmp/omg-git-\(getuid())"
        var expectedUID: uid_t = getuid()
        var workspaceStore: EditorWorkspaceStore = .shared
        var lspManager: EditorLSPManager = .shared
        var agentManager: AgentIntegrationManager = .shared
        var surfaceCounter: @MainActor () -> OMGDoctorSurfaceCounts = OMGDoctorService.defaultSurfaceCounts
        var residentMemoryProvider: @Sendable () -> UInt64 = OMGDoctorService.currentResidentMemoryBytes
    }

    static let shared = OMGDoctorService()

    @Published private(set) var report: OMGDoctorReport
    @Published private(set) var lastReclaimResult: OMGDoctorReclaimResult?

    private let dependencies: Dependencies
    private var tapObserver: AnyCancellable?

    init(dependencies: Dependencies = .init()) {
        self.dependencies = dependencies
        self.report = Self.buildSynchronousReport(
            dependencies: dependencies,
            lspMetrics: .init(activeServers: 0, idleServers: 0)
        )
        tapObserver = NotificationCenter.default.publisher(for: GlobalEventTap.stateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }
    }

    func refresh() async {
        let lspMetrics = await dependencies.lspManager.resourceMetrics()
        report = Self.buildSynchronousReport(dependencies: dependencies, lspMetrics: lspMetrics)
    }

    @discardableResult
    func grantAccessibilityPermission() -> Bool {
        let trusted = dependencies.requestAccessibility()
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
        return trusted
    }

    @discardableResult
    func reclaimIdleResources() async -> OMGDoctorReclaimResult {
        let reclaimedWebViews = await dependencies.workspaceStore.reclaimIdleWebViews()
        let reclaimedLSPServers = await dependencies.lspManager.reclaimIdleServers()
        let result = OMGDoctorReclaimResult(
            reclaimedWebViews: reclaimedWebViews,
            reclaimedLSPServers: reclaimedLSPServers
        )
        lastReclaimResult = result
        await refresh()
        return result
    }

    private static func buildSynchronousReport(
        dependencies: Dependencies,
        lspMetrics: EditorLSPManager.ResourceMetrics
    ) -> OMGDoctorReport {
        let hasGlobal = dependencies.hasGlobalKeybinds()
        let trusted = dependencies.isAccessibilityTrusted()
        let tapActive = dependencies.isEventTapEnabled()
        let accessibility = OMGDoctorAccessibilityCheck(
            status: (hasGlobal && !trusted) ? .warning : .healthy,
            hasGlobalKeybinds: hasGlobal,
            isTrusted: trusted,
            isEventTapEnabled: tapActive
        )

        let runtimeSSH = inspectRuntimeAndSSH(dependencies: dependencies)
        let agentBackups = inspectAgentsAndBackups(dependencies: dependencies)

        let webMetrics = dependencies.workspaceStore.resourceMetrics
        let surfaceCounts = dependencies.surfaceCounter()
        let resources = OMGDoctorResourceCheck(
            status: .healthy,
            residentMemoryBytes: dependencies.residentMemoryProvider(),
            activeWebViews: webMetrics.activeWebViews,
            reclaimableWebViews: webMetrics.idleReclaimableWebViews,
            activeLSPServers: lspMetrics.activeServers,
            idleLSPServers: lspMetrics.idleServers,
            visibleSurfaces: surfaceCounts.visible,
            occludedSurfaces: surfaceCounts.occluded
        )

        return OMGDoctorReport(
            accessibility: accessibility,
            runtimeSSH: runtimeSSH,
            agentBackups: agentBackups,
            resources: resources
        )
    }

    private static func inspectRuntimeAndSSH(dependencies: Dependencies) -> OMGDoctorRuntimeSSHCheck {
        var omgdAvailable = false
        var omgdRevision: String?
        if let resourcesURL = dependencies.resourcesURL {
            let runtimeDir = resourcesURL.appendingPathComponent("session-runtime", isDirectory: true)
            let helper = runtimeDir.appendingPathComponent("omgd")
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                let revision = (try? String(
                    contentsOf: runtimeDir.appendingPathComponent("revision"),
                    encoding: .utf8
                ))?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let revision, !revision.isEmpty {
                    omgdAvailable = true
                    omgdRevision = revision
                }
            }
        }

        let runRoot = dependencies.homeDirectory.appendingPathComponent(".omg/run", isDirectory: true)
        var activeSessions = 0
        var totalRecords = 0
        if let stateDirs = try? FileManager.default.contentsOfDirectory(
            at: runRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for stateDir in stateDirs {
                let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: sessionsDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in files where file.pathExtension == "json" {
                    totalRecords += 1
                    let baseName = file.deletingPathExtension().lastPathComponent
                    let closedMarker = sessionsDir.appendingPathComponent("\(baseName).closed")
                    if FileManager.default.fileExists(atPath: closedMarker.path) {
                        continue
                    }
                    if let data = try? Data(contentsOf: file),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       (obj["exited"] as? Bool) != true {
                        activeSessions += 1
                    }
                }
            }
        }

        let sshPath = dependencies.sshControlDirectoryPath
        var info = stat()
        var sshExists = false
        var sshHealthy = true
        var socketCount = 0
        if lstat(sshPath, &info) == 0 {
            sshExists = true
            let isDir = (info.st_mode & S_IFMT) == S_IFDIR
            let isPrivate = (info.st_mode & 0o777) == 0o700
            let ownedByUser = info.st_uid == dependencies.expectedUID
            sshHealthy = isDir && isPrivate && ownedByUser
            if isDir, let entries = try? FileManager.default.contentsOfDirectory(atPath: sshPath) {
                for entry in entries where !entry.hasPrefix(".") {
                    var childStat = stat()
                    let fullPath = (sshPath as NSString).appendingPathComponent(entry)
                    if lstat(fullPath, &childStat) == 0, (childStat.st_mode & S_IFMT) == S_IFSOCK {
                        socketCount += 1
                    }
                }
            }
        }

        return OMGDoctorRuntimeSSHCheck(
            status: sshHealthy ? .healthy : .warning,
            omgdAvailable: omgdAvailable,
            omgdRevision: omgdRevision,
            activeRuntimeSessions: activeSessions,
            totalRuntimeSessionRecords: totalRecords,
            sshControlDirectoryPath: sshPath,
            sshControlDirectoryExists: sshExists,
            sshControlDirectoryHealthy: sshHealthy,
            activeSSHSockets: socketCount
        )
    }

    private static func inspectAgentsAndBackups(dependencies: Dependencies) -> OMGDoctorAgentBackupCheck {
        let installer = AgentHookInstaller(homeURL: dependencies.homeDirectory)
        let audit = installer.backupAudit()

        let localSnapshot = dependencies.agentManager.snapshots[AgentIntegrationManager.localID]
        let detectedCLICount = localSnapshot?.cli.values.filter { $0.path != nil || $0.version != nil }.count ?? 0

        var installedHooks = 0
        var outdatedHooks = 0
        if let snapshot = localSnapshot, !snapshot.hooks.isEmpty {
            for state in snapshot.hooks.values {
                if state.isInstalled {
                    installedHooks += 1
                }
                if state == .updateAvailable {
                    outdatedHooks += 1
                }
            }
        } else {
            for agent in SupportedAgent.allCases {
                let state = installer.installationState(agent)
                if state.isInstalled {
                    installedHooks += 1
                }
                if state == .updateAvailable {
                    outdatedHooks += 1
                }
            }
        }

        let status: OMGDoctorHealthStatus = (audit.insecureBackupCount > 0 || outdatedHooks > 0)
            ? .warning
            : .healthy

        return OMGDoctorAgentBackupCheck(
            status: status,
            detectedCLICount: detectedCLICount,
            installedHookCount: installedHooks,
            outdatedHookCount: outdatedHooks,
            backupFileCount: audit.backupCount,
            insecureBackupCount: audit.insecureBackupCount
        )
    }

    static func defaultHasGlobalKeybinds() -> Bool {
        if GlobalEventTap.shared.hasConfiguredGlobalKeybinds {
            return true
        }
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let app = appDelegate.ghostty.app {
            return ghostty_app_has_global_keybinds(app)
        }
        return false
    }

    static func defaultSurfaceCounts() -> OMGDoctorSurfaceCounts {
        var seen = Set<UUID>()
        var visible = 0
        var occluded = 0

        func record(controller: BaseTerminalController, parked: Bool) {
            let window = controller.window
            let windowVisible: Bool = {
                guard !parked, let window else { return false }
                guard window.isVisible, !window.isMiniaturized,
                      window.occlusionState.contains(.visible) else { return false }
                return (window.tabGroup?.selectedWindow ?? window) === window
            }()

            for surface in controller.surfaceTree where seen.insert(surface.id).inserted {
                let coveredByEditor = EditorWorkspaceStore.shared.isEditorCovering(surfaceID: surface.id)
                if windowVisible && !coveredByEditor {
                    visible += 1
                } else {
                    occluded += 1
                }
            }
        }

        for controller in TerminalController.all {
            record(controller: controller, parked: controller.workspacePresentationIsParked)
        }
        for window in NSApp.windows {
            if let quick = window.windowController as? QuickTerminalController {
                record(controller: quick, parked: false)
            }
        }

        return OMGDoctorSurfaceCounts(visible: visible, occluded: occluded)
    }

    nonisolated static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
