import CryptoKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct MobileDeviceProvisionerTests {
    @Test func devicectlParserSupportsModernPropertiesAndLegacySchemas() throws {
        let modernJSON = Data("""
        {
          "result": {
            "devices": [
              {
                "identifier": "5F72D461-0173-5907-85D9-60ED4D6179C3",
                "name": "WirelessPhone",
                "properties": {
                  "hardware": {
                    "udid": "00008120-000631D42E44201E",
                    "platform": "iOS",
                    "deviceType": "iPhone",
                    "marketingName": "iPhone 14 Pro"
                  },
                  "state": { "name": "available (paired)" },
                  "connection": { "transportType": "localNetwork" }
                }
              },
              {
                "identifier": "LEGACY-ID",
                "hardwareProperties": {
                  "udid": "11112222-3333444455556666",
                  "platform": "iOS",
                  "deviceType": "iPhone"
                },
                "deviceProperties": {
                  "name": "USBPhone",
                  "osVersionNumber": "18.1"
                },
                "connectionProperties": {
                  "transportType": "wired"
                }
              },
              {
                "identifier": "WATCH-ID",
                "properties": {
                  "hardware": {
                    "udid": "WATCH-UDID",
                    "platform": "watchOS",
                    "deviceType": "appleWatch"
                  }
                }
              },
              {
                "identifier": "315B3717-14B5-4D3D-9BD6-9C91A5CB31D0",
                "name": "iPhone 18 Pro",
                "properties": {
                  "hardware": {
                    "udid": "315B3717-14B5-4D3D-9BD6-9C91A5CB31D0",
                    "platform": "iOS",
                    "deviceType": "iPhone",
                    "reality": "simulated"
                  },
                  "connection": {
                    "transportType": "sameMachine",
                    "pairingState": "paired"
                  }
                }
              },
              {
                "identifier": "UNPAIRED-ID",
                "name": "UnpairedPhone",
                "hardwareProperties": {
                  "udid": "UNPAIRED-UDID",
                  "platform": "iOS",
                  "deviceType": "iPhone",
                  "reality": "physical"
                },
                "connectionProperties": {
                  "transportType": "localNetwork",
                  "pairingState": "unpaired"
                }
              },
              {
                "identifier": "LEGACY-SIM-ID",
                "name": "SimulatedLegacy",
                "hardwareProperties": {
                  "udid": "LEGACY-SIM-UDID",
                  "platform": "iOS",
                  "deviceType": "iPhone",
                  "reality": "virtual"
                },
                "connectionProperties": {
                  "transportType": "sameMachine"
                }
              }
            ]
          }
        }
        """.utf8)

        let parsed = MobileDeviceProvisioner.parseDevicectlDevices(jsonData: modernJSON)
        #expect(parsed.count == 2)
        // Wired device sorts first
        #expect(parsed[0].name == "USBPhone")
        #expect(parsed[0].udid == "11112222-3333444455556666")
        #expect(parsed[0].osVersion == "18.1")
        #expect(parsed[0].transport == .wired)

        #expect(parsed[1].name == "WirelessPhone")
        #expect(parsed[1].udid == "00008120-000631D42E44201E")
        #expect(parsed[1].coreDeviceID == "5F72D461-0173-5907-85D9-60ED4D6179C3")
        #expect(parsed[1].model == "iPhone 14 Pro")
        #expect(parsed[1].transport == .localNetwork)
    }

    @Test func installedAppProbeAndProfileInspectionPreserveExistingBundleID() throws {
        let appsJSON = Data("""
        {
          "result": {
            "apps": [
              { "properties": { "bundleIdentifier": "com.example.other" } },
              { "bundleIdentifier": "com.jischeng.omg.mobile.5k863np6zu" }
            ]
          }
        }
        """.utf8)
        let installed = MobileDeviceProvisioner.parseInstalledMobileBundleID(jsonData: appsJSON)
        #expect(installed == "com.jischeng.omg.mobile.5k863np6zu")

        let certBytes = Data("mock-der-cert".utf8)
        let certSHA1 = Insecure.SHA1.hash(data: certBytes).map { String(format: "%02X", $0) }.joined()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let plistDict: [String: Any] = [
            "UUID": "PROFILE-UUID-1",
            "TeamIdentifier": ["5K863NP6ZU"],
            "ExpirationDate": now.addingTimeInterval(5 * 86400),
            "ProvisionedDevices": ["UDID-1"],
            "DeveloperCertificates": [certBytes],
            "Entitlements": ["application-identifier": "5K863NP6ZU.com.jischeng.omg.mobile"],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        let profile = try #require(MobileDeviceProvisioner.parseProvisioningProfile(
            plistData: plistData,
            path: URL(fileURLWithPath: "/tmp/test.mobileprovision")
        ))

        // Preserve already-installed bundle ID over profile bundle ID to protect pairings
        let resolvedInstalled = MobileDeviceProvisioner.resolveTargetBundleID(
            explicit: nil,
            installedBundleID: installed,
            profiles: [profile],
            teamID: "5K863NP6ZU",
            deviceUDID: "UDID-1"
        )
        #expect(resolvedInstalled == "com.jischeng.omg.mobile.5k863np6zu")

        // When no installed app exists yet, inherit matching profile bundle ID
        let resolvedFresh = MobileDeviceProvisioner.resolveTargetBundleID(
            explicit: nil,
            installedBundleID: nil,
            profiles: [profile],
            teamID: "5K863NP6ZU",
            deviceUDID: "UDID-1"
        )
        #expect(resolvedFresh == "com.jischeng.omg.mobile")

        // Valid vs expiring (<48h) vs expired status calculation
        let freshStatus = MobileDeviceProvisioner.computeExpiryStatus(profile: profile, now: now)
        if case .valid(_, let rem) = freshStatus {
            #expect(rem == 5 * 86400)
        } else {
            Issue.record("Expected .valid expiry status, got \(freshStatus)")
        }

        let nearExpiryStatus = MobileDeviceProvisioner.computeExpiryStatus(
            profile: profile,
            now: now.addingTimeInterval(4 * 86400)
        )
        if case .expiringSoon(_, let rem) = nearExpiryStatus {
            #expect(rem == 86400)
        } else {
            Issue.record("Expected .expiringSoon expiry status, got \(nearExpiryStatus)")
        }

        let expiredStatus = MobileDeviceProvisioner.computeExpiryStatus(
            profile: profile,
            now: now.addingTimeInterval(6 * 86400)
        )
        if case .expired = expiredStatus {
        } else {
            Issue.record("Expected .expired status, got \(expiredStatus)")
        }

        // Valid profile matches matching UDID + team + SHA1, rejects unknown UDID
        #expect(MobileDeviceProvisioner.selectValidProfile(
            profiles: [profile],
            teamID: "5K863NP6ZU",
            bundleID: "com.jischeng.omg.mobile",
            deviceUDID: "UDID-1",
            identitySHA1s: [certSHA1],
            now: now
        )?.uuid == "PROFILE-UUID-1")
        #expect(MobileDeviceProvisioner.selectValidProfile(
            profiles: [profile],
            teamID: "5K863NP6ZU",
            bundleID: "com.jischeng.omg.mobile",
            deviceUDID: "OTHER-UDID",
            identitySHA1s: [certSHA1],
            now: now
        ) == nil)
    }

    @Test func autoRefreshDefaultsOffAndEnforcesThresholdAndCooldown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-prov-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let provisioner = MobileDeviceProvisioner(
            supportDirectory: dir,
            profileDirectories: [],
            commandRunner: { _, _ in .init(status: 0, stdout: Data(), stderr: Data()) }
        )
        #expect(!provisioner.autoRefreshEnabled)

        provisioner.setAutoRefreshEnabled(true)
        #expect(provisioner.autoRefreshEnabled)
        let reloaded = MobileDeviceProvisioner(
            supportDirectory: dir,
            profileDirectories: [],
            commandRunner: { _, _ in .init(status: 0, stdout: Data(), stderr: Data()) }
        )
        #expect(reloaded.autoRefreshEnabled)

        let dev = MobileDeviceProvisioner.PairedDevice(
            udid: "UDID-1",
            coreDeviceID: "CORE-1",
            name: "MyPhone",
            model: "iPhone",
            osVersion: "18.0",
            transport: .localNetwork,
            installedBundleID: "com.jischeng.omg.mobile"
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = MobileDeviceProvisioner.ExpiryStatus.expiringSoon(
            expiresAt: now.addingTimeInterval(12 * 3600),
            remaining: 12 * 3600
        )
        let plenty = MobileDeviceProvisioner.ExpiryStatus.valid(
            expiresAt: now.addingTimeInterval(72 * 3600),
            remaining: 72 * 3600
        )

        #expect(!MobileDeviceProvisioner.shouldTriggerAutoRefresh(
            enabled: false, status: soon, device: dev, now: now, lastAttemptAt: nil, cooldownSeconds: 6 * 3600
        ))
        #expect(!MobileDeviceProvisioner.shouldTriggerAutoRefresh(
            enabled: true, status: plenty, device: dev, now: now, lastAttemptAt: nil, cooldownSeconds: 6 * 3600
        ))
        #expect(!MobileDeviceProvisioner.shouldTriggerAutoRefresh(
            enabled: true, status: soon, device: dev, now: now,
            lastAttemptAt: now.addingTimeInterval(-3600), cooldownSeconds: 6 * 3600
        ))
        #expect(MobileDeviceProvisioner.shouldTriggerAutoRefresh(
            enabled: true, status: soon, device: dev, now: now,
            lastAttemptAt: now.addingTimeInterval(-7 * 3600), cooldownSeconds: 6 * 3600
        ))
    }

    @Test func scanDevicesPopulatesStateFromCommandRunnerAndProvisioningProfiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-prov-scan-\(UUID().uuidString)")
        let profDir = dir.appendingPathComponent("profiles")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: profDir, withIntermediateDirectories: true)

        let certBytes = Data("test-cert".utf8)
        let certSHA1 = Insecure.SHA1.hash(data: certBytes).map { String(format: "%02X", $0) }.joined()
        let plistData = try PropertyListSerialization.data(fromPropertyList: [
            "UUID": "UUID-SCAN-1",
            "TeamIdentifier": ["5K863NP6ZU"],
            "ExpirationDate": Date().addingTimeInterval(5 * 86400),
            "ProvisionedDevices": ["00008120-000631D42E44201E"],
            "DeveloperCertificates": [certBytes],
            "Entitlements": ["application-identifier": "5K863NP6ZU.com.jischeng.omg.mobile"],
        ], format: .xml, options: 0)
        let profileFile = profDir.appendingPathComponent("UUID-SCAN-1.mobileprovision")
        try plistData.write(to: profileFile)

        let provisioner = MobileDeviceProvisioner(
            supportDirectory: dir,
            profileDirectories: [profDir],
            commandRunner: { executable, args in
                if executable == "/usr/bin/xcrun", args.contains("--json-output"),
                   let idx = args.firstIndex(of: "--json-output"), idx + 1 < args.count {
                    let outPath = URL(fileURLWithPath: args[idx + 1])
                    if args.contains("list") {
                        let json = """
                        {"result":{"devices":[{"identifier":"CORE-1","name":"My iPhone","properties":{"hardware":{"udid":"00008120-000631D42E44201E","platform":"iOS","deviceType":"iPhone"},"connection":{"transportType":"localNetwork"}}}]}}
                        """
                        try? Data(json.utf8).write(to: outPath)
                    } else if args.contains("apps") {
                        let apps = """
                        {"result":{"apps":[{"bundleIdentifier":"com.jischeng.omg.mobile"}]}}
                        """
                        try? Data(apps.utf8).write(to: outPath)
                    }
                    return .init(status: 0, stdout: Data(), stderr: Data())
                }
                if executable == "/usr/bin/security", args.first == "find-identity" {
                    let line = "  1) \(certSHA1) \"Apple Development: dev@example.com (5K863NP6ZU)\"\n"
                    return .init(status: 0, stdout: Data(line.utf8), stderr: Data())
                }
                if executable == "/usr/bin/security", args.first == "cms" {
                    return .init(status: 0, stdout: plistData, stderr: Data())
                }
                return .init(status: 0, stdout: Data(), stderr: Data())
            }
        )

        await provisioner.scanDevices(silent: false)
        #expect(provisioner.devices.count == 1)
        #expect(provisioner.selectedDevice?.udid == "00008120-000631D42E44201E")
        #expect(provisioner.activeBundleID == "com.jischeng.omg.mobile")
        #expect(provisioner.activeTeamID == "5K863NP6ZU")
        if case .valid = provisioner.expiryStatus {
        } else {
            Issue.record("Expected valid status, got \(provisioner.expiryStatus)")
        }
    }

    @Test func locateInstallScriptRestrictsToDevModeVerifiedRepoRootAndIgnoresCurrentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-prov-script-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeRepo = root.appendingPathComponent("repo", isDirectory: true)
        let iosScripts = fakeRepo.appendingPathComponent("ios/scripts", isDirectory: true)
        let xcodeproj = fakeRepo.appendingPathComponent("macos/Ghostty.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: iosScripts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeRepo.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeRepo.appendingPathComponent("ios").path)
        try Data("// zig\n".utf8).write(to: fakeRepo.appendingPathComponent("build.zig"))
        try Data("name: OMGMobile\n".utf8).write(to: fakeRepo.appendingPathComponent("ios/project.yml"))
        try Data("// pbxproj\n".utf8).write(to: xcodeproj.appendingPathComponent("project.pbxproj"))
        let scriptURL = iosScripts.appendingPathComponent("install-to-iphone.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let env = ["OMG_IOS_SOURCE_DIR": fakeRepo.appendingPathComponent("ios").path]
        let unrelatedBundle = root.appendingPathComponent("Apps/OMG Dev.app", isDirectory: true)

        // 1. Release builds (`isDevelopment == false`) never invoke source-tree install script even if env is set.
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: false,
            environment: env,
            bundleURL: unrelatedBundle
        ) == nil)

        // 2. Dev builds accept verified owned repo root via `OMG_IOS_SOURCE_DIR` or ancestor of `bundleURL`.
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: true,
            environment: env,
            bundleURL: unrelatedBundle
        )?.standardizedFileURL == scriptURL.standardizedFileURL)
        let nestedDebugBundle = fakeRepo.appendingPathComponent("macos/build/Debug/OMG Dev.app", isDirectory: true)
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: true,
            environment: [:],
            bundleURL: nestedDebugBundle
        )?.standardizedFileURL == scriptURL.standardizedFileURL)

        // 3. Unrelated CWD with `ios/scripts/install-to-iphone.sh` is ignored when neither env nor bundleURL points to it.
        let previousCWD = FileManager.default.currentDirectoryPath
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousCWD) }
        _ = FileManager.default.changeCurrentDirectoryPath(fakeRepo.path)
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: true,
            environment: [:],
            bundleURL: unrelatedBundle
        ) == nil)

        // 4. World-writable script or symlinked script or wrong UID is rejected.
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: true,
            environment: env,
            bundleURL: unrelatedBundle,
            expectedUID: getuid() &+ 1
        ) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: scriptURL.path)
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: true,
            environment: env,
            bundleURL: unrelatedBundle
        ) == nil)
        try FileManager.default.removeItem(at: scriptURL)
        let outsideScript = root.appendingPathComponent("outside.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outsideScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outsideScript.path)
        try FileManager.default.createSymbolicLink(at: scriptURL, withDestinationURL: outsideScript)
        #expect(MobileDeviceProvisioner.locateInstallScript(
            isDevelopment: true,
            environment: env,
            bundleURL: unrelatedBundle
        ) == nil)
    }

    @Test func releaseDownloadURLVersionAndProvisioningInputsRejectUntrustedAndInjectedValues() throws {
        // Trusted GitHub release IPA download & redirect targets:
        #expect(MobileDeviceProvisioner.isTrustedAltStoreFeedURL(
            try #require(URL(string: "https://github.com/jischeng/oh-my-ghostty/releases/latest/download/altstore-source.json"))
        ))
        #expect(!MobileDeviceProvisioner.isTrustedAltStoreFeedURL(
            try #require(URL(string: "https://evil.example.com/jischeng/oh-my-ghostty/releases/latest/download/altstore-source.json"))
        ))
        #expect(MobileDeviceProvisioner.isTrustedReleaseDownloadURL(
            try #require(URL(string: "https://github.com/jischeng/oh-my-ghostty/releases/download/v0.13.0/OMG-Mobile.ipa"))
        ))
        #expect(!MobileDeviceProvisioner.isTrustedReleaseDownloadURL(
            try #require(URL(string: "http://github.com/jischeng/oh-my-ghostty/releases/download/v0.13.0/OMG-Mobile.ipa"))
        ))
        #expect(!MobileDeviceProvisioner.isTrustedReleaseDownloadURL(
            try #require(URL(string: "https://github.com/other-owner/repo/releases/download/v1.0.0/OMG-Mobile.ipa"))
        ))
        #expect(!MobileDeviceProvisioner.isTrustedReleaseDownloadURL(
            try #require(URL(string: "https://evil.example.com/OMG-Mobile.ipa"))
        ))
        #expect(MobileDeviceProvisioner.isTrustedRedirectTargetURL(
            try #require(URL(string: "https://objects.githubusercontent.com/github-production-release-asset/123?X-Amz-Signature=abc"))
        ))
        #expect(MobileDeviceProvisioner.isTrustedRedirectTargetURL(
            try #require(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123"))
        ))
        #expect(!MobileDeviceProvisioner.isTrustedRedirectTargetURL(
            try #require(URL(string: "https://attacker.example.net/payload.ipa"))
        ))

        // Version tokens & cached IPA path traversal prevention:
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ipa-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let safeIPA = try MobileDeviceProvisioner.validatedCachedIPAURL(
            cacheDir: cacheDir,
            version: "0.13.0",
            buildVersion: "42"
        )
        #expect(safeIPA.lastPathComponent == "OMG-Mobile-0.13.0-b42.ipa")
        for badVersion in ["../escape", "0.13.0/../../x", ".leading-dot", "bad space", ""] {
            #expect(!MobileDeviceProvisioner.isSafeVersionToken(badVersion))
            #expect(throws: (any Error).self) {
                _ = try MobileDeviceProvisioner.validatedCachedIPAURL(
                    cacheDir: cacheDir,
                    version: badVersion,
                    buildVersion: "1"
                )
            }
        }

        // Provisioning pbxproj / xcodebuild argument validation:
        try MobileDeviceProvisioner.validateProvisioningInputs(
            teamID: "5K863NP6ZU",
            bundleID: "com.jischeng.omg.mobile.5k863np6zu",
            deviceUDID: "00008120-000631D42E44201E"
        )
        #expect(throws: (any Error).self) {
            try MobileDeviceProvisioner.validateProvisioningInputs(
                teamID: "5K86\"; shellScript = \"id\"; //",
                bundleID: "com.jischeng.omg.mobile",
                deviceUDID: "00008120-000631D42E44201E"
            )
        }
        #expect(throws: (any Error).self) {
            try MobileDeviceProvisioner.validateProvisioningInputs(
                teamID: "5K863NP6ZU",
                bundleID: "com.jischeng\"; CODE_SIGNING_ALLOWED = NO; //",
                deviceUDID: "00008120-000631D42E44201E"
            )
        }
        #expect(throws: (any Error).self) {
            try MobileDeviceProvisioner.validateProvisioningInputs(
                teamID: "5K863NP6ZU",
                bundleID: "com.jischeng.omg.mobile",
                deviceUDID: "00008120,arch=arm64;rm"
            )
        }
    }

    @Test func runSubprocessDrainsLargeStdoutAndStderrWithoutDeadlockAndHonorsTimeoutAndCancel() async throws {
        // 1. Concurrent >128 KB writes on BOTH stdout and stderr must not deadlock on OS pipe buffers.
        let largeOut = await MobileDeviceProvisioner.runSubprocess(
            executable: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys; sys.stdout.buffer.write(b'O' * 200000); sys.stdout.flush(); sys.stderr.buffer.write(b'E' * 200000); sys.stderr.flush()",
            ],
            timeoutSeconds: 10
        )
        #expect(largeOut.status == 0)
        #expect(largeOut.stdout.count == 200_000)
        #expect(largeOut.stderr.count == 200_000)

        // 2. Timeout terminates a hung subprocess promptly.
        let t0 = Date()
        let timedOut = await MobileDeviceProvisioner.runSubprocess(
            executable: "/bin/sleep",
            arguments: ["30"],
            timeoutSeconds: 0.15
        )
        #expect(timedOut.status == -1)
        #expect(Date().timeIntervalSince(t0) < 3.0)

        // 3. Task cancellation terminates an active subprocess promptly.
        let c0 = Date()
        let task = Task.detached {
            await MobileDeviceProvisioner.runSubprocess(
                executable: "/bin/sleep",
                arguments: ["30"],
                timeoutSeconds: 30
            )
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled.status == -1)
        #expect(Date().timeIntervalSince(c0) < 3.0)
    }

    @Test func freshAppleIDFallbackBundleCollisionWildcardEntitlementsAndAutoRefreshMonitorGateWork() async throws {
        // 1. `candidateIdentitySHA1s` ignores non-dev identities & revoked certs (0 `openssl` spawns when empty).
        let emptySecOutput = """
          0 valid identities found
        """
        #expect(MobileDeviceProvisioner.candidateIdentitySHA1s(from: emptySecOutput).isEmpty)

        let mixedSecOutput = """
          1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "OMG Release Signing"
          2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: revoked@example.com" (CSSMERR_TP_CERT_REVOKED)
          3) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: valid@example.com (9Z8Y7X6W5V)"
        """
        #expect(MobileDeviceProvisioner.candidateIdentitySHA1s(from: mixedSecOutput) == [
            "0123456789ABCDEF0123456789ABCDEF01234567",
        ])

        // 2. `parseXcodeProvisioningTeamID` extracts team ID from `IDEProvisioningTeams` (preferring paid over free).
        let defaultsOut = """
        {
            "dev@example.com" =     (
                        {
                    isFreeProvisioningTeam = 1;
                    teamID = FREE123456;
                    teamName = "Personal Team";
                },
                        {
                    isFreeProvisioningTeam = 0;
                    teamID = PAID987654;
                    teamName = "Paid Corp";
                }
            );
        }
        """
        #expect(MobileDeviceProvisioner.parseXcodeProvisioningTeamID(defaultsOutput: defaultsOut) == "PAID987654")
        let freeOnlyOut = "{ acct = ( { isFreeProvisioningTeam = 1; teamID = \"FREE123456\"; } ); }"
        #expect(MobileDeviceProvisioner.parseXcodeProvisioningTeamID(defaultsOutput: freeOnlyOut) == "FREE123456")

        // 3. Bundle ID collision fallback triggers only for fresh default bundle ID when portal rejects registration.
        #expect(MobileDeviceProvisioner.shouldFallbackToTeamScopedBundleID(
            errorText: "The app ID 'com.jischeng.omg.mobile' cannot be registered to your development team.",
            currentBundleID: "com.jischeng.omg.mobile",
            installedBundleID: nil
        ))
        #expect(!MobileDeviceProvisioner.shouldFallbackToTeamScopedBundleID(
            errorText: "The app ID 'com.jischeng.omg.mobile' cannot be registered to your development team.",
            currentBundleID: "com.jischeng.omg.mobile",
            installedBundleID: "com.jischeng.omg.mobile"
        ))

        // 4. Wildcard profile entitlements rewrite `TEAM.*` to concrete `TEAM.<bundleID>` before codesigning.
        let wildcardPlist = try PropertyListSerialization.data(fromPropertyList: [
            "UUID": "WILDCARD-1",
            "TeamIdentifier": ["FREE123456"],
            "ExpirationDate": Date().addingTimeInterval(5 * 86400),
            "ProvisionedDevices": ["UDID-1"],
            "DeveloperCertificates": [Data("cert".utf8)],
            "Entitlements": [
                "application-identifier": "FREE123456.*",
                "get-task-allow": true,
            ],
        ], format: .xml, options: 0)
        let wildcardProfile = try #require(MobileDeviceProvisioner.parseProvisioningProfile(
            plistData: wildcardPlist,
            path: URL(fileURLWithPath: "/tmp/wildcard.mobileprovision")
        ))
        #expect(wildcardProfile.isWildcard)
        let rewrittenData = try MobileDeviceProvisioner.resolvedEntitlementsData(
            for: wildcardProfile,
            bundleID: "com.jischeng.omg.mobile.free123456"
        )
        let rewritten = try #require(PropertyListSerialization.propertyList(
            from: rewrittenData,
            options: [],
            format: nil
        ) as? [String: Any])
        #expect(rewritten["application-identifier"] as? String == "FREE123456.com.jischeng.omg.mobile.free123456")

        // 5. Fresh Apple ID with 0 signing certs still populates `activeTeamID` via `IDEProvisioningTeams`,
        //    and `startAutoRefreshMonitor()` stays idle until `autoRefreshEnabled` is opted in.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-prov-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var opensslInvocations = 0
        let provisioner = MobileDeviceProvisioner(
            supportDirectory: dir,
            profileDirectories: [],
            commandRunner: { executable, args in
                if executable == "/usr/bin/openssl" {
                    opensslInvocations += 1
                }
                if executable == "/usr/bin/security", args.first == "find-identity" {
                    return .init(status: 0, stdout: Data("  0 valid identities found\n".utf8), stderr: Data())
                }
                if executable == "/usr/bin/defaults" {
                    return .init(status: 0, stdout: Data(freeOnlyOut.utf8), stderr: Data())
                }
                return .init(status: 0, stdout: Data(), stderr: Data())
            },
            allowMonitorInTests: true
        )
        defer { provisioner.stopAutoRefreshMonitor() }

        #expect(!provisioner.autoRefreshEnabled)
        provisioner.startAutoRefreshMonitor()
        #expect(!provisioner.isAutoRefreshMonitorRunning)

        provisioner.setAutoRefreshEnabled(true)
        #expect(provisioner.isAutoRefreshMonitorRunning)
        provisioner.setAutoRefreshEnabled(false)
        #expect(!provisioner.isAutoRefreshMonitorRunning)

        await provisioner.scanDevices(silent: true)
        #expect(opensslInvocations == 0)
        #expect(provisioner.activeTeamID == "FREE123456")
    }
}
