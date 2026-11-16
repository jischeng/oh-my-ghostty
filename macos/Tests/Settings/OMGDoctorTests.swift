import AppKit
import CryptoKit
import Foundation
import Security
import Testing
@testable import Ghostty

@MainActor
struct OMGDoctorTests {
    @Test func doctorDetectsMissingAccessibilityPermissionForGlobalKeybindsAndInvokesSelfHeal() async {
        var trusted = false
        var grantCalls = 0
        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { true },
            isAccessibilityTrusted: { trusted },
            isEventTapEnabled: { trusted },
            requestAccessibility: {
                grantCalls += 1
                trusted = true
                return true
            },
            resourcesURL: nil,
            homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sshControlDirectoryPath: "/tmp/nonexistent-\(UUID().uuidString)",
            surfaceCounter: { .init(visible: 2, occluded: 1) },
            residentMemoryProvider: { 128 * 1_024 * 1_024 }
        )

        let doctor = OMGDoctorService(dependencies: deps)
        await doctor.refresh()

        #expect(doctor.report.overallStatus == .warning)
        #expect(doctor.report.accessibility.status == .warning)
        #expect(doctor.report.accessibility.needsGrantAction)
        #expect(doctor.report.accessibility.summary(strings: SettingsStrings(language: .english)).contains("Accessibility"))
        #expect(doctor.report.accessibility.summary(strings: SettingsStrings(language: .simplifiedChinese)).contains("辅助功能"))

