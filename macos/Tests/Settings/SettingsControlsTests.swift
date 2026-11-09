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
        #expect(form.rowTitles == ["允许 iPhone 连接", "网关状态", "网络接口", "外部 WSS 入口", "配对密钥"])

        controller.revokePairings()
        #expect(!controller.isEnabledPreference)
        #expect(!controller.hasPairing)
        #expect(controller.invitation == nil)
        #expect(controller.state == .stopped)
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

    @Test func agentIsAStandalonePageAndHasConsistentName() {
        #expect(OhMyGhosttySettingsTab.navigationOrder.filter { $0 == .agents }.count == 1)
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let strings = SettingsStrings(language: language)
            #expect(strings.tabTitle(.agents) == "Agent")
            #expect(strings.agentIntegrationSection == "Agent")
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
}
