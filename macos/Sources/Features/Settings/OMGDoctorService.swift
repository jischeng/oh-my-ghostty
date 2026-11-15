import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import GhosttyKit
import Security

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

enum OMGSignerTrustMode: String, Codable, Equatable, Sendable {
    case appleTrusted = "apple_trusted"
    case selfSignedAdminTrusted = "self_signed_admin_trusted"
    case selfSignedUserOnlyTrusted = "self_signed_user_only_trusted"
    case selfSignedUntrusted = "self_signed_untrusted"
    case adHocOrDevelopment = "ad_hoc_or_development"
    case unsigned = "unsigned"
}

enum OMGSignerTrustInstallError: Error, Equatable, Sendable {
    case missingCertificate
    case invalidCertificate
    case canceled
    case executionFailed(String)

    func localizedSummary(strings: SettingsStrings) -> String {
        switch self {
        case .missingCertificate:
            return strings.t(
                "No self-signed release certificate is present on this bundle.",
                "当前应用包未附带自签名发布证书。"
            )
        case .invalidCertificate:
            return strings.t(
                "Refusing to install trust for a non-self-signed certificate.",
                "仅支持为自签名发布证书安装代码签名信任。"
            )
        case .canceled:
            return strings.t(
                "Administrator authorization canceled; no keychain trust settings were changed.",
                "已取消管理员授权，未修改钥匙串信任设置。"
            )
        case .executionFailed(let message):
            return message
        }
    }
}

struct OMGDoctorSignerTrustCheck: Equatable, Sendable {
    let status: OMGDoctorHealthStatus
    let mode: OMGSignerTrustMode
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let certificateCommonName: String?
    let certificateSHA1: String?
    let isSelfSignedLeaf: Bool
    let trustedInAdminDomain: Bool
    let trustedInUserDomain: Bool
    let isCodeSigningTrusted: Bool
    let isNonCodeSigningBlocked: Bool
    let hasUnscopedTrust: Bool
    let leafCertificateDER: Data?

    var needsTrustAction: Bool {
        status == .warning && isSelfSignedLeaf && leafCertificateDER != nil
    }

    func summary(strings: SettingsStrings) -> String {
        let certLabel = certificateCommonName ?? "OMG Release Signing"
        let fpSuffix = certificateSHA1.map { " (\($0.prefix(12))…)" } ?? ""
        switch mode {
        case .appleTrusted:
            let teamNote = teamIdentifier.map { "Team \($0)" } ?? "Apple signed"
            return strings.t(
                "Apple code signing trusted · \(teamNote).",
                "Apple 开发者签名已受信任 · \(teamNote)。"
            )
        case .selfSignedAdminTrusted:
            if hasUnscopedTrust || !isNonCodeSigningBlocked {
                return strings.t(
                    "\(certLabel)\(fpSuffix) has overly broad trust (non-CodeSigning policies allowed). Re-apply CodeSigning-only Admin trust.",
                    "\(certLabel)\(fpSuffix) 的信任范围过宽（允许了非代码签名策略）。请重新安装仅限代码签名的管理员域信任。"
                )
            }
            return strings.t(
                "\(certLabel)\(fpSuffix) trusted in System Admin domain (Code Signing only; Accessibility & Gatekeeper persist across updates).",
                "\(certLabel)\(fpSuffix) 已在系统管理员域受信任（仅限代码签名；辅助功能与 Gatekeeper 权限将在更新后保持）。"
            )
        case .selfSignedUserOnlyTrusted:
            return strings.t(
                "\(certLabel)\(fpSuffix) is only trusted in the user keychain. Install Admin domain trust so Accessibility & Gatekeeper persist across updates.",
                "\(certLabel)\(fpSuffix) 仅在当前用户钥匙串受信任。请安装管理员域信任，以便辅助功能与 Gatekeeper 权限在更新后保持。"
            )
        case .selfSignedUntrusted:
            return strings.t(
                "\(certLabel)\(fpSuffix) is not yet trusted for Code Signing in System Keychain; Accessibility & Gatekeeper prompts will repeat on updates.",
                "\(certLabel)\(fpSuffix) 尚未在系统钥匙串中授予代码签名信任；每次更新后都会重复弹出辅助功能与 Gatekeeper 提示。"
            )
        case .adHocOrDevelopment:
            if bundleIdentifier == "com.jischeng.omg" {
                return strings.t(
                    "Release bundle uses ad-hoc or non-pinned signing without a persistent team or self-signed leaf.",
                    "发布包未使用固定团队签名或自签名发布证书。"
                )
            }
            return strings.t(
                "Development/local build signature (\(bundleIdentifier ?? "unbundled")).",
                "开发/本地构建签名（\(bundleIdentifier ?? "非应用包")）。"
            )
        case .unsigned:
            if bundleIdentifier == "com.jischeng.omg" {
                return strings.t(
                    "Release bundle code signature could not be read.",
                    "无法读取发布包代码签名。"
                )
            }
            return strings.t(
                "Unsigned development binary.",
                "未签名的本地开发二进制。"
            )
        }
    }
}

