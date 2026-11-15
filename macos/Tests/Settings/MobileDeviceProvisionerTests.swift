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
}
