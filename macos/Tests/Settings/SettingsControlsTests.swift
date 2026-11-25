import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SettingsControlsTests {
    @Test func mobileAccessInvitationProducesPairingCode() {
        #expect(MobileAccessController.qrImage(
            for: "omg://device?url=ws://192.168.1.2:8791&token=" + String(repeating: "a", count: 64)
        ) != nil)
    }

    @Test func mobileAccessRefreshesAddressAndReportsFailureReasons() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-omgd")
        var currentAddress: String?
        var currentTailscaleAddress: String?
        let controller = MobileAccessController(
            executable: executable,
            support: directory,
            port: 18791,
            addressProvider: { currentAddress },
            tailscaleAddressProvider: { currentTailscaleAddress }
        )
        #expect(controller.listenAddress == nil)
        #expect(!controller.isEnabledPreference)
        controller.start()
        #expect(controller.isEnabledPreference)
        #expect(controller.state == .failed("The bundled mobile runtime is missing."))
        #expect(controller.errorMessage == "The bundled mobile runtime is missing.")

        let script = """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "--print-invite" ]; then
                printf 'omg://device?url=ws://192.168.1.9:18791&token=testtoken\\n'
                exit 0
            fi
        done
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        controller.start()
        #expect(controller.state == .failed("No private IPv4 LAN address is available."))
        #expect(controller.errorMessage == "No private IPv4 LAN address is available.")

        currentAddress = "192.168.1.9"
        currentTailscaleAddress = "100.90.1.2"
        await controller.refreshInvitation()
        #expect(controller.listenAddress == "192.168.1.9:18791")
        #expect(!controller.isUsingTailscale)
        #expect(controller.invitation == "omg://device?url=ws://192.168.1.9:18791&token=testtoken")
        #expect(controller.errorMessage == nil)

        controller.setNetworkMode(.tailscale)
        await controller.refreshInvitation()
        #expect(controller.networkMode == .tailscale)
        #expect(controller.listenAddress == "100.90.1.2:18791")
        #expect(controller.isUsingTailscale)
        #expect(controller.invitation == "omg://device?url=ws://100.90.1.2:18791&token=testtoken")

        controller.setNetworkMode(.lan)
        await controller.refreshInvitation()
        #expect(controller.networkMode == .lan)
        #expect(controller.listenAddress == "192.168.1.9:18791")

        #expect(!controller.setPublicURL("ws://119.29.60.90:18791"))
        #expect(controller.publicURL.isEmpty)
        #expect(controller.setPublicURL("https://119.29.60.90:18791/"))
        #expect(controller.publicURL == "wss://119.29.60.90:18791")
        #expect(controller.invitation == "omg://device?url=wss://119.29.60.90:18791&token=testtoken")
        #expect(controller.setPublicURL(""))
        #expect(controller.invitation == "omg://device?url=ws://192.168.1.9:18791&token=testtoken")

        controller.stop(persist: false)
        #expect(controller.isEnabledPreference)

        let tokenFile = directory.appendingPathComponent("mobile-pair.token")
        try Data("token".utf8).write(to: tokenFile)
        #expect(controller.hasPairing)

        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        let settingsController = NativeSettingsController(
            settings: settings,
            initialSelection: .mobile,
            mobileAccessController: controller
        )
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = settingsController
        defer { window.close() }
        settingsController.view.layoutSubtreeIfNeeded()
        let form = try #require(settingsController.children.compactMap { $0 as? NativeSettingsForm }.first)
        #expect(form.rowTitles == [
            "允许 iPhone 连接",
            "网关状态",
            "网络接口",
            "外部 WSS 入口",
            "配对密钥",
            "目标设备",
            "7 天签名状态",
            "安装 / 刷新 iPhone App",
            "Wi-Fi 自动续签",
            "SideStore 订阅源",
        ])

        controller.revokePairings()
        #expect(!controller.isEnabledPreference)
        #expect(!controller.hasPairing)
        #expect(controller.invitation == nil)
        #expect(controller.state == .stopped)
    }

    @Test func mobileGatewaySeparatesChannelPortsReapsOrphansAndSmoothsFailedToggle() async throws {
        #expect(OMGApplicationEnvironment.defaultMobileGatewayPort(
            development: false, workspaceDevelopment: false, ptyDevelopment: false
        ) == 8791)
        #expect(OMGApplicationEnvironment.defaultMobileGatewayPort(
            development: true, workspaceDevelopment: false, ptyDevelopment: false
        ) == 8792)
        #expect(OMGApplicationEnvironment.defaultMobileGatewayPort(
            development: true, workspaceDevelopment: true, ptyDevelopment: false
        ) == 8793)
        #expect(OMGApplicationEnvironment.defaultMobileGatewayPort(
            development: true, workspaceDevelopment: false, ptyDevelopment: true
        ) == 8794)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-omgd")
        let marker = directory.appendingPathComponent("stopped-orphan")
        let script = """
        #!/bin/sh
        if [ "$1" = "mobile" ] && [ "$2" = "stop" ]; then
            printf 'stopped\\n' > "\(marker.path)"
            exit 0
        fi
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let lockURL = directory.appendingPathComponent("mobile-gateway.lock")
        FileManager.default.createFile(atPath: lockURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let flockFn: (Int32, Int32) -> Int32 = flock
        let lockFD = Darwin.open(lockURL.path, O_RDWR)
        #expect(lockFD >= 0)
        defer {
            _ = flockFn(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
        #expect(flockFn(lockFD, LOCK_EX | LOCK_NB) == 0)

        let controller = MobileAccessController(
            executable: executable,
            support: directory,
            port: 18792,
            addressProvider: { "192.168.1.9" },
            tailscaleAddressProvider: { nil }
        )
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        let settingsController = NativeSettingsController(
            settings: settings,
            initialSelection: .mobile,
            mobileAccessController: controller
        )
        settingsController.loadViewIfNeeded()
        settingsController.view.layoutSubtreeIfNeeded()
        let form = try #require(settingsController.children.compactMap { $0 as? NativeSettingsForm }.first)
        func findSwitch(in view: NSView) -> NSSwitch? {
            if let sw = view as? NSSwitch { return sw }
            for child in view.subviews {
                if let found = findSwitch(in: child) { return found }
            }
            return nil
        }
        let allowSwitch = try #require(findSwitch(in: form.view))
        #expect(allowSwitch.isEnabled)
        #expect(allowSwitch.state == .off)

        allowSwitch.state = .on
        _ = allowSwitch.sendAction(allowSwitch.action, to: allowSwitch.target)
        try await waitForAppKit { FileManager.default.fileExists(atPath: marker.path) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(allowSwitch.isEnabled)

        for _ in 0..<20 {
            if case .failed = controller.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state == .failed("The mobile gateway exited with status 1. Check that port 18792 is available."))
        #expect(allowSwitch.isEnabled)
        // Immediate exit holds the switch briefly so AppKit's click animation can finish, then settles OFF.
        #expect(allowSwitch.state == .on)
        try await Task.sleep(for: .milliseconds(260))
        #expect(allowSwitch.state == .off)
    }

    @Test func pickerUsesNativeMenuAndPreservesSelectionSemantics() throws {
        var value: String?
        let binding = Binding<String?>(get: { value }, set: { value = $0 })
        let options: [OMGSettingsOption<String?>] = [.init(nil, "Follow Config"), .init("on", "On"), .init("off", "Off")]
        let trigger = OMGSettingsMenuTrigger(title: "Test", selection: binding, options: options, enabled: true)
        let coordinator = trigger.makeCoordinator()
        let menu = coordinator.makeMenu()
        #expect(menu.items.map(\.title) == options.map(\.title))
        #expect(menu.items.map(\.state) == [.on, .off, .off])
        coordinator.choose(try #require(menu.item(at: 1)))
        #expect(value == "on")
        coordinator.choose(try #require(menu.item(at: 0)))
        #expect(value == nil)
        coordinator.parent = .init(title: "Test", selection: binding, options: options, enabled: false)
        coordinator.choose(try #require(menu.item(at: 2)))
        #expect(value == nil)
        // Reordered live options must not turn an open menu's item into a different value.
        coordinator.parent = .init(title: "Test", selection: binding, options: options.reversed(), enabled: true)
        coordinator.choose(try #require(menu.item(at: 1)))
        #expect(value == "on")
        coordinator.parent = .init(title: "Test", selection: binding, options: [.init(nil, "Follow Config")], enabled: true)
        coordinator.choose(try #require(menu.item(at: 2)))
        #expect(value == "on")
    }

    @Test func sshHostPickerUsesNativeItemsAndPreservesHostIdentity() throws {
        var value = "local"
        let binding = Binding(get: { value }, set: { value = $0 })
        let items: [SSHHostPicker.Item] = [
            .init(id: "local", title: "Local", detail: "This Mac", symbol: "desktopcomputer"),
            .init(id: "cloud", title: "cloud", detail: "me@example.test:22", status: "Connected"),
        ]
        let picker = SSHHostPicker(items: items, selection: binding, accessibilityLabel: "SSH target")
        let coordinator = picker.makeCoordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        coordinator.update(button)

        #expect(button.itemTitles == ["Select an SSH host…", "Local · This Mac", "cloud · me@example.test:22 · Connected"])
        #expect(button.selectedItem?.representedObject as? String == "local")
        #expect(button.item(at: 0)?.isEnabled == false)
        #expect(button.menu?.autoenablesItems == false)

        coordinator.parent = .init(items: Array(items.reversed()), selection: binding, accessibilityLabel: "SSH target")
        coordinator.update(button)
        #expect(button.selectedItem?.representedObject as? String == "local")

        coordinator.selectItem(button)
        #expect(value == "local")
        button.selectItem(at: 1)
        coordinator.selectItem(button)
        #expect(value == "cloud")
        button.selectItem(at: 1)
        coordinator.parent = .init(items: items, selection: binding, enabled: false, accessibilityLabel: "SSH target")
        coordinator.selectItem(button)
        #expect(value == "cloud")
    }

    @Test func hostMenuPreservesDistinctIdentitiesWithIdenticalDisplayNames() {
        var value = "second"
        let picker = SSHHostPicker(
            items: [.init(id: "first", title: "cloud"), .init(id: "second", title: "cloud")],
            selection: Binding(get: { value }, set: { value = $0 })
        )
        let coordinator = picker.makeCoordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        coordinator.update(button)
        #expect(button.numberOfItems == 3)
        #expect(button.selectedItem?.representedObject as? String == "second")
        button.selectItem(at: 1)
        coordinator.selectItem(button)
        #expect(value == "first")
    }

    @Test func aiIsAStandalonePageThatKeepsItsIdentifier() {
        #expect(OhMyGhosttySettingsTab.navigationOrder.filter { $0 == .agents }.count == 1)
        // Deep links and the notification payload still address the page as `agents`.
        #expect(OhMyGhosttySettingsTab.agents.rawValue == "agents")
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let strings = SettingsStrings(language: language)
            #expect(strings.tabTitle(.agents) == "AI")
            #expect(strings.agentIntegrationSection == "Agent")
            #expect(!strings.officialPluginsCaption.contains("Integrations → Agent"))
            #expect(!strings.officialPluginsCaption.contains("集成 → Agent"))
        }
    }

    @Test func pickerHasFullWidthNativeAccessibleHitTarget() async throws {
        let host = NSHostingView(rootView: OMGSettingsPicker(title: "Mode", selection: .constant("on"),
            options: [.init("on", "Enabled"), .init("off", "Disabled")], showsTitle: false))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 220, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let button = try #require(buttons(host).first { $0.accessibilityLabel() == "Mode" })
        #expect(button.frame.width == 180)
        #expect(button.frame.height == OMGSettingsControlMetrics.height)
        #expect(button.accessibilityValue() as? String == "Enabled")
        #expect(button.accessibilityRole() == .popUpButton)
        #expect(button.isEnabled)
    }

    @Test func mobileAccessControllerTracksLiveConnectedDevicesFromGatewayRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = directory.appendingPathComponent("fake-omgd")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let controller = MobileAccessController(
            executable: executable,
            support: directory,
            port: 18799,
            addressProvider: { "192.168.1.9" },
            tailscaleAddressProvider: { nil }
        )
        defer { controller.stop() }
        #expect(controller.connectedDevices == 0)

        controller.startGatewayStateMonitor()
        let recordURL = directory.appendingPathComponent("mobile-gateway.json")
        let recordJSON = """
        {
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "listen": "192.168.1.9:18799",
          "public_url": "ws://192.168.1.9:18799",
          "token_file": "\(directory.appendingPathComponent("mobile-pair.token").path)",
          "started_at": 1,
          "connected_devices": 2
        }
        """
        let tmpURL = directory.appendingPathComponent(".mobile-gateway.tmp")
        try Data(recordJSON.utf8).write(to: tmpURL)
        _ = try FileManager.default.replaceItemAt(recordURL, withItemAt: tmpURL)

        try await waitForAppKit { controller.connectedDevices == 2 }
        #expect(controller.connectedDevices == 2)

        controller.stop()
        #expect(controller.connectedDevices == 0)
    }

    @Test func agentScopeCaptionsAccuratelyDescribeDefaultHookUpdatesAndRemoteRuntime() {
        let en = SettingsStrings(language: .english)
        let zh = SettingsStrings(language: .simplifiedChinese)

        #expect(en.agentUpdateScopeCaption.contains("Automatic status extension updates are on by default"))
        #expect(!en.agentUpdateScopeCaption.contains("off by default."))
        #expect(zh.agentUpdateScopeCaption.contains("状态扩展自动更新默认开启"))
        #expect(!zh.agentUpdateScopeCaption.contains("扩展自动更新默认关闭"))

        #expect(en.agentSSHScopeCaption.contains("~/.omg/omgd"))
        #expect(!en.agentSSHScopeCaption.contains("no remote daemon is installed"))
        #expect(zh.agentSSHScopeCaption.contains("~/.omg/omgd"))
        #expect(!zh.agentSSHScopeCaption.contains("不在远端安装常驻服务"))
    }

    @Test func mobileAccessRoutesGatewayLaunchThroughHostExecutableWhenProvided() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-mobile-spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let omgd = dir.appendingPathComponent("omgd")
        let host = dir.appendingPathComponent("omg")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: omgd)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: omgd.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)

        let bundled = MobileAccessController(
            executable: omgd,
            support: dir,
            port: 18792,
            addressProvider: { "192.168.1.10" },
            tailscaleAddressProvider: { nil },
            hostExecutable: host
        )
        let bundledSpec = bundled.gatewayLaunchSpecification(listenAddress: "192.168.1.10:18792")
        #expect(bundledSpec.executableURL == host)
        #expect(bundledSpec.arguments == [
            SessionRuntimeHostLauncher.foregroundActionFlag,
            "--",
            omgd.path,
            "mobile", "serve", "--listen", "192.168.1.10:18792",
            "--app-support", dir.path,
            "--token-file", dir.appendingPathComponent("mobile-pair.token").path,
        ])

        let unbundled = MobileAccessController(
            executable: omgd,
            support: dir,
            port: 18792,
            addressProvider: { "192.168.1.10" },
            tailscaleAddressProvider: { nil }
        )
        let directSpec = unbundled.gatewayLaunchSpecification(listenAddress: "192.168.1.10:18792")
        #expect(directSpec.executableURL == omgd)
        #expect(directSpec.arguments.first == "mobile")
    }

    @Test func mobileAccessOrphanReaperBoundsHungStopAndSerializesNetworkModeRestart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-mobile-reap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockURL = dir.appendingPathComponent("mobile-gateway.lock")
        FileManager.default.createFile(atPath: lockURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let flockFn: (Int32, Int32) -> Int32 = flock
        let lockFD = Darwin.open(lockURL.path, O_RDWR)
        #expect(lockFD >= 0)
        #expect(flockFn(lockFD, LOCK_EX | LOCK_NB) == 0)

        // 1. Unlaunchable executable (broken interpreter) must not crash or throw.
        let brokenExec = dir.appendingPathComponent("broken-omgd")
        try Data("#!/nonexistent/interpreter\n".utf8).write(to: brokenExec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brokenExec.path)
        MobileAccessController.stopOrphanedGatewayOffMain(executable: brokenExec, support: dir, timeout: 0.1)

        // 2. Hung `mobile stop` child is bounded by timeout and reaped cleanly.
        let hungExec = dir.appendingPathComponent("hung-omgd")
        try Data("#!/bin/sh\ntrap '' TERM\nsleep 30\n".utf8).write(to: hungExec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hungExec.path)
        let started = Date()
        MobileAccessController.stopOrphanedGatewayOffMain(executable: hungExec, support: dir, timeout: 0.1)
        #expect(Date().timeIntervalSince(started) < 2.0)

        _ = flockFn(lockFD, LOCK_UN)
        Darwin.close(lockFD)

        // 3. `setNetworkMode` waits for the previous gateway process to finish exiting before spawning replacement.
        let eventLog = dir.appendingPathComponent("events.log")
        let gatewayScript = dir.appendingPathComponent("serial-omgd")
        let script = """
        #!/bin/sh
        if [ "$1" = "mobile" ] && [ "$2" = "serve" ]; then
            listen="$4"
            echo "start:$listen" >> "\(eventLog.path)"
            trap 'sleep 0.2; echo "stop:$listen" >> "\(eventLog.path)"; exit 0' TERM
            while :; do sleep 0.05; done
        fi
        exit 0
        """
        try Data(script.utf8).write(to: gatewayScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gatewayScript.path)

        let controller = MobileAccessController(
            executable: gatewayScript,
            support: dir,
            port: 18796,
            addressProvider: { "192.168.1.20" },
            tailscaleAddressProvider: { "100.64.0.9" },
            orphanStopTimeout: 2.0
        )
        defer { controller.stop() }

        controller.start()
        try await waitForAppKit {
            controller.state == .running &&
                ((try? String(contentsOf: eventLog, encoding: .utf8))?.contains("start:192.168.1.20:18796") == true)
        }

        controller.setNetworkMode(.tailscale)
        try await waitForAppKit {
            controller.state == .running &&
                ((try? String(contentsOf: eventLog, encoding: .utf8))?.contains("start:100.64.0.9:18796") == true)
        }

        let lines = try String(contentsOf: eventLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines == [
            "start:192.168.1.20:18796",
            "stop:192.168.1.20:18796",
            "start:100.64.0.9:18796",
        ])
    }

    @Test func globalEventTapUsesActivationObserversInsteadOfTimerWhileAwaitingAccessibility() {
        let tap = GlobalEventTap.shared
        tap.disable()
        defer { tap.disable() }

        var trusted = false
        tap.enable(isTrustedProvider: { trusted })
        #expect(tap.hasConfiguredGlobalKeybinds)
        #expect(tap.isWaitingForPermission)
        #expect(!tap.isTapEnabled)

        // Activation while still untrusted keeps observers registered without creating a tap.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(tap.isWaitingForPermission)

        // Once trust is granted, app activation tears down the pending permission observers immediately.
        trusted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!tap.isWaitingForPermission)

        tap.disable()
        #expect(!tap.hasConfiguredGlobalKeybinds)
        #expect(!tap.isWaitingForPermission)
        #expect(!tap.isTapEnabled)
    }

    @Test func agentErrorsDropInterpreterScaffoldingAndVersionsStayOnOneLine() {
        let message = """
        Claude Code: Traceback (most recent call last):
          File "<stdin>", line 78, in <module>
        RuntimeError: Error: Failed to install native update
        Socket is closed
        Cursor Agent: Traceback (most recent call last):
          File "<stdin>", line 78, in <module>
        RuntimeError: Checking for updates...
        Error: Update failed: [unauthenticated] Error
        """
        let sections = AgentIntegrationErrorHint.sections(message)
        #expect(sections.map(\.agent) == ["Claude Code", "Cursor Agent"])
        #expect(sections[0].lines == ["Failed to install native update", "Socket is closed"])
        #expect(sections[1].lines == ["Checking for updates...", "Update failed: [unauthenticated] Error"])
        #expect(!AgentIntegrationErrorHint.plain(message).contains("Traceback"))
        #expect(AgentIntegrationErrorHint.sections("npm failed")[0].agent == nil)
        let cli = AgentCLIInstallation(version: "Hermes Agent v0.23.2 (2026.9.24)\nInstall directory: /tmp/hermes\nPython: 3.14")
        #expect(cli.displayVersion == "Hermes Agent v0.23.2 (2026.9.24)")
    }

    @Test func numberShortcutFamiliesShareOneModifierChoiceAndRebindTabsThroughTheRealCore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(OMGNumberShortcutModifiers.shared(by: (1...4).map { settings.inspectorPanelShortcut(slot: $0) }) == .option)
        settings.setInspectorPanelShortcut(slot: 2, value: "control+command+2")
        #expect(OMGNumberShortcutModifiers.shared(by: (1...4).map { settings.inspectorPanelShortcut(slot: $0) }) == nil)
        #expect(OMGNumberShortcutModifiers.controlCommand.symbols == "⌃⌘")
        #expect(OMGNumberShortcutModifiers.command.tabKeybindLines.isEmpty)

        settings.tabNumberModifiers = .controlOption
        settings.toggleSidebarShortcut = "option+command+s"
        let overlay = root.appendingPathComponent("appearance.ghostty")
        let config = Ghostty.Config(at: overlay.path)
        #expect(config.loaded && config.errors.isEmpty, "\(config.errors)")
        #expect(config.keyboardShortcut(for: "goto_tab:3")?.modifiers == [.control, .option])
        #expect(config.keyboardShortcut(for: "last_tab")?.modifiers == [.control, .option])

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabNumberModifiers == .controlOption)
        #expect(restored.toggleSidebarShortcut == "option+command+s")
        restored.tabNumberModifiers = nil
        #expect(Ghostty.Config(at: overlay.path).keyboardShortcut(for: "goto_tab:3")?.modifiers == [.command])

        let menu = NSMenu()
        let item = NSMenuItem(title: "Toggle Sidebar", action: #selector(AppDelegate.toggleSidebar(_:)), keyEquivalent: "b")
        item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)
        OMGMenuShortcuts.apply(to: menu, settings: restored)
        #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.option, .command])
        let own = OMGKeyboardShortcut(storageValue: "option+command+s")
        #expect(own?.conflictingMenuItemTitle(in: menu) == "Toggle Sidebar")
        #expect(own?.conflictingMenuItemTitle(in: menu, excluding: #selector(AppDelegate.toggleSidebar(_:))) == nil)
    }
}
