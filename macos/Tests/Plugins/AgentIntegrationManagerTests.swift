import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentIntegrationManagerTests {
    @Test func appUpgradeChecksHooksImmediatelyAndPreservesCLIDeadline() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.pi)
        let path = home.appendingPathComponent(".pi/agent/extensions/omg-agent-status.ts")
        try "// marker: _omg_agent_status\n// old adapter\n".write(to: path, atomically: true, encoding: .utf8)
        let now = Date()
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home, integrationRevision: "new-app")
        var policy = manager.policy(for: "local")
        policy.lastAttempt = now
        policy.checkedIntegrationRevision = "old-app"
        manager.setPolicy(policy, for: "local")
        #expect(!policy.isDue(at: now))
        #expect(manager.shouldCheck("local", at: now))
        await manager.refresh(target: "local", automatic: true, hooksOnly: true)
        #expect(installer.installationState(.pi) == .updateAvailable)
        #expect(manager.snapshots["local"]?.hooks[.pi] == .updateAvailable)
        #expect(manager.snapshots["local"]?.cli.isEmpty == true)
        #expect(manager.policy(for: "local").lastAttempt == now)
        #expect(!manager.shouldCheck("local", at: now))
        let reopened = AgentIntegrationManager(defaults: defaults, homeURL: home, integrationRevision: "new-app")
        #expect(!reopened.shouldCheck("local", at: now))
        let upgraded = AgentIntegrationManager(defaults: defaults, homeURL: home, integrationRevision: "next-app")
        #expect(upgraded.shouldCheck("local", at: now))
        policy.updateHooksAutomatically = true
        upgraded.setPolicy(policy, for: "local")
        await upgraded.refresh(target: "local", automatic: true, hooksOnly: true)
        #expect(installer.installationState(.pi) == .current)
        #expect(installer.installationState(.claude) == .missing)
        #expect(upgraded.snapshots["local"]?.hooksChanged == true)
        policy.checkAutomatically = false
        upgraded.setPolicy(policy, for: "local")
        #expect(!upgraded.shouldCheck("local", at: now))
        #expect(!upgraded.shouldCheck("ssh:offline", at: now))
    }

    @Test func legacyPoliciesDecodeWithoutUpgradeRevision() throws {
        let policy = try JSONDecoder().decode(AgentIntegrationPolicy.self, from: Data(#"{"checkAutomatically":true,"updateHooksAutomatically":false,"automaticallyUpdatedAgents":[],"intervalHours":24}"#.utf8))
        #expect(policy.checkedIntegrationRevision == nil)
        #expect(policy.needsIntegrationCheck(revision: "new-app"))
    }

    @Test func standaloneCodexUsesItsNativeUpdaterWithoutNpm() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("updates")
        try executable(#"""
#!/usr/bin/python3
import os, pathlib, sys
if sys.argv[1:] == ["--version"]: print("codex-cli 0.154.0")
elif sys.argv[1:] == ["update"]: pathlib.Path(os.environ["UPDATE_LOG"]).write_text("native update")
else: sys.exit(2)
"""#, at: home.appendingPathComponent("codex"))
        let environment = ["HOME": home.path, "PATH": home.path + ":/usr/bin:/bin", "UPDATE_LOG": log.path]
        let data = try await python(AgentIntegrationManager.cliScript(checkLatest: false), environment: environment)
        let inventory = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
        #expect(inventory["codex"]?.package == nil)
        #expect(inventory["codex"]?.canAutomaticallyUpdate == true)
        #expect(inventory["codex"]?.needsUpdateCheck == true)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        _ = try await python(AgentIntegrationManager.cliScript(update: .codex), environment: environment)
        #expect(try String(contentsOf: log, encoding: .utf8) == "native update")
    }
    @Test(arguments: [SupportedAgent.codex, .claude, .omp, .qoder, .opencode, .pi, .reasonix,
                      .antigravity, .cursor, .amp, .copilot, .droid, .kimi, .hermes, .grok, .cline, .qwen])
    func nativeUpdatePolicyNeverProbesHelp(agent: SupportedAgent) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("calls.jsonl")
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
with pathlib.Path(os.environ["UPDATE_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["--version"]: print("1.0.0")
elif "--help" in sys.argv: sys.exit(2)
elif os.environ.get("FAIL_UPDATE"):
    print("native update failed", file=sys.stderr)
    sys.exit(1)
"""#, at: home.appendingPathComponent(agent.definition.command))
        var environment = ["HOME": home.path, "PATH": home.path + ":/usr/bin:/bin", "UPDATE_LOG": log.path]
        let data = try await python(AgentIntegrationManager.cliScript(checkLatest: false), environment: environment)
        let inventory = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
        #expect(inventory[agent.rawValue]?.updater == "native")
        #expect(inventory[agent.rawValue]?.canAutomaticallyUpdate == true)
        #expect(inventory[agent.rawValue]?.needsUpdateCheck == true)
        #expect(try String(contentsOf: log, encoding: .utf8) == "[\"--version\"]\n")
        try FileManager.default.removeItem(at: log)
        _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
        let expected: [String] = switch agent {
        case .pi: ["update", "--all"]
        case .opencode, .reasonix: ["upgrade"]
        case .kimi: ["upgrade", "--yes"]
        case .hermes: ["update", "--yes", "--no-gateway-restart"]
        default: ["update"]
        }
        #expect(calls == [["--version"], expected])
        environment["FAIL_UPDATE"] = "1"
        await #expect(throws: (any Error).self) {
            _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        }
    }

    @Test func npmInstalledPiStillUsesNativeUpdateAll() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("node_modules")
        let package = root.appendingPathComponent("pi-test")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"name":"pi-test","version":"1.0.0","bin":{"pi":"cli"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
pathlib.Path(os.environ["UPDATE_LOG"]).write_text(json.dumps(sys.argv[1:]))
"""#, at: package.appendingPathComponent("cli"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("pi"), withDestinationURL: package.appendingPathComponent("cli")
        )
        // Any npm operation except inventory is a test failure.
        try executable("#!/bin/sh\n[ \"$1\" = root ] || exit 2\nprintf '%s\\n' \"$OMG_TEST_ROOT\"\n",
                       at: home.appendingPathComponent("npm"))
        let log = home.appendingPathComponent("updates.json")
        let environment = ["HOME": home.path, "PATH": home.path + ":/usr/bin:/bin",
                           "OMG_TEST_ROOT": root.path, "UPDATE_LOG": log.path]
        let data = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let inventory = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
        #expect(inventory["pi"]?.package == "pi-test")
        #expect(inventory["pi"]?.updater == "native")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        _ = try await python(AgentIntegrationManager.cliScript(update: .pi), environment: environment)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: log))
        #expect(arguments == ["update", "--all"])
    }

    @Test func offlineSSHIsNotScheduledAndDoesNotAdvanceItsDeadline() async throws {
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var connected: Set<String> = []
        let manager = AgentIntegrationManager(defaults: defaults, connectionTargets: { connected })
        var policy = AgentIntegrationPolicy()
        policy.updateHooksAutomatically = true
        policy.automaticallyUpdatedAgents = [.codex]
        manager.setPolicy(policy, for: "ssh:cloud")
        var localPolicy = manager.policy(for: "local")
        localPolicy.checkAutomatically = false
        manager.setPolicy(localPolicy, for: "local")
        manager.checkDueTargets()
        await manager.refresh(target: "ssh:cloud", automatic: true)
        #expect(manager.policy(for: "ssh:cloud").lastAttempt == nil)
        #expect(manager.snapshots["ssh:cloud"] == nil)
        #expect(manager.busy.isEmpty)
        #expect(manager.allowsAutomaticWork("local"))
        connected = ["ssh:vps-jump"]
        #expect(!manager.allowsAutomaticWork("ssh:cloud"))
        connected.insert("ssh:cloud")
        // A ready connection alone is no longer sufficient: it must be registered.
        #expect(!manager.allowsAutomaticWork("ssh:cloud"))
        connected.remove("ssh:cloud")
        #expect(!manager.allowsAutomaticWork("ssh:cloud"))
        #expect(manager.policy(for: "ssh:cloud").isDue(at: Date()))
    }
    @Test func updatePoliciesAreIsolatedPersistedAndRespectIntervals() throws {
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AgentIntegrationManager(defaults: defaults)
        #expect(manager.policy(for: "local").checkAutomatically)
        #expect(!manager.policy(for: "ssh:cloud").checkAutomatically)
        let now = Date(timeIntervalSince1970: 100_000)
        var policy = AgentIntegrationPolicy()
        policy.updateHooksAutomatically = true
        policy.automaticallyUpdatedAgents.insert(.codex)
        policy.lastAttempt = now
        manager.setPolicy(policy, for: "ssh:cloud")
        #expect(!manager.policy(for: "local").updateHooksAutomatically)
        #expect(!manager.policy(for: "ssh:other").updateHooksAutomatically)
        #expect(manager.policy(for: "ssh:cloud").automaticallyUpdatedAgents == [.codex])
        #expect(manager.policy(for: "local").automaticallyUpdatedAgents.isEmpty)
        #expect(!policy.isDue(at: now.addingTimeInterval(86_399)))
        #expect(policy.isDue(at: now.addingTimeInterval(86_400)))
        policy.checkAutomatically = false
        #expect(!policy.isDue(at: now.addingTimeInterval(1_000_000)))
        let reopened = AgentIntegrationManager(defaults: defaults)
        #expect(reopened.policy(for: "ssh:cloud").updateHooksAutomatically)
        #expect(reopened.policy(for: "ssh:cloud").lastAttempt == now)
    }

    @Test func settingsFrameFitsInvokingDisplayIncludingNegativeCoordinates() {
        let original = NSRect(x: 300, y: 200, width: 820, height: 560)
        let leftDisplay = NSRect(x: -1_920, y: 25, width: 1_920, height: 1_055)
        let moved = OhMyGhosttySettingsWindowController.frame(original, on: leftDisplay)
        #expect(leftDisplay.contains(moved))
        #expect(moved.midX == leftDisplay.midX)
        #expect(moved.size == original.size)
        let smallDisplay = NSRect(x: 0, y: 0, width: 640, height: 400)
        #expect(OhMyGhosttySettingsWindowController.frame(original, on: smallDisplay) == smallDisplay)
    }

    @Test func automaticHookMaintenanceRepairsStaleHooksButNeverReinstallsRemovedOnes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        let hooks = home.appendingPathComponent(".codex/hooks.json")
        let stale = try String(contentsOf: hooks, encoding: .utf8)
            .replacingOccurrences(of: "_omg_agent_status_v\(AgentHookInstaller.hookVersion)", with: "_omg_agent_status_v0")
        try stale.write(to: hooks, atomically: true, encoding: .utf8)
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home)
        await manager.refresh(target: "local", automatic: true)
        #expect(installer.installationState(.codex) == .updateAvailable)
        var policy = manager.policy(for: "local")
        policy.updateHooksAutomatically = true
        manager.setPolicy(policy, for: "local")
        await manager.refresh(target: "local", automatic: true)
        #expect(installer.installationState(.codex) == .current)
        #expect(installer.installationState(.claude) == .missing)
        #expect(manager.snapshots["local"]?.error == nil)
        #expect(manager.policy(for: "local").lastSuccess != nil)
        try installer.uninstall(.codex)
        await manager.refresh(target: "local", automatic: true)
        #expect(installer.installationState(.codex) == .missing)
    }

    @Test func updatesNeverDowngradeOrMovePrereleaseChannels() {
        #expect(AgentCLIInstallation(version: "1.9.0", latest: "1.10.0", package: "example").updateAvailable)
        #expect(!AgentCLIInstallation(version: "2.0.0", latest: "1.10.0", package: "example").updateAvailable)
        #expect(!AgentCLIInstallation(version: "2.0.0-beta.1", latest: "2.0.0", package: "example").updateAvailable)
        #expect(!AgentCLIInstallation(version: "1.0.0", latest: "2.0.0").updateAvailable)
    }

    @Test func remoteHooksTargetOnlySelectedAgentAndPreserveOtherHooks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let thirdParty = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo third-party"}]}]}}"#
        try thirdParty.write(to: claude, atomically: true, encoding: .utf8)
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        _ = try await python(AgentHookInstaller.remoteInstallerScript(agents: [.codex, .claude]), environment: environment)
        let codex = home.appendingPathComponent(".codex/hooks.json")
        let codexBefore = try Data(contentsOf: codex)
        let installed = try await hookStates(home: home)
        #expect(installed["codex"] == "current")
        #expect(installed["claude"] == "current")
        #expect(installed["pi"] == "missing")
        let stale = try #require(String(bytes: codexBefore, encoding: .utf8))
            .replacingOccurrences(of: "_omg_agent_status_v\(AgentHookInstaller.hookVersion)", with: "_omg_agent_status_v0")
        try stale.write(to: codex, atomically: true, encoding: .utf8)
        #expect(try await hookStates(home: home)["codex"] == "updateAvailable")
        _ = try await python(AgentHookInstaller.remoteInstallerScript(action: .remove, agents: [.claude]), environment: environment)
        #expect(try await hookStates(home: home)["claude"] == "missing")
        #expect(try String(contentsOf: claude, encoding: .utf8).contains("echo third-party"))
        #expect(try String(contentsOf: codex, encoding: .utf8) == stale)
    }

    @Test func remoteStatusAndRemovalCoverEveryExportedHookDialect() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        _ = try await python(AgentHookInstaller.remoteInstallerScript(), environment: environment)
        let installed = try await hookStates(home: home)
        let agents = SupportedAgent.allCases.filter { $0.definition.hook.kind != .none }
        for agent in agents { #expect(installed[agent.rawValue] == "current") }
        _ = try await python(AgentHookInstaller.remoteInstallerScript(action: .remove), environment: environment)
        let removed = try await hookStates(home: home)
        for agent in agents { #expect(removed[agent.rawValue] == "missing") }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/oh-my-ghostty/agent-detectors").path))
    }

    @Test(arguments: [SupportedAgent.crush, .qwen, .droid, .grok])
    func npmUpdateUsesVerifiedExecutableAndExactNewerVersion(agent: SupportedAgent) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        let root = home.appendingPathComponent("node_modules")
        let package = root.appendingPathComponent("@example/qwen")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"name":"@example/qwen","version":"1.0.0","bin":{"\#(agent.definition.command)":"cli"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try executable("#!/bin/sh\necho 1.0.0\n", at: package.appendingPathComponent("cli"))
        let command = bin.appendingPathComponent(agent.definition.command)
        try FileManager.default.createSymbolicLink(at: command, withDestinationURL: package.appendingPathComponent("cli"))
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
if sys.argv[1] == "root": print(os.environ["OMG_TEST_ROOT"])
elif sys.argv[1] == "outdated":
    print(json.dumps({"@example/qwen": {"latest": os.environ["OMG_TEST_LATEST"]}}))
    sys.exit(1)
elif sys.argv[1] == "install":
    pathlib.Path(os.environ["OMG_TEST_LOG"]).write_text(json.dumps(sys.argv[1:]))
else: sys.exit(2)
"""#, at: bin.appendingPathComponent("npm"))
        let log = home.appendingPathComponent("installed.json")
        var environment = [
            "HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin",
            "OMG_TEST_ROOT": root.path, "OMG_TEST_LATEST": "1.2.0", "OMG_TEST_LOG": log.path,
        ]
        let output = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let values = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: output)
        #expect(values[agent.rawValue]?.updateAvailable == true)
        #expect(values[agent.rawValue]?.updater == nil)
        var installedOnlyEnvironment = environment
        installedOnlyEnvironment.removeValue(forKey: "OMG_TEST_LATEST")
        let inventory = try await python(AgentIntegrationManager.cliScript(checkLatest: false), environment: installedOnlyEnvironment)
        let installedOnly = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: inventory)
        #expect(installedOnly[agent.rawValue]?.version == "1.0.0")
        #expect(installedOnly[agent.rawValue]?.latest == nil)
        _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("@example/qwen@1.2.0"))
        try FileManager.default.removeItem(at: log)
        environment["OMG_TEST_LATEST"] = "0.9.0"
        _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        try FileManager.default.removeItem(at: command)
        try executable("#!/bin/sh\necho 9.0.0\n", at: command)
        let unmanaged = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let unmanagedValues = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: unmanaged)
        #expect(unmanagedValues[agent.rawValue]?.package == nil)
        if agent == .crush {
            await #expect(throws: (any Error).self) {
                _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
            }
        } else {
            #expect(unmanagedValues[agent.rawValue]?.updater == "native")
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test func antigravityHooksPreserveNamedConfigAndEmitOnlyJSONOnStdout() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".gemini/config/hooks.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = #"{"third-party":{"Stop":[{"command":"echo preserved"}]}}"#
        try unrelated.write(to: url, atomically: true, encoding: .utf8)
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.antigravity)
        #expect(installer.installationState(.antigravity) == .current)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["third-party"] != nil)
        let hooks = try #require(root["omg-agent-status"] as? [String: Any])
        let pre = try #require((hooks["PreInvocation"] as? [[String: Any]])?.first?["command"] as? String)
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["command"] as? String)
        let data = try JSONEncoder().encode(["pre": pre, "stop": stop])
        let driver = #"""
