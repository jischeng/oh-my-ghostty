import AppKit
import Combine
import CryptoKit
import Foundation

/// Manages 1-click wireless/USB signing, installation, and opt-in 7-day
/// auto-refresh of the native `OMGMobile` iOS app on paired devices without
/// requiring the user to open Xcode.
@MainActor
final class MobileDeviceProvisioner: ObservableObject {
    static let shared = MobileDeviceProvisioner()
    static let altStoreSourceURL =
        "https://github.com/jischeng/oh-my-ghostty/releases/latest/download/altstore-source.json"
    static let defaultBundleID = "com.jischeng.omg.mobile"
    static let expiringThresholdSeconds: TimeInterval = 48 * 3600
    static let autoRefreshCheckIntervalSeconds: TimeInterval = 4 * 3600
    static let autoRefreshCooldownSeconds: TimeInterval = 6 * 3600

    enum Transport: Equatable, Sendable {
        case wired
        case localNetwork
        case other(String)

        var displayLabel: String {
            switch self {
            case .wired: return "USB"
            case .localNetwork: return "Wi-Fi"
            case .other(let raw): return raw.isEmpty ? "Unknown" : raw
            }
        }
    }

    struct PairedDevice: Equatable, Identifiable, Sendable {
        let udid: String
        let coreDeviceID: String
        let name: String
        let model: String
        let osVersion: String
        let transport: Transport
        var installedBundleID: String?

        var id: String { udid }
    }

    struct SigningIdentity: Equatable, Sendable {
        let sha1: String
        let commonName: String
        let teamID: String
    }

    struct ProvisioningProfileInfo: Equatable, Sendable {
        let uuid: String
        let path: URL
        let teamID: String
        let bundleID: String
        let isWildcard: Bool
        let expiresAt: Date
        let provisionedUDIDs: Set<String>
        let provisionsAllDevices: Bool
        let certificateSHA1s: Set<String>
        let entitlementsData: Data
    }

    enum ExpiryStatus: Equatable, Sendable {
        case unknown
        case missing(reason: String)
        case expired(expiredAt: Date)
        case expiringSoon(expiresAt: Date, remaining: TimeInterval)
        case valid(expiresAt: Date, remaining: TimeInterval)
    }

    enum OperationState: Equatable, Sendable {
        case idle
        case installing(step: String)
        case succeeded(summary: String)
        case failed(message: String)
    }

    struct CommandOutput: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var combinedText: String {
            let out = String(data: stdout, encoding: .utf8) ?? ""
            let err = String(data: stderr, encoding: .utf8) ?? ""
            return [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async -> CommandOutput

    private struct AttemptHistory: Codable {
        var lastAttemptByUDID: [String: TimeInterval]
    }

    private struct AltStoreSourceFeed: Decodable {
        struct AppEntry: Decodable {
            struct VersionEntry: Decodable {
                let version: String
                let buildVersion: String
                let downloadURL: String
                let size: Int
                let sha256: String
            }

            let versions: [VersionEntry]
        }

        let apps: [AppEntry]
    }

    @Published private(set) var devices: [PairedDevice] = []
    @Published var selectedDeviceUDID: String? {
        didSet { recomputeStatus() }
    }
    @Published private(set) var identities: [SigningIdentity] = []
    @Published private(set) var profiles: [ProvisioningProfileInfo] = []
    @Published private(set) var expiryStatus: ExpiryStatus = .unknown
    @Published private(set) var activeBundleID: String = MobileDeviceProvisioner.defaultBundleID
    @Published private(set) var activeTeamID: String?
    @Published private(set) var autoRefreshEnabled: Bool = false
    @Published private(set) var operationState: OperationState = .idle
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdatedAt: Date?

    private let supportDirectory: URL
    private let profileDirectories: [URL]
    private let runCommand: CommandRunner
    private let autoRefreshFile: URL
    private let attemptsFile: URL
    private let allowMonitorInTests: Bool
    private var xcodeFallbackTeamID: String?
    private var monitorStarted = false
    private var initialCheckWorkItem: DispatchWorkItem?
    private var monitorTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activeTask: Task<Void, Never>?

    var isAutoRefreshMonitorRunning: Bool {
        monitorStarted
    }

    var selectedDevice: PairedDevice? {
        if let udid = selectedDeviceUDID,
           let matched = devices.first(where: { $0.udid == udid }) {
            return matched
        }
        return devices.first
    }

    var isBusy: Bool {
        if case .installing = operationState { return true }
        return isScanning
    }

    init(
        supportDirectory: URL? = nil,
        profileDirectories: [URL]? = nil,
        commandRunner: CommandRunner? = nil,
        allowMonitorInTests: Bool = false
    ) {
        let resolvedSupport = supportDirectory ?? OMGApplicationEnvironment.applicationSupportURL()
        self.supportDirectory = resolvedSupport
        self.autoRefreshFile = resolvedSupport.appendingPathComponent("mobile-auto-refresh.txt")
        self.attemptsFile = resolvedSupport.appendingPathComponent("mobile-refresh-attempts.json")
        self.profileDirectories = profileDirectories ?? [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
        ]
        self.runCommand = commandRunner ?? Self.defaultRunCommand
        self.allowMonitorInTests = allowMonitorInTests
        self.autoRefreshEnabled = Self.loadBoolFlag(at: self.autoRefreshFile, defaultValue: false)
    }

    deinit {
        initialCheckWorkItem?.cancel()
        monitorTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        activeTask?.cancel()
    }

    // MARK: - Opt-in Auto-Refresh Preference & Monitor

    func setAutoRefreshEnabled(_ enabled: Bool) {
        guard autoRefreshEnabled != enabled else { return }
        autoRefreshEnabled = enabled
        Self.saveBoolFlag(enabled, at: autoRefreshFile)
        if enabled {
            startAutoRefreshMonitor()
            Task { await checkAutoRefreshIfNeeded() }
        } else {
            stopAutoRefreshMonitor()
        }
    }

    func startAutoRefreshMonitor() {
        guard autoRefreshEnabled,
              !monitorStarted,
              allowMonitorInTests || !OMGApplicationEnvironment.isRunningTests else { return }
        monitorStarted = true

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                await self?.checkAutoRefreshIfNeeded()
            }
        }
        initialCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)

        monitorTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoRefreshCheckIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAutoRefreshIfNeeded()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAutoRefreshIfNeeded()
            }
        }
    }

    func stopAutoRefreshMonitor() {
        initialCheckWorkItem?.cancel()
        initialCheckWorkItem = nil
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        monitorStarted = false
    }

    func checkAutoRefreshIfNeeded(now: Date = Date()) async {
        guard autoRefreshEnabled, !isBusy else { return }
        await scanDevices(silent: true)
        guard let target = selectedDevice else { return }
        let lastAttempt = loadLastAttemptDate(for: target.udid)
        guard Self.shouldTriggerAutoRefresh(
            enabled: autoRefreshEnabled,
            status: expiryStatus,
            device: target,
            now: now,
            lastAttemptAt: lastAttempt,
            cooldownSeconds: Self.autoRefreshCooldownSeconds
        ) else {
            return
        }
        await refreshDevice(target, forcePortalRefresh: true, isAuto: true)
    }

    static func shouldTriggerAutoRefresh(
        enabled: Bool,
        status: ExpiryStatus,
        device: PairedDevice?,
        now: Date,
        lastAttemptAt: Date?,
        cooldownSeconds: TimeInterval
    ) -> Bool {
        guard enabled, device != nil else { return false }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < cooldownSeconds {
            return false
        }
        switch status {
        case .expiringSoon, .expired:
            return true
        case .unknown, .missing, .valid:
            return false
        }
    }

    // MARK: - Device, Identity & Profile Discovery

    func scanDevices(silent: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var listOut = await runCommand(
            "/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--timeout", "15", "--json-output", tempFile.path]
        )
        if listOut.status != 0 {
            listOut = await runCommand(
                "/usr/bin/xcrun",
                ["devicectl", "list", "devices", "--json-output", tempFile.path]
            )
        }

        var discovered: [PairedDevice] = []
        if listOut.status == 0, let data = try? Data(contentsOf: tempFile) {
            discovered = Self.parseDevicectlDevices(jsonData: data)
        }

        for index in discovered.indices {
            let appsFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("omg-apps-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: appsFile) }
            let appOut = await runCommand(
                "/usr/bin/xcrun",
                [
                    "devicectl", "device", "info", "apps",
                    "--device", discovered[index].coreDeviceID,
                    "--timeout", "10",
                    "--json-output", appsFile.path,
                ]
            )
            if appOut.status == 0, let data = try? Data(contentsOf: appsFile) {
                discovered[index].installedBundleID = Self.parseInstalledMobileBundleID(jsonData: data)
            }
        }

        let loadedIdentities = await loadSigningIdentities()
        let loadedProfiles = await loadProvisioningProfiles()
        if Self.preferredTeamID(from: loadedIdentities) == nil {
            xcodeFallbackTeamID = await loadFallbackXcodeTeamID()
        } else {
            xcodeFallbackTeamID = nil
        }

        devices = discovered
        if let current = selectedDeviceUDID,
           !discovered.contains(where: { $0.udid == current }) {
            selectedDeviceUDID = nil
        }
        if selectedDeviceUDID == nil {
            selectedDeviceUDID = discovered.first?.udid
        }
        identities = loadedIdentities
        profiles = loadedProfiles
        lastUpdatedAt = Date()
        recomputeStatus()
        if !silent, discovered.isEmpty, listOut.status != 0 {
            operationState = .failed(message: "Unable to query devices via devicectl.")
        }
    }

    func selectDevice(udid: String?) {
        selectedDeviceUDID = udid
    }

    func copySideStoreSourceURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.altStoreSourceURL, forType: .string)
    }

    func installOrRefreshSelectedDevice(forcePortalRefresh: Bool = false) {
        guard !isBusy else { return }
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            if self.selectedDevice == nil {
                await self.scanDevices(silent: false)
            }
            guard let target = self.selectedDevice else {
                self.operationState = .failed(
                    message: "No paired iPhone detected. Connect via USB once, trust this Mac, and enable Developer Mode."
                )
                return
            }
            await self.refreshDevice(target, forcePortalRefresh: forcePortalRefresh, isAuto: false)
        }
    }

    // MARK: - Refresh Pipeline

    private func refreshDevice(_ device: PairedDevice, forcePortalRefresh: Bool, isAuto: Bool) async {
        recordAttemptDate(Date(), for: device.udid)
        if !isAuto {
            operationState = .installing(step: "Preparing \(device.name)…")
        }

        if let repoScript = Self.locateInstallScript() {
            var args = [repoScript.path, "--device", device.udid]
            if forcePortalRefresh {
                args.append("--refresh")
            }
            if isAuto {
                args.append("--no-launch")
            }
            if !isAuto {
                operationState = .installing(step: "Building & signing OMG Mobile…")
            }
            let result = await runCommand("/bin/bash", args)
            await scanDevices(silent: true)
            if result.status == 0 {
                let summary = "Updated on \(device.name) (\(device.transport.displayLabel))."
                operationState = .succeeded(summary: summary)
            } else {
                let snippet = Self.conciseErrorSnippet(from: result.combinedText)
                operationState = .failed(message: snippet)
            }
            return
        }

        // Standalone / packaged OMG.app path (no local Xcode checkout):
        // download/verify release IPA from altstore-source.json, ensure a valid
        // profile (renewing via ProvisioningStub if needed), inside-out codesign,
        // and install with devicectl.
        do {
            if !isAuto {
                operationState = .installing(step: "Checking release IPA…")
            }
            let ipaURL = try await ensureVerifiedReleaseIPA()
            try await installPackagedIPA(
                ipaURL,
                to: device,
                forcePortalRefresh: forcePortalRefresh,
                noLaunch: isAuto
            )
            await scanDevices(silent: true)
            operationState = .succeeded(summary: "Updated on \(device.name) (\(device.transport.displayLabel)).")
        } catch {
            await scanDevices(silent: true)
            operationState = .failed(message: error.localizedDescription)
        }
    }

    private func recomputeStatus(now: Date = Date()) {
        let device = selectedDevice
        let team = Self.preferredTeamID(from: identities) ?? xcodeFallbackTeamID ?? activeTeamID
        activeTeamID = team
        let bundle = Self.resolveTargetBundleID(
            explicit: nil,
            installedBundleID: device?.installedBundleID,
            profiles: profiles,
            teamID: team,
            deviceUDID: device?.udid
        )
        activeBundleID = bundle

        guard let team, !team.isEmpty else {
            expiryStatus = .missing(reason: "Add an Apple ID & Apple Development cert in Xcode → Settings → Accounts.")
            return
        }
        if identities.isEmpty {
            expiryStatus = .missing(
                reason: "No local Apple Development certificate yet; click Install / Refresh to create one automatically."
            )
            return
        }
        guard let device else {
            expiryStatus = .unknown
            return
        }
        let certSet = Set(identities.filter { $0.teamID.isEmpty || $0.teamID == team }.map(\.sha1))
        let matched = Self.selectValidProfile(
            profiles: profiles,
            teamID: team,
            bundleID: bundle,
            deviceUDID: device.udid,
            identitySHA1s: certSet,
            now: Date(timeIntervalSince1970: 0)
        )
        expiryStatus = Self.computeExpiryStatus(profile: matched, now: now)
    }

    private func loadFallbackXcodeTeamID() async -> String? {
        let out = await runCommand("/usr/bin/defaults", ["read", "com.apple.dt.Xcode", "IDEProvisioningTeams"])
        guard out.status == 0, let text = String(data: out.stdout, encoding: .utf8) else { return nil }
        return Self.parseXcodeProvisioningTeamID(defaultsOutput: text)
    }

    private func loadSigningIdentities() async -> [SigningIdentity] {
        let identOut = await runCommand("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        guard identOut.status == 0,
              let identText = String(data: identOut.stdout, encoding: .utf8) else {
            return []
        }
        let candidateSHA1s = Self.candidateIdentitySHA1s(from: identText)
        guard !candidateSHA1s.isEmpty else {
            return []
        }
        let certOut = await runCommand("/usr/bin/security", ["find-certificate", "-a", "-Z", "-p"])
        var subjects: [String: String] = [:]
        if certOut.status == 0, let pemText = String(data: certOut.stdout, encoding: .utf8) {
            for (sha1, pem) in Self.splitPEMBlocksWithSHA1(pemText)
                where candidateSHA1s.contains(sha1) && subjects[sha1] == nil {
                let subj = await runOpenSSLSubject(pem: pem)
                if !subj.isEmpty {
                    subjects[sha1] = subj
                }
            }
        }
        return Self.parseCodesigningIdentities(securityOutput: identText, certificateSubjectMap: subjects)
    }

    private func runOpenSSLSubject(pem: String) async -> String {
        let output = await Self.runSubprocess(
            executable: "/usr/bin/openssl",
            arguments: ["x509", "-noout", "-subject"],
            stdinData: Data(pem.utf8),
            timeoutSeconds: 10
        )
        guard output.status == 0 else { return "" }
        return String(data: output.stdout, encoding: .utf8) ?? ""
    }

    private func loadProvisioningProfiles() async -> [ProvisioningProfileInfo] {
        var found: [ProvisioningProfileInfo] = []
        for dir in profileDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for file in files where file.pathExtension == "mobileprovision" {
                let cms = await runCommand("/usr/bin/security", ["cms", "-D", "-i", file.path])
                if cms.status == 0, let parsed = Self.parseProvisioningProfile(plistData: cms.stdout, path: file) {
                    found.append(parsed)
                }
            }
        }
        return found
    }

    private func ensureVerifiedReleaseIPA() async throws -> URL {
        let cacheDir = supportDirectory.appendingPathComponent("mobile-ipa-cache", isDirectory: true)
        var cacheStat = stat()
        if Darwin.lstat(cacheDir.path, &cacheStat) == 0, (cacheStat.st_mode & S_IFMT) == S_IFLNK {
            throw OMGPrivateFileWriter.WriteError.unsafePath
        }
        try FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        guard let feedURL = URL(string: Self.altStoreSourceURL),
              Self.isTrustedAltStoreFeedURL(feedURL) else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid AltStore feed URL.",
            ])
        }
        let urlSession = Self.makeTrustedReleaseURLSession()
        defer { urlSession.finishTasksAndInvalidate() }

        let (feedData, feedResponse) = try await urlSession.data(from: feedURL)
        if let http = feedResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "MobileDeviceProvisioner", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Unable to download altstore-source.json (HTTP \(http.statusCode)).",
            ])
        }
        let feed = try JSONDecoder().decode(AltStoreSourceFeed.self, from: feedData)
        guard let latest = feed.apps.first?.versions.first,
              let downloadURL = URL(string: latest.downloadURL),
              Self.isTrustedReleaseDownloadURL(downloadURL),
              latest.size > 0,
              Self.isValidSHA256Hex(latest.sha256) else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No verified OMG Mobile release version found in altstore-source.json.",
            ])
        }

        let cachedIPA = try Self.validatedCachedIPAURL(
            cacheDir: cacheDir,
            version: latest.version,
            buildVersion: latest.buildVersion
        )
        if FileManager.default.fileExists(atPath: cachedIPA.path),
           Self.verifyFile(cachedIPA, expectedSize: latest.size, expectedSHA256: latest.sha256) {
            return cachedIPA
        }

        let (downloadedTmp, downloadResponse) = try await urlSession.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: downloadedTmp) }
        if let http = downloadResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "MobileDeviceProvisioner", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Unable to download OMG Mobile IPA (HTTP \(http.statusCode)).",
            ])
        }
        guard Self.verifyFile(downloadedTmp, expectedSize: latest.size, expectedSHA256: latest.sha256) else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded IPA failed SHA-256 or byte-size verification.",
            ])
        }
        let downloadedData = try Data(contentsOf: downloadedTmp, options: .mappedIfSafe)
        try OMGPrivateFileWriter.writeAtomically(downloadedData, to: cachedIPA)
        return cachedIPA
    }

    private func installPackagedIPA(
        _ ipaURL: URL,
        to device: PairedDevice,
        forcePortalRefresh: Bool,
        noLaunch: Bool
    ) async throws {
        var resolvedTeam = activeTeamID
            ?? Self.preferredTeamID(from: identities)
            ?? xcodeFallbackTeamID
        if resolvedTeam == nil || resolvedTeam?.isEmpty == true {
            resolvedTeam = await loadFallbackXcodeTeamID()
        }
        guard let team = resolvedTeam, !team.isEmpty else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Missing Apple ID / Development Team in Xcode → Settings → Accounts.",
            ])
        }
        activeTeamID = team
        var bundle = Self.resolveTargetBundleID(
            explicit: nil,
            installedBundleID: device.installedBundleID,
            profiles: profiles,
            teamID: team,
            deviceUDID: device.udid
        )
        activeBundleID = bundle
        var certSHA1s = Set(identities.filter { $0.teamID.isEmpty || $0.teamID == team }.map(\.sha1))
        var profile = (forcePortalRefresh || certSHA1s.isEmpty) ? nil : Self.selectValidProfile(
            profiles: profiles,
            teamID: team,
            bundleID: bundle,
            deviceUDID: device.udid,
            identitySHA1s: certSHA1s,
            now: Date()
        )

        if profile == nil {
            operationState = .installing(step: "Renewing 7-day provisioning profile…")
            do {
                try await renewProvisioningProfileViaStub(
                    teamID: team,
                    bundleID: bundle,
                    deviceUDID: device.udid
                )
            } catch {
                if Self.shouldFallbackToTeamScopedBundleID(
                    errorText: error.localizedDescription,
                    currentBundleID: bundle,
                    installedBundleID: device.installedBundleID
                ) {
                    bundle = "\(Self.defaultBundleID).\(team.lowercased())"
                    activeBundleID = bundle
                    try await renewProvisioningProfileViaStub(
                        teamID: team,
                        bundleID: bundle,
                        deviceUDID: device.udid
                    )
                } else {
                    throw error
                }
            }
            let updatedIdentities = await loadSigningIdentities()
            let updatedProfiles = await loadProvisioningProfiles()
            identities = updatedIdentities
            profiles = updatedProfiles
            certSHA1s = Set(updatedIdentities.filter { $0.teamID.isEmpty || $0.teamID == team }.map(\.sha1))
            profile = Self.selectValidProfile(
                profiles: updatedProfiles,
                teamID: team,
                bundleID: bundle,
                deviceUDID: device.udid,
                identitySHA1s: certSHA1s,
                now: Date()
            )
        }

        guard let activeProfile = profile,
              let signSHA1 = activeProfile.certificateSHA1s.first(where: { certSHA1s.contains($0) })
                ?? certSHA1s.first else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unable to find valid provisioning profile and certificate for \(bundle).",
            ])
        }

        operationState = .installing(step: "Signing OMG Mobile inside-out…")
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-resign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let extractDir = workDir.appendingPathComponent("extract", isDirectory: true)
        let unzipOut = await runCommand("/usr/bin/ditto", ["-xk", ipaURL.path, extractDir.path])
        guard unzipOut.status == 0 else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to unpack IPA: \(Self.conciseErrorSnippet(from: unzipOut.combinedText))",
            ])
        }
        let appURL = extractDir.appendingPathComponent("Payload/OMGMobile.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "OMGMobile.app missing inside downloaded IPA.",
            ])
        }

        try Self.updateBundleIdentifiers(in: appURL, to: bundle)
        Self.removeCodeSignatures(under: appURL)
        let embeddedProfile = appURL.appendingPathComponent("embedded.mobileprovision")
        try? FileManager.default.removeItem(at: embeddedProfile)
        try FileManager.default.copyItem(at: activeProfile.path, to: embeddedProfile)

        let entitlementsURL = workDir.appendingPathComponent("entitlements.plist")
        let resolvedEntitlements = try Self.resolvedEntitlementsData(for: activeProfile, bundleID: bundle)
        try OMGPrivateFileWriter.writeAtomically(resolvedEntitlements, to: entitlementsURL)

        for nested in Self.nestedSignableTargets(in: appURL) {
            let res = await runCommand(
                "/usr/bin/codesign",
                ["--force", "--sign", signSHA1, "--timestamp=none", nested.path]
            )
            if res.status != 0 {
                throw NSError(domain: "MobileDeviceProvisioner", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to sign \(nested.lastPathComponent): \(res.combinedText)",
                ])
            }
        }
        let appSign = await runCommand(
            "/usr/bin/codesign",
            [
                "--force", "--sign", signSHA1,
                "--entitlements", entitlementsURL.path,
                "--generate-entitlement-der",
                "--timestamp=none",
                appURL.path,
            ]
        )
        guard appSign.status == 0 else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Failed to sign OMGMobile.app: \(appSign.combinedText)",
            ])
        }

        operationState = .installing(step: "Installing onto \(device.name)…")
        let installRes = await runCommand(
            "/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", device.coreDeviceID, "--timeout", "60", appURL.path]
        )
        guard installRes.status == 0 else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 10, userInfo: [
                NSLocalizedDescriptionKey: Self.conciseErrorSnippet(from: installRes.combinedText),
            ])
        }
        if !noLaunch {
            _ = await runCommand(
                "/usr/bin/xcrun",
                ["devicectl", "device", "process", "launch", "--device", device.coreDeviceID, "--timeout", "30", bundle]
            )
        }
    }

    private func renewProvisioningProfileViaStub(teamID: String, bundleID: String, deviceUDID: String) async throws {
        try Self.validateProvisioningInputs(teamID: teamID, bundleID: bundleID, deviceUDID: deviceUDID)
        let stubDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-prov-stub-\(UUID().uuidString)", isDirectory: true)
        let projDir = stubDir.appendingPathComponent("StubApp.xcodeproj", isDirectory: true)
        let srcDir = stubDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stubDir) }

        try Data("int main(void) { return 0; }\n".utf8)
            .write(to: srcDir.appendingPathComponent("main.c"))
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
          <key>CFBundleExecutable</key><string>StubApp</string>
          <key>CFBundleName</key><string>StubApp</string>
          <key>CFBundleVersion</key><string>1</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
        </dict></plist>
        """
        try Data(infoPlist.utf8).write(to: srcDir.appendingPathComponent("Info.plist"))
        let pbxproj = """
        // !$*UTF8*$!
        {
          archiveVersion = 1; classes = {}; objectVersion = 56;
          objects = {
            AA01 = { isa = PBXBuildFile; fileRef = AA02; };
            AA02 = { isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = Sources/main.c; sourceTree = "<group>"; };
            AA03 = { isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = StubApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
            AA04 = { isa = PBXGroup; children = (AA02, AA03); sourceTree = "<group>"; };
            AA05 = { isa = PBXNativeTarget; buildConfigurationList = AA08; buildPhases = (AA06); buildRules = (); dependencies = (); name = StubApp; productName = StubApp; productReference = AA03; productType = "com.apple.product-type.application"; };
            AA06 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (AA01); runOnlyForDeploymentPostprocessing = 0; };
            AA07 = { isa = PBXProject; attributes = { LastUpgradeCheck = 1500; }; buildConfigurationList = AA09; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; mainGroup = AA04; productRefGroup = AA04; projectDirPath = ""; projectRoot = ""; targets = (AA05); };
            AA08 = { isa = XCConfigurationList; buildConfigurations = (AA10); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
            AA09 = { isa = XCConfigurationList; buildConfigurations = (AA11); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
            AA10 = { isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = "\(teamID)"; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Sources/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = "\(bundleID)"; PRODUCT_NAME = StubApp; SDKROOT = iphoneos; }; name = Release; };
            AA11 = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
          };
          rootObject = AA07;
        }
        """
        try Data(pbxproj.utf8).write(to: projDir.appendingPathComponent("project.pbxproj"))

        let res = await runCommand(
            "/usr/bin/xcodebuild",
            [
                "-project", projDir.path,
                "-target", "StubApp",
                "-configuration", "Release",
                "-destination", "id=\(deviceUDID)",
                "-derivedDataPath", stubDir.appendingPathComponent("derived").path,
                "-allowProvisioningUpdates",
                "build",
            ]
        )
        guard res.status == 0 else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Xcode profile renewal failed: \(Self.conciseErrorSnippet(from: res.combinedText))",
            ])
        }
    }

    // MARK: - Pure Parsers & Helpers (Unit-Testable)

    static func parseDevicectlDevices(jsonData: Data) -> [PairedDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let items = result["devices"] as? [[String: Any]] else {
            return []
        }
        var parsed: [PairedDevice] = []
        for item in items {
            let props = item["properties"] as? [String: Any] ?? [:]
            let hw = (props["hardware"] as? [String: Any])
                ?? (item["hardwareProperties"] as? [String: Any])
                ?? [:]
            let devProps = item["deviceProperties"] as? [String: Any] ?? [:]
            let conn = (props["connection"] as? [String: Any])
                ?? (item["connectionProperties"] as? [String: Any])
                ?? [:]

            let udid = (hw["udid"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = (item["identifier"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalUDID = udid.isEmpty ? identifier : udid
            let coreID = identifier.isEmpty ? udid : identifier
            guard !finalUDID.isEmpty else { continue }

            let reality = ((hw["reality"] as? String)
                ?? (item["reality"] as? String)
                ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !reality.isEmpty && reality != "physical" { continue }

            let rawTransport = ((conn["transportType"] as? String)
                ?? (conn["interfaceType"] as? String)
                ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if rawTransport == "samemachine" { continue }

            let pairingState = (conn["pairingState"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if pairingState == "unpaired" { continue }

            let platform = hw["platform"] as? String ?? ""
            let devType = (hw["deviceType"] as? String ?? "").lowercased()
            let isIOS = platform.contains("iOS")
                || platform.contains("iPadOS")
                || devType == "iphone"
                || devType == "ipad"
                || (platform.isEmpty && devType.isEmpty)
            guard isIOS else { continue }

            let rawName = (item["name"] as? String)
                ?? (devProps["name"] as? String)
                ?? (props["name"] as? String)
                ?? finalUDID
            let model = (hw["marketingName"] as? String) ?? (hw["productType"] as? String) ?? ""
            let osVer = (devProps["osVersionNumber"] as? String)
                ?? (props["osVersionNumber"] as? String)
                ?? ""
            let transport: Transport
            if rawTransport.contains("wired") || rawTransport.contains("usb") {
                transport = .wired
            } else if rawTransport.contains("localnetwork") || rawTransport.contains("wifi") || rawTransport.contains("network") {
                transport = .localNetwork
            } else {
                transport = .other(rawTransport)
            }

            parsed.append(PairedDevice(
                udid: finalUDID,
                coreDeviceID: coreID,
                name: rawName,
                model: model,
                osVersion: osVer,
                transport: transport,
                installedBundleID: nil
            ))
        }
        return parsed.sorted { lhs, rhs in
            let lWired = lhs.transport == .wired
            let rWired = rhs.transport == .wired
            if lWired != rWired { return lWired }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func parseInstalledMobileBundleID(jsonData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else {
            return nil
        }
        var found: [String] = []
        for app in apps {
            let props = app["properties"] as? [String: Any] ?? [:]
            let bid = (app["bundleIdentifier"] as? String)
                ?? (props["bundleIdentifier"] as? String)
                ?? ""
            if bid.hasPrefix(defaultBundleID) {
                found.append(bid)
            }
        }
        if found.contains(defaultBundleID) {
            return defaultBundleID
        }
        return found.sorted().first
    }

    static func parseProvisioningProfile(plistData: Data, path: URL) -> ProvisioningProfileInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
            let teams = plist["TeamIdentifier"] as? [String],
            let teamID = teams.first, !teamID.isEmpty,
            let uuid = plist["UUID"] as? String,
            let expiresAt = plist["ExpirationDate"] as? Date,
            let entitlements = plist["Entitlements"] as? [String: Any],
            let appID = entitlements["application-identifier"] as? String else {
            return nil
        }
        let prefix = "\(teamID)."
        guard appID.hasPrefix(prefix) else { return nil }
        let bundleID = String(appID.dropFirst(prefix.count))
        let provisioned = Set(plist["ProvisionedDevices"] as? [String] ?? [])
        let allDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        var certSHA1s: Set<String> = []
        for certData in plist["DeveloperCertificates"] as? [Data] ?? [] {
            let digest = Insecure.SHA1.hash(data: certData)
            certSHA1s.insert(digest.map { String(format: "%02X", $0) }.joined())
        }
        let entData = (try? PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )) ?? Data()
        return ProvisioningProfileInfo(
            uuid: uuid,
            path: path,
            teamID: teamID,
            bundleID: bundleID,
            isWildcard: bundleID == "*",
            expiresAt: expiresAt,
            provisionedUDIDs: provisioned,
            provisionsAllDevices: allDevices,
            certificateSHA1s: certSHA1s,
            entitlementsData: entData
        )
    }

    static func candidateIdentitySHA1s(from securityOutput: String) -> Set<String> {
        var sha1s: Set<String> = []
        for rawLine in securityOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard !line.contains("CSSMERR_"), !line.contains("REVOKED") else { continue }
            guard line.contains("Apple Development") || line.contains("iPhone Developer") else { continue }
            guard let sha1Range = line.range(of: #"\b[0-9A-Fa-f]{40}\b"#, options: .regularExpression) else {
                continue
            }
            sha1s.insert(String(line[sha1Range]).uppercased())
        }
        return sha1s
    }

    static func parseXcodeProvisioningTeamID(defaultsOutput: String) -> String? {
        // Prefer non-free team if Xcode lists multiple provisioning teams, else take first valid 10-char team ID.
        var paidTeams: [String] = []
        var allTeams: [String] = []
        let blocks = defaultsOutput.components(separatedBy: "{")
        for block in blocks {
            guard let range = block.range(
                of: #"teamID\s*=\s*"?([A-Z0-9]{10})"?\s*;"#,
                options: .regularExpression
            ) else { continue }
            let fragment = String(block[range])
            guard let idRange = fragment.range(of: #"[A-Z0-9]{10}"#, options: .regularExpression) else {
                continue
            }
            let team = String(fragment[idRange])
            if !allTeams.contains(team) {
                allTeams.append(team)
            }
            if block.range(of: #"isFreeProvisioningTeam\s*=\s*0\s*;"#, options: .regularExpression) != nil,
               !paidTeams.contains(team) {
                paidTeams.append(team)
            }
        }
        return paidTeams.first ?? allTeams.first
    }

    static func shouldFallbackToTeamScopedBundleID(
        errorText: String,
        currentBundleID: String,
        installedBundleID: String?
    ) -> Bool {
        guard installedBundleID == nil, currentBundleID == defaultBundleID else { return false }
        let markers = [
            "cannot be registered",
            "is not available",
            "already registered",
            "Failed to register bundle identifier",
            "No profiles for '\(defaultBundleID)'",
        ]
        return markers.contains { errorText.localizedCaseInsensitiveContains($0) }
    }

    static func resolvedEntitlementsData(for profile: ProvisioningProfileInfo, bundleID: String) throws -> Data {
        guard var entitlements = try PropertyListSerialization.propertyList(
            from: profile.entitlementsData,
            options: [.mutableContainers],
            format: nil
        ) as? [String: Any] else {
            return profile.entitlementsData
        }
        let currentAppID = entitlements["application-identifier"] as? String ?? ""
        if profile.isWildcard || currentAppID.hasSuffix(".*") {
            entitlements["application-identifier"] = "\(profile.teamID).\(bundleID)"
            return try PropertyListSerialization.data(
                fromPropertyList: entitlements,
                format: .xml,
                options: 0
            )
        }
        return profile.entitlementsData
    }

    nonisolated static func isSafeVersionToken(_ token: String) -> Bool {
        guard !token.contains("..") else { return false }
        return token.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#, options: .regularExpression) != nil
    }

    nonisolated static func isValidSHA256Hex(_ hex: String) -> Bool {
        hex.range(of: #"^[0-9A-Fa-f]{64}$"#, options: .regularExpression) != nil
    }

    nonisolated static func isTrustedAltStoreFeedURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.host?.lowercased() == "github.com",
              !components.path.contains("..") else {
            return false
        }
        return components.path == "/jischeng/oh-my-ghostty/releases/latest/download/altstore-source.json"
            || (components.path.hasPrefix("/jischeng/oh-my-ghostty/releases/download/") &&
                components.path.hasSuffix("/altstore-source.json"))
    }

    nonisolated static func isTrustedReleaseDownloadURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !components.path.contains("..") else {
            return false
        }
        if host == "github.com" {
            return components.query == nil &&
                components.path.hasPrefix("/jischeng/oh-my-ghostty/releases/download/") &&
                components.path.hasSuffix(".ipa")
        }
        return false
    }

    nonisolated static func isTrustedRedirectTargetURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !components.path.contains("..") else {
            return false
        }
        if host == "github.com" {
            return components.path.hasPrefix("/jischeng/oh-my-ghostty/releases/")
        }
        return host == "objects.githubusercontent.com" || host == "release-assets.githubusercontent.com"
    }

    nonisolated static func validatedCachedIPAURL(
        cacheDir: URL,
        version: String,
        buildVersion: String
    ) throws -> URL {
        guard isSafeVersionToken(version), isSafeVersionToken(buildVersion) else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Invalid version metadata in altstore-source.json.",
            ])
        }
        let fileName = "OMG-Mobile-\(version)-b\(buildVersion).ipa"
        let candidate = cacheDir.appendingPathComponent(fileName, isDirectory: false)
        guard candidate.standardizedFileURL.deletingLastPathComponent() == cacheDir.standardizedFileURL else {
            throw OMGPrivateFileWriter.WriteError.unsafePath
        }
        var st = stat()
        if Darwin.lstat(candidate.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw OMGPrivateFileWriter.WriteError.unsafePath
        }
        return candidate
    }

    nonisolated static func validateProvisioningInputs(
        teamID: String,
        bundleID: String,
        deviceUDID: String
    ) throws {
        guard teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Apple Developer Team ID.",
            ])
        }
        guard bundleID.count <= 155,
              bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Invalid iOS bundle identifier.",
            ])
        }
        guard deviceUDID.range(of: #"^[A-Za-z0-9-]{4,64}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "MobileDeviceProvisioner", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "Invalid paired device UDID.",
            ])
        }
    }

    private final class TrustedReleaseRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let nextURL = request.url,
                  MobileDeviceProvisioner.isTrustedRedirectTargetURL(nextURL) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private static func makeTrustedReleaseURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: TrustedReleaseRedirectDelegate(), delegateQueue: nil)
    }

    static func parseCodesigningIdentities(
        securityOutput: String,
        certificateSubjectMap: [String: String]
    ) -> [SigningIdentity] {
        var result: [SigningIdentity] = []
        for rawLine in securityOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard !line.contains("CSSMERR_"), !line.contains("REVOKED") else { continue }
            guard line.contains("Apple Development") || line.contains("iPhone Developer") else { continue }
            guard let sha1Range = line.range(of: #"\b[0-9A-Fa-f]{40}\b"#, options: .regularExpression),
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else {
                continue
            }
            let sha1 = String(line[sha1Range]).uppercased()
            let commonName = String(line[line.index(after: firstQuote)..<lastQuote])
            let subject = certificateSubjectMap[sha1] ?? ""
            let teamID = extractTeamOU(from: subject) ?? extractParenthesizedTeam(from: commonName) ?? ""
            result.append(SigningIdentity(sha1: sha1, commonName: commonName, teamID: teamID))
        }
        return result
    }

    static func resolveTargetBundleID(
        explicit: String?,
        installedBundleID: String?,
        profiles: [ProvisioningProfileInfo],
        teamID: String?,
        deviceUDID: String?
    ) -> String {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        if let installedBundleID, !installedBundleID.isEmpty {
            return installedBundleID
        }
        let matchingProfiles = profiles.filter { profile in
            guard profile.bundleID.hasPrefix(defaultBundleID) else { return false }
            if let teamID, profile.teamID != teamID { return false }
            if let deviceUDID, !profile.provisionsAllDevices, !profile.provisionedUDIDs.contains(deviceUDID) {
                return false
            }
            return true
        }
        if matchingProfiles.contains(where: { $0.bundleID == defaultBundleID }) {
            return defaultBundleID
        }
        if let existing = matchingProfiles.map(\.bundleID).sorted().first {
            return existing
        }
        return defaultBundleID
    }

    static func selectValidProfile(
        profiles: [ProvisioningProfileInfo],
        teamID: String,
        bundleID: String,
        deviceUDID: String,
        identitySHA1s: Set<String>,
        now: Date
    ) -> ProvisioningProfileInfo? {
        let eligible = profiles.filter { profile in
            guard profile.teamID == teamID,
                  profile.expiresAt.timeIntervalSince(now) > 60,
                  profile.provisionsAllDevices || profile.provisionedUDIDs.contains(deviceUDID),
                  profile.bundleID == bundleID || profile.isWildcard else {
                return false
            }
            if !identitySHA1s.isEmpty && !profile.certificateSHA1s.isEmpty {
                return !profile.certificateSHA1s.isDisjoint(with: identitySHA1s)
            }
            return true
        }
        let exact = eligible.filter { !$0.isWildcard }
        let pool = exact.isEmpty ? eligible : exact
        return pool.max(by: { $0.expiresAt < $1.expiresAt })
    }

    static func computeExpiryStatus(profile: ProvisioningProfileInfo?, now: Date) -> ExpiryStatus {
        guard let profile else {
            return .missing(reason: "No provisioning profile installed yet.")
        }
        let remaining = profile.expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            return .expired(expiredAt: profile.expiresAt)
        }
        if remaining < Self.expiringThresholdSeconds {
            return .expiringSoon(expiresAt: profile.expiresAt, remaining: remaining)
        }
        return .valid(expiresAt: profile.expiresAt, remaining: remaining)
    }

    // MARK: - Private Utilities

    private static func preferredTeamID(from identities: [SigningIdentity]) -> String? {
        identities.first(where: { !$0.teamID.isEmpty })?.teamID
    }

    private static func extractTeamOU(from subject: String) -> String? {
        guard let range = subject.range(of: #"\bOU\s*=\s*([A-Z0-9]{10})\b"#, options: .regularExpression) else {
            return nil
        }
        let fragment = String(subject[range])
        return fragment.split(separator: "=").last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func extractParenthesizedTeam(from commonName: String) -> String? {
        guard let open = commonName.lastIndex(of: "("),
              let close = commonName.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let inside = String(commonName[commonName.index(after: open)..<close])
        guard inside.count == 10, inside.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
            return nil
        }
        return inside
    }

    private static func splitPEMBlocksWithSHA1(_ output: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var currentSHA1 = ""
        var inPEM = false
        var lines: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("SHA-1 hash:") {
                currentSHA1 = line.replacingOccurrences(of: "SHA-1 hash:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
            } else if line.contains("-----BEGIN CERTIFICATE-----") {
                inPEM = true
                lines = [line]
            } else if line.contains("-----END CERTIFICATE-----"), inPEM {
                lines.append(line)
                if !currentSHA1.isEmpty {
                    result.append((currentSHA1, lines.joined(separator: "\n") + "\n"))
                }
                inPEM = false
                currentSHA1 = ""
                lines = []
            } else if inPEM {
                lines.append(line)
            }
        }
        return result
    }

    private static func verifyFile(_ url: URL, expectedSize: Int, expectedSHA256: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue == expectedSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256.lowercased()
    }

    private static func updateBundleIdentifiers(in appURL: URL, to bundleID: String) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        if var info = try PropertyListSerialization.propertyList(
            from: infoData, options: [.mutableContainers], format: nil
        ) as? [String: Any],
           info["CFBundleIdentifier"] as? String != bundleID {
            info["CFBundleIdentifier"] = bundleID
            if var urlTypes = info["CFBundleURLTypes"] as? [[String: Any]], !urlTypes.isEmpty {
                urlTypes[0]["CFBundleURLName"] = bundleID
                info["CFBundleURLTypes"] = urlTypes
            }
            let out = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try out.write(to: infoURL)
        }
        let streamPlist = appURL.appendingPathComponent("Frameworks/TermioStream.framework/Info.plist")
        if FileManager.default.fileExists(atPath: streamPlist.path) {
            let sData = try Data(contentsOf: streamPlist)
            if var sInfo = try PropertyListSerialization.propertyList(
                from: sData, options: [.mutableContainers], format: nil
            ) as? [String: Any],
               sInfo["CFBundleIdentifier"] as? String != "\(bundleID).stream" {
                sInfo["CFBundleIdentifier"] = "\(bundleID).stream"
                let out = try PropertyListSerialization.data(fromPropertyList: sInfo, format: .binary, options: 0)
                try out.write(to: streamPlist)
            }
        }
    }

    private static func removeCodeSignatures(under appURL: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) else { return }
        var targets: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "_CodeSignature" {
            targets.append(url)
        }
        for url in targets {
            try? fm.removeItem(at: url)
        }
    }

    private static func nestedSignableTargets(in appURL: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        for sub in ["Frameworks", "PlugIns"] {
            let root = appURL.appendingPathComponent(sub)
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let item as URL in enumerator {
                let ext = item.pathExtension
                if ext == "dylib" || ext == "framework" || ext == "appex" {
                    results.append(item)
                }
            }
        }
        return results.sorted { $0.path.count > $1.path.count }
    }

    nonisolated static func locateInstallScript(
        isDevelopment: Bool = OMGApplicationEnvironment.isDevelopment,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        expectedUID: uid_t = getuid()
    ) -> URL? {
        guard isDevelopment else { return nil }
        var candidateRepoRoots: [URL] = []
        if let envDir = environment["OMG_IOS_SOURCE_DIR"], !envDir.isEmpty {
            let iosURL = URL(fileURLWithPath: envDir, isDirectory: true)
            candidateRepoRoots.append(iosURL.deletingLastPathComponent())
        }

        var cursor = bundleURL
        for _ in 0..<8 {
            candidateRepoRoots.append(cursor)
            cursor.deleteLastPathComponent()
        }

        var seen = Set<String>()
        for repoRoot in candidateRepoRoots {
            let standardized = repoRoot.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            guard isVerifiedDevelopmentRepoRoot(standardized, expectedUID: expectedUID) else { continue }
            let script = standardized.appendingPathComponent("ios/scripts/install-to-iphone.sh")
            if isSafeOwnedRegularExecutable(script, expectedUID: expectedUID) {
                return script
            }
        }
        return nil
    }

    nonisolated private static func isVerifiedDevelopmentRepoRoot(_ repoRoot: URL, expectedUID: uid_t) -> Bool {
        var rootStat = stat()
        guard Darwin.lstat(repoRoot.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              rootStat.st_uid == expectedUID,
              (rootStat.st_mode & 0o022) == 0 else {
            return false
        }
        let iosDir = repoRoot.appendingPathComponent("ios")
        let scriptsDir = repoRoot.appendingPathComponent("ios/scripts")
        for dir in [iosDir, scriptsDir] {
            var dirStat = stat()
            guard Darwin.lstat(dir.path, &dirStat) == 0,
                  (dirStat.st_mode & S_IFMT) == S_IFDIR,
                  dirStat.st_uid == expectedUID,
                  (dirStat.st_mode & 0o022) == 0 else {
                return false
            }
        }
        let requiredFiles = [
            repoRoot.appendingPathComponent("build.zig"),
            repoRoot.appendingPathComponent("ios/project.yml"),
            repoRoot.appendingPathComponent("macos/Ghostty.xcodeproj/project.pbxproj"),
        ]
        for marker in requiredFiles {
            var markerStat = stat()
            guard Darwin.lstat(marker.path, &markerStat) == 0,
                  (markerStat.st_mode & S_IFMT) == S_IFREG,
                  markerStat.st_uid == expectedUID else {
                return false
            }
        }
        return true
    }

    nonisolated private static func isSafeOwnedRegularExecutable(_ url: URL, expectedUID: uid_t) -> Bool {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == expectedUID,
              (st.st_mode & 0o022) == 0,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return false
        }
        return true
    }

    private static func conciseErrorSnippet(from text: String) -> String {
        let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        if let important = lines.last(where: {
            $0.localizedCaseInsensitiveContains("error:") || $0.localizedCaseInsensitiveContains("failed")
        }) {
            return important
        }
        return lines.last ?? "Installation failed."
    }

    private static func loadBoolFlag(at url: URL, defaultValue: Bool) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return defaultValue
        }
        if text == "1" || text.lowercased() == "true" { return true }
        if text == "0" || text.lowercased() == "false" { return false }
        return defaultValue
    }

    private static func saveBoolFlag(_ enabled: Bool, at url: URL) {
        try? OMGPrivateFileWriter.writeAtomically(Data((enabled ? "1\n" : "0\n").utf8), to: url)
    }

    private func loadLastAttemptDate(for udid: String) -> Date? {
        guard let data = try? Data(contentsOf: attemptsFile),
              let history = try? JSONDecoder().decode(AttemptHistory.self, from: data),
              let epoch = history.lastAttemptByUDID[udid] else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    private func recordAttemptDate(_ date: Date, for udid: String) {
        var map: [String: TimeInterval] = [:]
        if let data = try? Data(contentsOf: attemptsFile),
           let existing = try? JSONDecoder().decode(AttemptHistory.self, from: data) {
            map = existing.lastAttemptByUDID
        }
        map[udid] = date.timeIntervalSince1970
        if let encoded = try? JSONEncoder().encode(AttemptHistory(lastAttemptByUDID: map)) {
            try? OMGPrivateFileWriter.writeAtomically(encoded, to: attemptsFile)
        }
    }

    private final class SubprocessController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var aborted = false

        func attach(_ proc: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if aborted {
                return false
            }
            process = proc
            return true
        }

        var wasAborted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return aborted
        }

        func abort() {
            let proc: Process? = {
                lock.lock()
                defer { lock.unlock() }
                aborted = true
                return process
            }()
            guard let proc, proc.isRunning else { return }
            let pid = proc.processIdentifier
            proc.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning, pid > 1 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
        }
    }

    nonisolated static func runSubprocess(
        executable: String,
        arguments: [String],
        stdinData: Data? = nil,
        timeoutSeconds: TimeInterval = 300
    ) async -> CommandOutput {
        let controller = SubprocessController()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    if controller.wasAborted {
                        continuation.resume(returning: CommandOutput(
                            status: -1,
                            stdout: Data(),
                            stderr: Data("Cancelled".utf8)
                        ))
                        return
                    }

                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: executable)
                    proc.arguments = arguments
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe

                    var inPipe: Pipe?
                    if stdinData != nil {
                        let pipe = Pipe()
                        proc.standardInput = pipe
                        inPipe = pipe
                    } else {
                        proc.standardInput = FileHandle.nullDevice
                    }

                    guard controller.attach(proc) else {
                        continuation.resume(returning: CommandOutput(
                            status: -1,
                            stdout: Data(),
                            stderr: Data("Cancelled".utf8)
                        ))
                        return
                    }

                    let watchdog = DispatchWorkItem {
                        controller.abort()
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + max(0.05, timeoutSeconds),
                        execute: watchdog
                    )

                    do {
                        try proc.run()
                        if controller.wasAborted {
                            controller.abort()
                        }

                        if let stdinData, let inPipe {
                            DispatchQueue.global(qos: .utility).async {
                                try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
                                try? inPipe.fileHandleForWriting.close()
                            }
                        }

                        let group = DispatchGroup()
                        let dataLock = NSLock()
                        var outData = Data()
                        var errData = Data()

                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            let bytes = outPipe.fileHandleForReading.readDataToEndOfFile()
                            dataLock.lock()
                            outData = bytes
                            dataLock.unlock()
                            group.leave()
                        }

                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            let bytes = errPipe.fileHandleForReading.readDataToEndOfFile()
                            dataLock.lock()
                            errData = bytes
                            dataLock.unlock()
                            group.leave()
                        }

                        proc.waitUntilExit()
                        watchdog.cancel()
                        group.wait()

                        dataLock.lock()
                        let finalOut = outData
                        let finalErr = errData
                        dataLock.unlock()

                        let status: Int32 = controller.wasAborted ? -1 : proc.terminationStatus
                        continuation.resume(returning: CommandOutput(
                            status: status,
                            stdout: finalOut,
                            stderr: finalErr
                        ))
                    } catch {
                        watchdog.cancel()
                        try? inPipe?.fileHandleForWriting.close()
                        continuation.resume(returning: CommandOutput(
                            status: -1,
                            stdout: Data(),
                            stderr: Data(error.localizedDescription.utf8)
                        ))
                    }
                }
            }
        } onCancel: {
            controller.abort()
        }
    }

    private static let defaultRunCommand: CommandRunner = { executable, arguments in
        await runSubprocess(executable: executable, arguments: arguments, timeoutSeconds: 300)
    }
}
