import AppKit
import Combine

extension NativeSettingsController {
    func mobileAccess(_ form: NativeSettingsForm) {
        let mobile = mobileAccessController
        let allow = SettingsSwitch(value: mobile.state.isRunning) { [weak mobile] enabled in
            if enabled {
                mobile?.start()
            } else {
                mobile?.stop()
            }
        }
        let availability = NSTextField(labelWithString: "")
        availability.font = .systemFont(ofSize: 12, weight: .medium)
        let showQR = SettingsActionButton(text("Show QR…", "显示二维码…")) { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                if mobile.invitation == nil { await mobile.refreshInvitation() }
                guard let invitation = mobile.invitation else {
                    if let message = mobile.errorMessage { self.showError(message) }
                    return
                }
                self.presentAsSheet(MobilePairingSheet(
                    invitation: invitation,
                    instructionText: self.text(
                        "Open OMG Mobile → Settings → Devices → Scan QR Code.",
                        "打开 OMG Mobile → 设置 → 设备 → 扫描二维码。"
                    ),
                    copyTitle: self.text("Copy Link", "复制链接"),
                    closeTitle: self.text("Close", "关闭")
                ))
            }
        }
        let copyLink = SettingsActionButton(text("Copy Link", "复制链接")) { [weak self, weak mobile] in
            guard let self, let mobile else { return }
            if mobile.invitation != nil {
                mobile.copyInvitation()
                return
            }
            Task { [weak self, weak mobile] in
                guard let self, let mobile else { return }
                await mobile.refreshInvitation()
                if mobile.invitation != nil {
                    mobile.copyInvitation()
                } else if let message = mobile.errorMessage {
                    self.showError(message)
                }
            }
        }
        let addressValue = valueLabel(mobile.listenAddress ?? text("Unavailable", "不可用"))

        form.section(
            text("iPhone", "iPhone"),
            caption: text(
                "Expose local OMG sessions to paired mobile devices while OMG is running.",
                "OMG 运行时，将本地会话提供给已配对的移动设备。"
            )
        )
        form.row(
            text("Allow paired devices", "允许已配对设备"),
            subtitle: text("Turning this off disconnects mobile devices but keeps their pairing.", "关闭后会断开移动设备，但保留配对。"),
            control: allow
        )
        form.row(
            text("Pair an iPhone", "配对 iPhone"),
            subtitle: text("Open OMG Mobile → Settings → Devices and scan the private code.", "打开 OMG Mobile → 设置 → 设备，扫描私有二维码。"),
            control: showQR
        )
        form.row(
            text("OMG Mobile", "OMG Mobile"),
            subtitle: text("The phone receives the access listed below while this gateway is enabled.", "网关启用期间，手机获得下方列出的访问权限。"),
            control: copyLink
        )

        form.section(text("Network", "网络"))
        form.row(
            text("Connection", "连接方式"),
            subtitle: text("Both devices must be on the same local network.", "两台设备必须处于同一局域网。"),
            control: valueLabel(text("LAN", "局域网"))
        )
        form.row(
            text("Address", "地址"),
            control: addressValue
        )
        form.section(text("Pairing", "配对"))
        form.row(
            text("Gateway status", "网关状态"),
            control: availability
        )
        form.row(
            text("Pair Token", "配对 Token"),
            subtitle: text("Rotating it stops the gateway and disconnects every paired device.", "更换 Token 会停止网关并断开所有已配对设备。"),
            control: SettingsActionButton(text("Revoke…", "撤销…")) { [weak self, weak mobile] in
                guard let self, let mobile else { return }
                self.confirm(
                    self.text("Revoke all mobile pairings?", "撤销所有移动设备配对？"),
                    message: self.text(
                        "The current invitation becomes invalid and every paired device is disconnected. Running sessions are preserved.",
                        "当前邀请将失效，所有已配对设备都会断开；运行中的会话不会被关闭。"
                    ),
                    actionTitle: self.text("Revoke", "撤销")
                ) {
                    mobile.revokePairings()
                }
            }
        )

        form.section(
            text("Access Permissions", "访问许可"),
            caption: text(
                "The current LAN gateway grants one full-control profile.",
                "当前局域网网关授予一份完整控制权限。"
            )
        )
        form.row(text("View sessions", "查看会话"), control: permissionBadge(text("Allowed", "允许")))
        form.row(text("Transfer input and resize", "接管输入与调整尺寸"), control: permissionBadge(text("Allowed", "允许")))
        form.row(text("Browse and edit project files", "浏览与编辑项目文件"), control: permissionBadge(text("Allowed", "允许")))
        form.row(text("Create and close sessions", "创建与关闭会话"), control: permissionBadge(text("Allowed", "允许")))

        let update = { [weak self, weak allow, weak availability, weak addressValue, weak showQR, weak copyLink, weak mobile] in
            guard let self, let mobile else { return }
            allow?.state = mobile.state == .starting || mobile.state.isRunning ? .on : .off
            allow?.isEnabled = mobile.state != .starting
            addressValue?.stringValue = mobile.listenAddress ?? self.text("Unavailable", "不可用")
            switch mobile.state {
            case .stopped:
                availability?.stringValue = self.text("Stopped", "已停止")
                availability?.textColor = .secondaryLabelColor
                availability?.toolTip = mobile.errorMessage
            case .starting:
                availability?.stringValue = self.text("Starting…", "正在启动…")
                availability?.textColor = .systemOrange
                availability?.toolTip = nil
            case .running:
                availability?.stringValue = self.text("Ready", "已就绪")
                availability?.textColor = .systemGreen
                availability?.toolTip = mobile.errorMessage
            case .failed(let reason):
                availability?.stringValue = self.text("Unavailable", "不可用")
                availability?.textColor = .systemRed
                availability?.toolTip = mobile.errorMessage ?? reason
            }
            showQR?.isEnabled = mobile.state.isRunning
            copyLink?.isEnabled = mobile.state.isRunning || mobile.invitation != nil
        }
        update()
        let tokens = mobile.objectWillChange.receive(on: RunLoop.main).sink { _ in update() }
        form.retained.append(tokens)
    }

    private func valueLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func permissionBadge(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .systemGreen
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }

    private func showError(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = text("Could not create pairing invitation", "无法创建配对邀请")
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

private final class MobilePairingSheet: NSViewController {
    private let invitation: String
    private let instructionText: String
    private let copyTitle: String
    private let closeTitle: String

    init(invitation: String, instructionText: String, copyTitle: String, closeTitle: String) {
        self.invitation = invitation
        self.instructionText = instructionText
        self.copyTitle = copyTitle
        self.closeTitle = closeTitle
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 430, height: 540)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "OMG Mobile")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let qr = NSImageView()
        qr.image = MobileAccessController.qrImage(for: invitation)
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 280).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 280).isActive = true
        let instruction = NSTextField(wrappingLabelWithString: instructionText)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        let link = NSTextField(wrappingLabelWithString: invitation)
        link.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        link.textColor = .tertiaryLabelColor
        link.isSelectable = true
        let copy = SettingsActionButton(copyTitle) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.invitation, forType: .string)
        }
        let close = SettingsActionButton(closeTitle) { [weak self] in
            self?.dismiss(self)
        }
        let actions = NSStackView(views: [copy, close])
        actions.spacing = 8
        let stack = NSStackView(views: [title, qr, instruction, link, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            link.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}