import base64, fcntl, json, os, pty, subprocess, termios
commands = json.loads(base64.b64decode("\#(data.base64EncodedString())"))
def execute(command, payload, remote=False, terminal=True):
    environment = dict(os.environ)
    environment.pop("SSH_CONNECTION", None)
    if remote: environment["SSH_CONNECTION"] = "test"
    master, slave = pty.openpty()
    def setup():
        os.setsid()
        if terminal: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    process = subprocess.Popen(["/bin/sh", "-c", command], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        preexec_fn=setup, pass_fds=(slave,))
    process.stdin.write(json.dumps(payload).encode())
    process.stdin.close()
    stdout = process.stdout.read()
    stderr = process.stderr.read()
    response = json.loads(stdout)
    os.set_blocking(master, False)
    try: sequence = os.read(master, 65536).decode()
    except BlockingIOError: sequence = ""
    # macOS can defer the session leader's reap until the PTY is closed.
    os.close(master); os.close(slave)
    assert process.wait(timeout=10) == 0, stderr
    return response, sequence
for remote in (False, True):
    response, sequence = execute(commands["pre"], {"conversationId": "test-123"}, remote)
    assert response == {}
    assert "omg_state=working" in sequence
    assert "omg_scope=" + ("remote" if remote else "local") in sequence
    assert "omg_conversation=test-123" in sequence
    response, sequence = execute(commands["stop"], {"conversationId": "test-123", "fullyIdle": True}, remote)
    assert response == {"decision": "allow"}
    assert "omg_state=done" in sequence
    _, sequence = execute(commands["stop"], {"fullyIdle": False}, remote)
    assert "omg_state=working" in sequence
    _, sequence = execute(commands["stop"], {"terminationReason": "error"}, remote)
    assert "omg_state=error" in sequence