struct OMGDoctorReport: Equatable, Sendable {
    let accessibility: OMGDoctorAccessibilityCheck
    let signerTrust: OMGDoctorSignerTrustCheck
    let runtimeSSH: OMGDoctorRuntimeSSHCheck
    let agentBackups: OMGDoctorAgentBackupCheck
    let resources: OMGDoctorResourceCheck

    var overallStatus: OMGDoctorHealthStatus {
        let checks = [
            accessibility.status,
            signerTrust.status,
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
        var inspectSignerTrust: @Sendable () -> OMGDoctorSignerTrustCheck = {
            OMGDoctorService.defaultInspectSignerTrust(bundleURL: Bundle.main.bundleURL)
        }
        var installSignerTrust: @Sendable (Data) async -> Result<Void, OMGSignerTrustInstallError> = { derData in
            await OMGDoctorService.defaultInstallSignerTrust(derData: derData)
        }
    }

    static let shared = OMGDoctorService()

    @Published private(set) var report: OMGDoctorReport
    @Published private(set) var lastReclaimResult: OMGDoctorReclaimResult?
    @Published private(set) var lastSignerTrustError: OMGSignerTrustInstallError?

    private let dependencies: Dependencies
    private var tapObserver: AnyCancellable?

    init(dependencies: Dependencies = .init()) {
        self.dependencies = dependencies
        self.report = Self.buildInitialPlaceholderReport(dependencies: dependencies)
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
        let hasGlobal = dependencies.hasGlobalKeybinds()
        let trusted = dependencies.isAccessibilityTrusted()
        let tapActive = dependencies.isEventTapEnabled()
        let accessibility = OMGDoctorAccessibilityCheck(
            status: (hasGlobal && !trusted) ? .warning : .healthy,
            hasGlobalKeybinds: hasGlobal,
            isTrusted: trusted,
            isEventTapEnabled: tapActive
        )
        let webMetrics = dependencies.workspaceStore.resourceMetrics
        let surfaceCounts = dependencies.surfaceCounter()
        let localSnapshot = dependencies.agentManager.snapshots[AgentIntegrationManager.localID]
        let detectedCLICount = localSnapshot?.cli.values.filter { $0.path != nil || $0.version != nil }.count ?? 0
        let cachedHookCounts: (installed: Int, outdated: Int)? = {
            guard let snapshot = localSnapshot, !snapshot.hooks.isEmpty else { return nil }
            var installed = 0
            var outdated = 0
            for state in snapshot.hooks.values {
                if state.isInstalled { installed += 1 }
                if state == .updateAvailable { outdated += 1 }
            }
            return (installed, outdated)
        }()
        let inspectSignerTrust = dependencies.inspectSignerTrust
        let residentMemoryProvider = dependencies.residentMemoryProvider
        let resourcesURL = dependencies.resourcesURL
        let homeDirectory = dependencies.homeDirectory
        let sshControlDirectoryPath = dependencies.sshControlDirectoryPath
        let expectedUID = dependencies.expectedUID

        let lspMetrics = await dependencies.lspManager.resourceMetrics()
        let background = await Task.detached(priority: .utility) {
            let signerTrust = inspectSignerTrust()
            let runtimeSSH = Self.inspectRuntimeAndSSH(
                resourcesURL: resourcesURL,
                homeDirectory: homeDirectory,
                sshControlDirectoryPath: sshControlDirectoryPath,
                expectedUID: expectedUID
            )
            let agentBackups = Self.inspectAgentsAndBackups(
                homeDirectory: homeDirectory,
                detectedCLICount: detectedCLICount,
                cachedHookCounts: cachedHookCounts
            )
            let residentMemoryBytes = residentMemoryProvider()
            return (signerTrust, runtimeSSH, agentBackups, residentMemoryBytes)
        }.value

        let resources = OMGDoctorResourceCheck(
            status: .healthy,
            residentMemoryBytes: background.3,
            activeWebViews: webMetrics.activeWebViews,
            reclaimableWebViews: webMetrics.idleReclaimableWebViews,
            activeLSPServers: lspMetrics.activeServers,
            idleLSPServers: lspMetrics.idleServers,
            visibleSurfaces: surfaceCounts.visible,
            occludedSurfaces: surfaceCounts.occluded
        )

        report = OMGDoctorReport(
            accessibility: accessibility,
            signerTrust: background.0,
            runtimeSSH: background.1,
            agentBackups: background.2,
            resources: resources
        )
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
    func installReleaseSignerTrust() async -> Bool {
        lastSignerTrustError = nil
        guard let derData = report.signerTrust.leafCertificateDER,
              report.signerTrust.isSelfSignedLeaf else {
            lastSignerTrustError = .missingCertificate
            return false
        }
        switch await dependencies.installSignerTrust(derData) {
        case .success:
            await refresh()
            if report.signerTrust.status != .healthy {
                lastSignerTrustError = .executionFailed(
                    "Post-install verification failed: Admin CodeSigning-only trust is not yet active."
                )
                return false
            }
            return true
        case .failure(let error):
            lastSignerTrustError = error
            await refresh()
            return false
        }
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

    private static func buildInitialPlaceholderReport(
        dependencies: Dependencies
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
        let signerTrust = OMGDoctorSignerTrustCheck(
            status: .healthy,
            mode: .adHocOrDevelopment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: nil,
            certificateCommonName: nil,
            certificateSHA1: nil,
            isSelfSignedLeaf: false,
            trustedInAdminDomain: false,
            trustedInUserDomain: false,
            isCodeSigningTrusted: false,
            isNonCodeSigningBlocked: true,
            hasUnscopedTrust: false,
            leafCertificateDER: nil
        )
        let runtimeSSH = OMGDoctorRuntimeSSHCheck(
            status: .healthy,
            omgdAvailable: false,
            omgdRevision: nil,
            activeRuntimeSessions: 0,
            totalRuntimeSessionRecords: 0,
            sshControlDirectoryPath: dependencies.sshControlDirectoryPath,
            sshControlDirectoryExists: false,
            sshControlDirectoryHealthy: true,
            activeSSHSockets: 0
        )
        let agentBackups = OMGDoctorAgentBackupCheck(
            status: .healthy,
            detectedCLICount: 0,
            installedHookCount: 0,
            outdatedHookCount: 0,
            backupFileCount: 0,
            insecureBackupCount: 0
        )
        let webMetrics = dependencies.workspaceStore.resourceMetrics
        let surfaceCounts = dependencies.surfaceCounter()
        let resources = OMGDoctorResourceCheck(
            status: .healthy,
            residentMemoryBytes: 0,
            activeWebViews: webMetrics.activeWebViews,
            reclaimableWebViews: webMetrics.idleReclaimableWebViews,
            activeLSPServers: 0,
            idleLSPServers: 0,
            visibleSurfaces: surfaceCounts.visible,
            occludedSurfaces: surfaceCounts.occluded
        )
        return OMGDoctorReport(
            accessibility: accessibility,
            signerTrust: signerTrust,
            runtimeSSH: runtimeSSH,
            agentBackups: agentBackups,
            resources: resources
        )
    }

    nonisolated private static func inspectRuntimeAndSSH(
        resourcesURL: URL?,
        homeDirectory: URL,
        sshControlDirectoryPath: String,
        expectedUID: uid_t
    ) -> OMGDoctorRuntimeSSHCheck {
        var omgdAvailable = false
        var omgdRevision: String?
        if let resourcesURL {
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

        let runRoot = homeDirectory.appendingPathComponent(".omg/run", isDirectory: true)
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
                       obj["ended"] == nil || obj["ended"] is NSNull,
                       (obj["exited"] as? Bool) != true {
                        activeSessions += 1
                    }
                }
            }
        }

        let sshPath = sshControlDirectoryPath
        var info = stat()
        var sshExists = false
        var sshHealthy = true
        var socketCount = 0
        if lstat(sshPath, &info) == 0 {
            sshExists = true
            let isDir = (info.st_mode & S_IFMT) == S_IFDIR
            let isPrivate = (info.st_mode & 0o777) == 0o700
            let ownedByUser = info.st_uid == expectedUID
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

    nonisolated private static func inspectAgentsAndBackups(
        homeDirectory: URL,
        detectedCLICount: Int,
        cachedHookCounts: (installed: Int, outdated: Int)?
    ) -> OMGDoctorAgentBackupCheck {
        let installer = AgentHookInstaller(homeURL: homeDirectory)
        let audit = installer.backupAudit()

        var installedHooks = 0
        var outdatedHooks = 0
        if let cachedHookCounts {
            installedHooks = cachedHookCounts.installed
            outdatedHooks = cachedHookCounts.outdated
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

    nonisolated static func defaultInspectSignerTrust(bundleURL: URL) -> OMGDoctorSignerTrustCheck {
        let fallbackBundleID = Bundle(url: bundleURL)?.bundleIdentifier
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return makeNonSelfSignedTrustCheck(
                mode: .unsigned,
                bundleIdentifier: fallbackBundleID,
                teamIdentifier: nil,
                certificate: nil
            )
        }

        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &cfInfo) == errSecSuccess,
              let info = cfInfo as? [String: Any] else {
            return makeNonSelfSignedTrustCheck(
                mode: .unsigned,
                bundleIdentifier: fallbackBundleID,
                teamIdentifier: nil,
                certificate: nil
            )
        }

        let signingIdentifier = (info[kSecCodeInfoIdentifier as String] as? String) ?? fallbackBundleID
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []

        if let teamIdentifier, !teamIdentifier.isEmpty {
            return makeNonSelfSignedTrustCheck(
                mode: .appleTrusted,
                bundleIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier,
                certificate: certificates.first
            )
        }

        guard let leafCertificate = certificates.first else {
            return makeNonSelfSignedTrustCheck(
                mode: .adHocOrDevelopment,
                bundleIdentifier: signingIdentifier,
                teamIdentifier: nil,
                certificate: nil
            )
        }

        return inspectLeafCertificateTrust(
            certificate: leafCertificate,
            bundleIdentifier: signingIdentifier,
            teamIdentifier: nil
        )
    }

    nonisolated static func inspectLeafCertificateTrust(
        certificate: SecCertificate,
        bundleIdentifier: String?,
        teamIdentifier: String? = nil
    ) -> OMGDoctorSignerTrustCheck {
        let derData = SecCertificateCopyData(certificate) as Data
        let sha1 = Insecure.SHA1.hash(data: derData)
            .map { String(format: "%02X", $0) }
            .joined()
        let commonName = SecCertificateCopySubjectSummary(certificate) as String?

        let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?
        let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
        let isSelfSigned = subject != nil && subject == issuer
        guard isSelfSigned else {
            let status: OMGDoctorHealthStatus = bundleIdentifier == "com.jischeng.omg" ? .warning : .healthy
            return OMGDoctorSignerTrustCheck(
                status: status,
                mode: .adHocOrDevelopment,
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                certificateCommonName: commonName,
                certificateSHA1: sha1,
                isSelfSignedLeaf: false,
                trustedInAdminDomain: false,
                trustedInUserDomain: false,
                isCodeSigningTrusted: false,
                isNonCodeSigningBlocked: true,
                hasUnscopedTrust: false,
                leafCertificateDER: nil
            )
        }

        let adminDomain = checkDomainTrust(certificate: certificate, domain: .admin)
        let userDomain = checkDomainTrust(certificate: certificate, domain: .user)

        let certArray = [certificate] as CFArray
        let csPolicy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil)
        let csTrusted = csPolicy.map { evaluateTrustPolicy($0, certificates: certArray) } ?? false
        let x509Trusted = evaluateTrustPolicy(SecPolicyCreateBasicX509(), certificates: certArray)
        let sslTrusted = evaluateTrustPolicy(SecPolicyCreateSSL(true, nil), certificates: certArray)

        let nonCodeSigningBlocked = !x509Trusted && !sslTrusted
        let hasUnscopedTrust = adminDomain.hasUnscoped || userDomain.hasUnscoped || x509Trusted || sslTrusted

        let mode: OMGSignerTrustMode
        if adminDomain.hasCodeSigning && csTrusted {
            mode = .selfSignedAdminTrusted
        } else if userDomain.hasCodeSigning && csTrusted {
            mode = .selfSignedUserOnlyTrusted
        } else {
            mode = .selfSignedUntrusted
        }

        let isHealthy = mode == .selfSignedAdminTrusted
            && csTrusted
            && nonCodeSigningBlocked
            && !hasUnscopedTrust

        return OMGDoctorSignerTrustCheck(
            status: isHealthy ? .healthy : .warning,
            mode: mode,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            certificateCommonName: commonName,
            certificateSHA1: sha1,
            isSelfSignedLeaf: true,
            trustedInAdminDomain: adminDomain.hasCodeSigning,
            trustedInUserDomain: userDomain.hasCodeSigning,
            isCodeSigningTrusted: csTrusted,
            isNonCodeSigningBlocked: nonCodeSigningBlocked,
            hasUnscopedTrust: hasUnscopedTrust,
            leafCertificateDER: derData
        )
    }

    nonisolated private static func makeNonSelfSignedTrustCheck(
        mode: OMGSignerTrustMode,
        bundleIdentifier: String?,
        teamIdentifier: String?,
        certificate: SecCertificate?
    ) -> OMGDoctorSignerTrustCheck {
        let derData = certificate.map { SecCertificateCopyData($0) as Data }
        let sha1 = derData.map { data in
            Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }
        let commonName = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let status: OMGDoctorHealthStatus = switch mode {
        case .appleTrusted:
            .healthy
        case .adHocOrDevelopment, .unsigned:
            bundleIdentifier == "com.jischeng.omg" ? .warning : .healthy
        case .selfSignedAdminTrusted, .selfSignedUserOnlyTrusted, .selfSignedUntrusted:
            .warning
        }

        return OMGDoctorSignerTrustCheck(
            status: status,
            mode: mode,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            certificateCommonName: commonName,
            certificateSHA1: sha1,
            isSelfSignedLeaf: false,
            trustedInAdminDomain: false,
            trustedInUserDomain: false,
            isCodeSigningTrusted: mode == .appleTrusted,
            isNonCodeSigningBlocked: true,
            hasUnscopedTrust: false,
            leafCertificateDER: nil
        )
    }

    nonisolated private static func checkDomainTrust(
        certificate: SecCertificate,
        domain: SecTrustSettingsDomain
    ) -> (hasCodeSigning: Bool, hasUnscoped: Bool) {
        var cfSettings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, domain, &cfSettings)
        guard status == errSecSuccess else {
            return (false, false)
        }
        guard let entries = cfSettings as? [[String: Any]], !entries.isEmpty else {
            // An empty array in macOS Trust Settings means "Always Trust" for all policies.
            return (true, true)
        }

        let codeSignOID = kSecPolicyAppleCodeSigning as String
        var hasCodeSigning = false
        var hasUnscoped = false

        for dict in entries {
            let resultRaw = (dict[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value
                ?? SecTrustSettingsResult.trustRoot.rawValue
            guard resultRaw == SecTrustSettingsResult.trustRoot.rawValue
                || resultRaw == SecTrustSettingsResult.trustAsRoot.rawValue else {
                continue
            }

            guard let policyObj = dict[kSecTrustSettingsPolicy as String] else {
                hasUnscoped = true
                hasCodeSigning = true
                continue
            }

            let policyOID: String?
            let cfPolicy = policyObj as AnyObject as CFTypeRef
            if CFGetTypeID(cfPolicy) == SecPolicyGetTypeID() {
                let secPolicy = unsafeBitCast(cfPolicy, to: SecPolicy.self)
                let props = SecPolicyCopyProperties(secPolicy) as? [String: Any]
                policyOID = props?[kSecPolicyOid as String] as? String
            } else {
                policyOID = policyObj as? String
            }

            if policyOID == codeSignOID {
                let hasAppScope = dict[kSecTrustSettingsApplication as String] != nil
                let hasPolicyString = dict[kSecTrustSettingsPolicyString as String] != nil
                if !hasAppScope && !hasPolicyString {
                    hasCodeSigning = true
                }
            }
        }

        return (hasCodeSigning, hasUnscoped)
    }

    nonisolated private static func evaluateTrustPolicy(
        _ policy: SecPolicy,
        certificates: CFArray
    ) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates, policy, &trust) == errSecSuccess,
              let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    nonisolated static func defaultInstallSignerTrust(
        derData: Data
    ) async -> Result<Void, OMGSignerTrustInstallError> {
        guard let cert = SecCertificateCreateWithData(nil, derData as CFData) else {
            return .failure(.invalidCertificate)
        }
        let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data?
        let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data?
        guard subject != nil && subject == issuer else {
            return .failure(.invalidCertificate)
        }

        return await Task.detached(priority: .userInitiated) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("omg-release-signer-\(UUID().uuidString).der")
            let fd = Darwin.open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                return .failure(.executionFailed("Failed to create temporary certificate file (errno \(errno))."))
            }
            defer { _ = Darwin.unlink(tempURL.path) }

            let writeSucceeded = derData.withUnsafeBytes { rawBuffer -> Bool in
                guard let base = rawBuffer.baseAddress else { return true }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
            _ = Darwin.close(fd)
            guard writeSucceeded else {
                return .failure(.executionFailed("Failed to write release certificate bytes."))
            }

            let escapedPath = tempURL.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // Self-signed CA:FALSE certificates fail with errSecParam (-50) under -r trustAsRoot;
            // use -r trustRoot -p codeSign in Admin domain (-d) so TCC/Gatekeeper stick across updates.
            let source = "do shell script \"/usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain \" & quoted form of \"\(escapedPath)\" with administrator privileges"
            guard let script = NSAppleScript(source: source) else {
                return .failure(.executionFailed("Unable to initialize administrator authorization script."))
            }
            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                if let code = errorInfo[NSAppleScript.errorNumber] as? Int, code == -128 {
                    return .failure(.canceled)
                }
                let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? "Administrator trust installation failed."
                return .failure(.executionFailed(message))
            }
            return .success(())
        }.value
    }
}