        #expect(doctor.grantAccessibilityPermission())
        await doctor.refresh()
        #expect(grantCalls == 1)
        #expect(doctor.report.accessibility.status == .healthy)
        #expect(!doctor.report.accessibility.needsGrantAction)
        #expect(doctor.report.overallStatus == .healthy)
    }

    @Test func doctorAuditsRuntimeSessionsSSHControlDirectoryAndAgentBackups() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-audit-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let runtimeDir = resources.appendingPathComponent("session-runtime", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let sshDir = root.appendingPathComponent("ssh-mux", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".omg/run/stateA/sessions"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let helperURL = runtimeDir.appendingPathComponent("omgd")
        try "#!/bin/sh\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try "rev-doctor-test\n".write(to: runtimeDir.appendingPathComponent("revision"), atomically: true, encoding: .utf8)

        let sessionsDir = home.appendingPathComponent(".omg/run/stateA/sessions")
        try Data("{\"ended\":null}".utf8).write(to: sessionsDir.appendingPathComponent("active.json"))
        try Data("{\"ended\":\"exited\"}".utf8).write(to: sessionsDir.appendingPathComponent("exited.json"))
        try Data("{\"ended\":\"lost\"}".utf8).write(to: sessionsDir.appendingPathComponent("lost.json"))
        try Data("{\"ended\":null}".utf8).write(to: sessionsDir.appendingPathComponent("closed.json"))
        try Data().write(to: sessionsDir.appendingPathComponent("closed.closed"))

        // Create one secure 0600 backup and one insecure 0644 backup.
        let secureBak = home.appendingPathComponent(".claude/settings.json.omg.bak")
        try OMGPrivateFileWriter.writeAtomically(Data("{}".utf8), to: secureBak)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".qwen"), withIntermediateDirectories: true)
        let insecureBak = home.appendingPathComponent(".qwen/settings.json.omg.bak")
        try Data("{}".utf8).write(to: insecureBak)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: insecureBak.path)

        let suiteName = "OMGDoctorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agentManager = AgentIntegrationManager(
            defaults: defaults,
            homeURL: home,
            snapshots: [
                AgentIntegrationManager.localID: AgentIntegrationSnapshot(
                    hooks: [.claude: .current],
                    cli: [.claude: .init(version: "1.0.0", path: "/usr/local/bin/claude")]
                ),
            ],
            connectionTargets: { [] },
            registry: registry
        )

        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { false },
            isAccessibilityTrusted: { true },
            isEventTapEnabled: { false },
            resourcesURL: resources,
            homeDirectory: home,
            sshControlDirectoryPath: sshDir.path,
            agentManager: agentManager,
            surfaceCounter: { .init(visible: 3, occluded: 2) },
            residentMemoryProvider: { 256 * 1_024 * 1_024 }
        )
        let doctor = OMGDoctorService(dependencies: deps)
        await doctor.refresh()

        #expect(doctor.report.runtimeSSH.omgdAvailable)
        #expect(doctor.report.runtimeSSH.omgdRevision == "rev-doctor-test")
        #expect(doctor.report.runtimeSSH.activeRuntimeSessions == 1)
        #expect(doctor.report.runtimeSSH.totalRuntimeSessionRecords == 4)
        #expect(!doctor.report.runtimeSSH.sshControlDirectoryHealthy)
        #expect(doctor.report.runtimeSSH.status == .warning)

        #expect(doctor.report.agentBackups.detectedCLICount == 1)
        #expect(doctor.report.agentBackups.installedHookCount == 1)
        #expect(doctor.report.agentBackups.backupFileCount == 2)
        #expect(doctor.report.agentBackups.insecureBackupCount == 1)
        #expect(doctor.report.agentBackups.status == .warning)

        // Tighten permissions to 0700 and 0600 -> everything turns healthy!
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: insecureBak.path)
        await doctor.refresh()

        #expect(doctor.report.runtimeSSH.sshControlDirectoryHealthy)
        #expect(doctor.report.runtimeSSH.status == .healthy)
        #expect(doctor.report.agentBackups.insecureBackupCount == 0)
        #expect(doctor.report.agentBackups.status == .healthy)
        #expect(doctor.report.overallStatus == .healthy)
    }

    @Test func doctorReclaimsIdleEditorWebViewsWhilePreservingOpenDocumentsForRehydration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("main.swift")
        try "print(\"hello\")\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = EditorWorkspaceStore()
        let ownerID = UUID()
        let surfaceID = UUID()
        let workspace = store.workspace(for: ownerID, surfaceID: surfaceID)
        defer { store.remove(surfaceIDs: [surfaceID]) }

        let fs = LocalWorkspaceFilesystem(workingDirectory: tempDir.path)
        workspace.open(path: fileURL.path, filesystem: fs)
        for _ in 0..<40 where workspace.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(workspace.documents.count == 1)
        _ = workspace.workbenchController.ensureWebView()
        #expect(workspace.workbenchController.webView != nil)
        #expect(store.resourceMetrics.activeWebViews == 1)
        #expect(store.resourceMetrics.idleReclaimableWebViews == 0)

        // Hide the editor pane -> its WebView becomes idle-reclaimable!
        workspace.isVisible = false
        #expect(store.resourceMetrics.idleReclaimableWebViews == 1)

        let lspManager = EditorLSPManager(serverCommands: [:])
        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { false },
            isAccessibilityTrusted: { true },
            isEventTapEnabled: { false },
            resourcesURL: nil,
            homeDirectory: tempDir,
            sshControlDirectoryPath: tempDir.appendingPathComponent("no-ssh").path,
            workspaceStore: store,
            lspManager: lspManager,
            surfaceCounter: { .init(visible: 1, occluded: 0) },
            residentMemoryProvider: { 64 * 1_024 * 1_024 }
        )
        let doctor = OMGDoctorService(dependencies: deps)
        await doctor.refresh()
        #expect(doctor.report.resources.activeWebViews == 1)
        #expect(doctor.report.resources.reclaimableWebViews == 1)

        let reclaimed = await doctor.reclaimIdleResources()
        #expect(reclaimed.reclaimedWebViews == 1)
        #expect(workspace.workbenchController.webView == nil)
        #expect(workspace.documents.count == 1)
        #expect(doctor.report.resources.activeWebViews == 0)
        #expect(doctor.report.resources.reclaimableWebViews == 0)

        // Uncollapsing the workspace rehydrates the WebView and open document seamlessly.
        let beforeRev = workspace.workbenchRehydrationRevision
        workspace.isVisible = true
        #expect(workspace.workbenchController.webView != nil)
        #expect(workspace.workbenchRehydrationRevision == beforeRev + 1)
        #expect(workspace.documents.first?.text == "print(\"hello\")\n")
    }

    @Test func nativePluginSettingsRendersOMGDoctorAndCommandPaletteActionWithoutTarballInstaller() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = OhMyGhosttySettings(fileURL: dir.appendingPathComponent("settings.json"))

        let suiteName = "OMGDoctorUI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)

        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            settings.language = language
            let controller = NativeSettingsController(
                settings: settings,
                initialSelection: .plugins,
                registry: registry,
                agents: agents
            )
            _ = controller.view
            controller.select(.plugins)
            controller.view.layoutSubtreeIfNeeded()

            let form = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
            let expectedLabel = SettingsStrings(language: language).doctorResourcesLabel
            #expect(form.rowTitles.contains(expectedLabel))
            #expect(!form.rowTitles.contains("GitHub"))
            #expect(!form.rowTitles.contains("Install package"))
            #expect(!form.rowTitles.contains("安装插件包"))
        }

        var didInvoke = false
        let enOption = TerminalCommandPaletteView.makeDoctorOption(language: .english) {
            didInvoke = true
        }
        #expect(enOption.title == "OMG Doctor")
        enOption.action()
        #expect(didInvoke)

        let zhOption = TerminalCommandPaletteView.makeDoctorOption(language: .simplifiedChinese) {}
        #expect(zhOption.title.contains("OMG Doctor"))
    }

    @Test func nativePluginSettingsUpdatesDoctorInPlaceWithoutRebuildLoopOrSearchWipe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = OhMyGhosttySettings(fileURL: dir.appendingPathComponent("settings.json"))
        settings.language = .english

        let suiteName = "OMGDoctorNoLoop.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)

        final class MemoryCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var step: UInt64 = 0
            func nextBytes() -> UInt64 {
                lock.lock()
                defer { lock.unlock() }
                step += 1
                return (100 + step) * 1_048_576
            }
            var calls: UInt64 {
                lock.lock()
                defer { lock.unlock() }
                return step
            }
        }
        let counter = MemoryCounter()
        let deps = OMGDoctorService.Dependencies(
            hasGlobalKeybinds: { false },
            isAccessibilityTrusted: { true },
            isEventTapEnabled: { false },
            resourcesURL: nil,
            homeDirectory: dir,
            sshControlDirectoryPath: dir.appendingPathComponent("no-ssh").path,
            agentManager: agents,
            surfaceCounter: { .init(visible: 2, occluded: 0) },
            residentMemoryProvider: { counter.nextBytes() }
        )
        let doctor = OMGDoctorService(dependencies: deps)

        let controller = NativeSettingsController(
            settings: settings,
            initialSelection: .plugins,
            registry: registry,
            agents: agents,
            doctor: doctor
        )
        _ = controller.view
        controller.select(.plugins)
        controller.searchField.stringValue = "doctor"
        let initialForm = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
        let initialFormID = ObjectIdentifier(initialForm)

        // Yield across multiple MainActor and RunLoop turns so initial async refresh settles.
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(15))
        }
        let callsAfterMount = counter.calls

        // Trigger another explicit refresh with a new residentMemory value and settle RunLoop.main.
        await doctor.refresh()
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(15))
        }

        let currentForm = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
        #expect(ObjectIdentifier(currentForm) == initialFormID)
        #expect(controller.searchField.stringValue == "doctor")
        #expect(counter.calls == callsAfterMount + 1)

        func collectStrings(in view: NSView) -> [String] {
            var out: [String] = []
            if let field = view as? NSTextField {
                out.append(field.stringValue)
            }
            for sub in view.subviews {
                out.append(contentsOf: collectStrings(in: sub))
            }
            return out
        }
        let expectedMemoryText = doctor.report.resources.summary(strings: SettingsStrings(language: .english))
        let expectedTrustText = doctor.report.signerTrust.summary(strings: SettingsStrings(language: .english))
        let renderedStrings = collectStrings(in: currentForm.view)
        #expect(renderedStrings.contains { $0.contains(expectedMemoryText) })
        #expect(renderedStrings.contains { $0.contains(expectedTrustText) })
    }

    @Test func doctorDetectsSelfSignedTrustStatesAndInstallsAdminCodeSigningTrust() async throws {
        let certDER = Data("test-self-signed-der".utf8)
        final class TrustState: @unchecked Sendable {
            private let lock = NSLock()
            let certDER: Data
            var mode: OMGSignerTrustMode = .selfSignedUntrusted
            var unscoped = false
            var installedDERs: [Data] = []
            var nextInstallResult: Result<Void, OMGSignerTrustInstallError> = .success(())

            init(certDER: Data) {
                self.certDER = certDER
            }

            func snapshot() -> OMGDoctorSignerTrustCheck {
                lock.lock()
                defer { lock.unlock() }
                let admin = mode == .selfSignedAdminTrusted
                let user = mode == .selfSignedUserOnlyTrusted
                let csTrusted = admin || user
                let healthy = admin && csTrusted && !unscoped
                return OMGDoctorSignerTrustCheck(
                    status: healthy ? .healthy : .warning,
                    mode: mode,
                    bundleIdentifier: "com.jischeng.omg",
                    teamIdentifier: nil,
                    certificateCommonName: "OMG Release Signing",
                    certificateSHA1: "9B2E176C03E5458E6FDAF73392CD9D79203972C6",
                    isSelfSignedLeaf: true,
                    trustedInAdminDomain: admin,
                    trustedInUserDomain: user,
                    isCodeSigningTrusted: csTrusted,
                    isNonCodeSigningBlocked: !unscoped,
                    hasUnscopedTrust: unscoped,
                    leafCertificateDER: certDER
                )
            }

            func install(_ der: Data) -> Result<Void, OMGSignerTrustInstallError> {
                lock.lock()
                defer { lock.unlock() }
                installedDERs.append(der)
                if case .success = nextInstallResult {
                    mode = .selfSignedAdminTrusted
                }
                return nextInstallResult
            }
        }

        let state = TrustState(certDER: certDER)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-trust-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "OMGDoctorTests.Trust.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agents = AgentIntegrationManager(
            defaults: defaults,
            homeURL: dir,
            snapshots: [AgentIntegrationManager.localID: AgentIntegrationSnapshot(hooks: [:], cli: [:])],
            connectionTargets: { [] },
            registry: registry
        )

        let doctor = OMGDoctorService(
            dependencies: .init(
                hasGlobalKeybinds: { false },
                isAccessibilityTrusted: { true },
                isEventTapEnabled: { false },
                resourcesURL: nil,
                homeDirectory: dir,
                sshControlDirectoryPath: dir.appendingPathComponent("no-ssh").path,
                agentManager: agents,
                surfaceCounter: { .init(visible: 1, occluded: 0) },
                residentMemoryProvider: { 64 * 1_048_576 },
                inspectSignerTrust: { state.snapshot() },
                installSignerTrust: { der in state.install(der) }
            )
        )

        let stringsEN = SettingsStrings(language: .english)
        let stringsZH = SettingsStrings(language: .simplifiedChinese)

        await doctor.refresh()
        #expect(doctor.report.overallStatus == .warning)
        #expect(doctor.report.signerTrust.status == .warning)
        #expect(doctor.report.signerTrust.needsTrustAction)
        #expect(doctor.report.signerTrust.summary(strings: stringsEN).contains("System Keychain"))
        #expect(doctor.report.signerTrust.summary(strings: stringsZH).contains("系统钥匙串"))

        // Canceled administrator prompt preserves warning and records cancellation error.
        state.nextInstallResult = .failure(.canceled)
        #expect(!(await doctor.installReleaseSignerTrust()))
        #expect(doctor.lastSignerTrustError == .canceled)
        #expect(doctor.report.signerTrust.status == .warning)

        // Successful Admin CodeSigning install resolves warning cleanly.
        state.nextInstallResult = .success(())
        #expect(await doctor.installReleaseSignerTrust())
        #expect(doctor.lastSignerTrustError == nil)
        #expect(doctor.report.signerTrust.mode == .selfSignedAdminTrusted)
        #expect(doctor.report.signerTrust.status == .healthy)
        #expect(!doctor.report.signerTrust.needsTrustAction)
        #expect(doctor.report.overallStatus == .healthy)

        // Overly broad trust (e.g. non-CodeSigning allowed) triggers warning and remediation prompt.
        state.unscoped = true
        await doctor.refresh()
        #expect(doctor.report.signerTrust.status == .warning)
        #expect(doctor.report.signerTrust.needsTrustAction)
        #expect(doctor.report.signerTrust.summary(strings: stringsEN).contains("overly broad"))

        // User-only trust warns that Admin trust is required for TCC persistence.
        state.unscoped = false
        state.mode = .selfSignedUserOnlyTrusted
        await doctor.refresh()
        #expect(doctor.report.signerTrust.status == .warning)
        #expect(doctor.report.signerTrust.summary(strings: stringsEN).contains("user keychain"))
    }

    @Test func doctorInspectsRealSelfSignedCertificateViaSecurityFrameworkWithoutKeychainMutation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-cert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyURL = dir.appendingPathComponent("key.pem")
        let derURL = dir.appendingPathComponent("cert.der")
        let confURL = dir.appendingPathComponent("cert.conf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = OMG Test Release Signer
        [ext]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature
        extendedKeyUsage = codeSigning
        """.write(to: confURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-outform", "DER", "-out", derURL.path,
            "-days", "1", "-config", confURL.path,
        ]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let derData = try Data(contentsOf: derURL)
        let certificate = try #require(SecCertificateCreateWithData(nil, derData as CFData))
        let check = OMGDoctorService.inspectLeafCertificateTrust(
            certificate: certificate,
            bundleIdentifier: "com.jischeng.omg"
        )

        let expectedSHA1 = Insecure.SHA1.hash(data: derData)
            .map { String(format: "%02X", $0) }
            .joined()
        #expect(check.mode == .selfSignedUntrusted)
        #expect(check.status == .warning)
        #expect(check.isSelfSignedLeaf)
        #expect(!check.trustedInAdminDomain)
        #expect(!check.trustedInUserDomain)
        #expect(!check.isCodeSigningTrusted)
        #expect(check.isNonCodeSigningBlocked)
        #expect(!check.hasUnscopedTrust)
        #expect(check.certificateSHA1 == expectedSHA1)
        #expect(check.leafCertificateDER == derData)
        #expect(check.needsTrustAction)
    }

    @Test func doctorInitDefersExpensiveTrustAndDiskInspectionToAsyncRefresh() async throws {
        final class InspectionProbe: @unchecked Sendable {
            private let lock = NSLock()
            var trustCalls = 0
            var memoryCalls = 0
            var trustRanOffMainThread = false

            func recordTrust() -> OMGDoctorSignerTrustCheck {
                lock.lock()
                trustCalls += 1
                trustRanOffMainThread = !Thread.isMainThread
                lock.unlock()
                return OMGDoctorSignerTrustCheck(
                    status: .healthy,
                    mode: .selfSignedAdminTrusted,
                    bundleIdentifier: "com.jischeng.omg",
                    teamIdentifier: nil,
                    certificateCommonName: "OMG Release Signing",
                    certificateSHA1: "9B2E176C03E5458E6FDAF73392CD9D79203972C6",
                    isSelfSignedLeaf: true,
                    trustedInAdminDomain: true,
                    trustedInUserDomain: false,
                    isCodeSigningTrusted: true,
                    isNonCodeSigningBlocked: true,
                    hasUnscopedTrust: false,
                    leafCertificateDER: nil
                )
            }

            func recordMemory() -> UInt64 {
                lock.lock()
                memoryCalls += 1
                lock.unlock()
                return 128 * 1_048_576
            }
        }

        let probe = InspectionProbe()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-defer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let doctor = OMGDoctorService(
            dependencies: .init(
                hasGlobalKeybinds: { false },
                isAccessibilityTrusted: { true },
                isEventTapEnabled: { false },
                resourcesURL: nil,
                homeDirectory: dir,
                sshControlDirectoryPath: dir.appendingPathComponent("no-ssh").path,
                surfaceCounter: { .init(visible: 1, occluded: 0) },
                residentMemoryProvider: { probe.recordMemory() },
                inspectSignerTrust: { probe.recordTrust() }
            )
        )

        // Synchronous `init` on `@MainActor` must not invoke SecTrust or disk/memory probes.
        #expect(probe.trustCalls == 0)
        #expect(probe.memoryCalls == 0)

        await doctor.refresh()
        #expect(probe.trustCalls == 1)
        #expect(probe.memoryCalls == 1)
        #expect(probe.trustRanOffMainThread)
    }

    @Test func concurrentStaleRefreshNeverOverwritesPostMutationTrustOrAccessibilityState() async throws {
        let certDER = Data("concurrent-self-signed-der".utf8)

        final class StalledTrustGate: @unchecked Sendable {
            private let lock = NSLock()
            private let stalledFirstInspection = DispatchSemaphore(value: 0)
            private let enteredFirstInspection = DispatchSemaphore(value: 0)
            private var callIndex = 0
            private var mode: OMGSignerTrustMode = .selfSignedUntrusted
            let certDER: Data

            init(certDER: Data) {
                self.certDER = certDER
            }

            func setMode(_ next: OMGSignerTrustMode) {
                lock.lock()
                mode = next
                lock.unlock()
            }

            func inspect(stallCall targetCall: Int?) -> OMGDoctorSignerTrustCheck {
                lock.lock()
                callIndex += 1
                let myCall = callIndex
                let capturedMode = mode
                lock.unlock()

                let admin = capturedMode == .selfSignedAdminTrusted
                let snapshot = OMGDoctorSignerTrustCheck(
                    status: admin ? .healthy : .warning,
                    mode: capturedMode,
                    bundleIdentifier: "com.jischeng.omg",
                    teamIdentifier: nil,
                    certificateCommonName: "OMG Release Signing",
                    certificateSHA1: "9B2E176C03E5458E6FDAF73392CD9D79203972C6",
                    isSelfSignedLeaf: true,
                    trustedInAdminDomain: admin,
                    trustedInUserDomain: false,
                    isCodeSigningTrusted: admin,
                    isNonCodeSigningBlocked: true,
                    hasUnscopedTrust: false,
                    leafCertificateDER: certDER
                )

                if myCall == targetCall {
                    enteredFirstInspection.signal()
                    _ = stalledFirstInspection.wait(timeout: .now() + 5.0)
                }
                return snapshot
            }

            func waitUntilStalledCallEntered() async {
                await Task.detached {
                    _ = self.enteredFirstInspection.wait(timeout: .now() + 5.0)
                }.value
            }

            func releaseStalledCall() {
                stalledFirstInspection.signal()
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-doctor-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Part A: Slow pre-install `refresh()` (#2) finishing AFTER `installReleaseSignerTrust()` (#3)
        // must never overwrite `report` back to `.warning` or cause post-install verification failure.
        let gateA = StalledTrustGate(certDER: certDER)
        var accessibilityTrusted = false
        let doctorA = OMGDoctorService(
            dependencies: .init(
                hasGlobalKeybinds: { true },
                isAccessibilityTrusted: { accessibilityTrusted },
                isEventTapEnabled: { accessibilityTrusted },
                requestAccessibility: {
                    accessibilityTrusted = true
                    return true
                },
                resourcesURL: nil,
                homeDirectory: dir,
                sshControlDirectoryPath: dir.appendingPathComponent("no-ssh").path,
                surfaceCounter: { .init(visible: 1, occluded: 0) },
                residentMemoryProvider: { 64 * 1_048_576 },
                inspectSignerTrust: { gateA.inspect(stallCall: 2) },
                installSignerTrust: { _ in
                    gateA.setMode(.selfSignedAdminTrusted)
                    return .success(())
                }
            )
        )

        // Call #1 seeds `report` with `leafCertificateDER` (`.warning`).
        await doctorA.refresh()
        #expect(doctorA.report.signerTrust.status == .warning)
        #expect(doctorA.report.accessibility.status == .warning)

        // Launch slow pre-mutation `refresh()` (call #2), which captures `.selfSignedUntrusted` and `isTrusted = false`,
        // then blocks on `gateA` while the user grants Accessibility AND installs Signer Trust!
        let slowRefreshTask = Task { await doctorA.refresh() }
        await gateA.waitUntilStalledCallEntered()

        #expect(doctorA.grantAccessibilityPermission())
        let installSucceeded = await doctorA.installReleaseSignerTrust()
        #expect(installSucceeded)
        #expect(doctorA.lastSignerTrustError == nil)
        #expect(doctorA.report.signerTrust.status == .healthy)
        #expect(doctorA.report.accessibility.isTrusted)
        #expect(doctorA.report.accessibility.status == .healthy)

        // Now release slow pre-mutation refresh #2 and wait for it to finish; `report` must stay `.healthy`!
        gateA.releaseStalledCall()
        await slowRefreshTask.value
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(doctorA.report.signerTrust.status == .healthy)
        #expect(doctorA.report.signerTrust.mode == .selfSignedAdminTrusted)
        #expect(doctorA.report.accessibility.isTrusted)
        #expect(doctorA.report.accessibility.status == .healthy)
        #expect(doctorA.report.overallStatus == .healthy)

        // Part B: Slow pre-install `refresh()` released right during `installSignerTrust` (finishing before
        // post-install `refresh()` completes) must also be invalidated and never flip `report` stale.
        let gateB = StalledTrustGate(certDER: certDER)
        let doctorB = OMGDoctorService(
            dependencies: .init(
                hasGlobalKeybinds: { false },
                isAccessibilityTrusted: { true },
                isEventTapEnabled: { true },
                resourcesURL: nil,
                homeDirectory: dir,
                sshControlDirectoryPath: dir.appendingPathComponent("no-ssh").path,
                surfaceCounter: { .init(visible: 1, occluded: 0) },
                residentMemoryProvider: { 64 * 1_048_576 },
                inspectSignerTrust: { gateB.inspect(stallCall: 2) },
                installSignerTrust: { _ in
                    gateB.setMode(.selfSignedAdminTrusted)
                    gateB.releaseStalledCall()
                    return .success(())
                }
            )
        )
        await doctorB.refresh()
        #expect(doctorB.report.signerTrust.status == .warning)

        let slowRefreshB = Task { await doctorB.refresh() }
        await gateB.waitUntilStalledCallEntered()
        #expect(await doctorB.installReleaseSignerTrust())
        await slowRefreshB.value
        #expect(doctorB.lastSignerTrustError == nil)
        #expect(doctorB.report.signerTrust.status == .healthy)
        #expect(doctorB.report.overallStatus == .healthy)
    }
}