response, sequence = execute(commands["pre"], {}, terminal=False)
assert response == {} and not sequence
print("PTY local/SSH and headless protocol checks passed")
"""#
        _ = try await python(driver, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let remoteStatus = try await hookStates(home: home)
        #expect(remoteStatus["antigravity"] == "current")
        _ = try await python(AgentHookInstaller.remoteInstallerScript(action: .remove, agents: [.antigravity]), environment: environment)
        #expect(installer.installationState(.antigravity) == .missing)
        _ = try await python(AgentHookInstaller.remoteInstallerScript(agents: [.antigravity]), environment: environment)
        #expect(installer.installationState(.antigravity) == .current)
        try installer.uninstall(.antigravity)
        let remaining = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(remaining.count == 1 && remaining["third-party"] != nil)
        try #"{"omg-agent-status":{"Stop":[{"command":"echo user-owned"}]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try installer.install(.antigravity) }
        await #expect(throws: (any Error).self) {
            _ = try await python(AgentHookInstaller.remoteInstallerScript(agents: [.antigravity]), environment: environment)
        }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("user-owned"))
    }

    private func hookStates(home: URL) async throws -> [String: String] {
        let data = try await python(AgentHookInstaller.remoteInstallerScript(action: .status),
                                    environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func executable(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func python(_ script: String, environment: [String: String]) async throws -> Data {
        let result = try await GitProcessRunner().run(
            executablePath: "/usr/bin/python3", arguments: ["-"], workingDirectory: "/tmp",
            environment: environment, stdin: Data(script.utf8), timeout: 30
        )
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result.stdout
    }
}
