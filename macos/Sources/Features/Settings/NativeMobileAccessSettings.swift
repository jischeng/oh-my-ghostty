import AppKit
import Combine

extension NativeSettingsController {
    func mobileAccess(_ form: NativeSettingsForm) {
        let mobile = mobileAccessController
        form.section(
            text("Gateway", "网关"),
            caption: text(
                "Exposes local OMG sessions to paired devices on this LAN while OMG is running.",
                "OMG 运行时，将本地会话提供给同一局域网内的已配对设备。"
            )
        )
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let startStop = SettingsActionButton(text("Start", "启动")) {}
        startStop.invoke = { [weak self, weak mobile, weak startStop] in
            guard let self, let mobile else { return }
            if mobile.state.isRunning {
                mobile.stop()
            } else {
                mobile.start()
            }
            startStop?.title = mobile.state.isRunning
                ? self.text("Stop", "停止") : self.text("Start", "启动")
        }
        let gatewayStack = NSStackView(views: [status, detail])
        gatewayStack.orientation = .vertical
        gatewayStack.alignment = .leading
        gatewayStack.spacing = 2
        form.embed(gatewayStack, height: 42)
        form.row(text("Gateway control", "网关控制"), control: startStop)

        form.section(text("Pairing", "配对"))
        let qr = NSImageView()
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 190).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 190).isActive = true
        form.embed(qr, height: 198)
        let invitation = NSTextField(wrappingLabelWithString: "")
        invitation.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        invitation.textColor = .secondaryLabelColor
        invitation.isSelectable = true
        invitation.isEditable = false
        form.embed(invitation, height: 44)
        let refresh = SettingsActionButton(text("Refresh", "刷新")) {
            Task { [weak mobile] in await mobile?.refreshInvitation() }
        }
        let copy = SettingsActionButton(text("Copy Link", "复制链接")) { [weak mobile] in
            mobile?.copyInvitation()
        }
        form.row(text("Private invitation", "私有邀请"), control: NSStackView(views: [refresh, copy]))
        form.note(text(
            "Scan this code from OMG Mobile → Settings → Devices. The invitation contains a bearer token; do not share it.",
            "在 OMG Mobile → 设置 → 设备 中扫描。邀请中包含访问令牌，请勿分享。"
        ))

        form.section(
            text("Access Permissions", "访问许可"),
            caption: text(
                "A paired device currently receives full control of sessions exposed by this gateway.",
                "已配对设备当前拥有此网关所暴露会话的完整控制权。"
            )
        )
        form.row(text("View sessions", "查看会话"), control: permissionBadge(text("Allowed", "允许")))
        form.row(text("Transfer input and resize", "接管输入与调整尺寸"), control: permissionBadge(text("Allowed", "允许")))
        form.row(text("Browse and edit project files", "浏览与编辑项目文件"), control: permissionBadge(text("Allowed", "允许")))
        form.row(text("Create and close sessions", "创建与关闭会话"), control: permissionBadge(text("Allowed", "允许")))
        let revoke = SettingsActionButton(text("Revoke All Pairings…", "撤销全部配对…")) { [weak self, weak mobile] in
            guard let self, let mobile else { return }
            self.confirm(
                self.text("Revoke all mobile pairings?", "撤销所有移动设备配对？"),
                message: self.text(
                    "This stops the gateway, invalidates the current invitation, and disconnects every paired device. Running sessions are preserved.",
                    "这会停止网关、使当前邀请失效，并断开所有已配对设备；运行中的会话不会被关闭。"
                ),
                actionTitle: self.text("Revoke", "撤销")
            ) {
                mobile.revokePairings()
            }
        }
        form.row(text("Manage access", "管理访问"), control: revoke)

        let update = { [weak self, weak status, weak detail, weak startStop, weak qr, weak invitation, weak mobile] in
            guard let self, let mobile else { return }
            switch mobile.state {
            case .stopped:
                status?.stringValue = "\u{25CF} " + self.text("Stopped", "已停止")
                status?.textColor = .secondaryLabelColor
                detail?.stringValue = self.text("Paired devices cannot connect.", "已配对设备无法连接。")
            case .starting:
                status?.stringValue = "\u{25CF} " + self.text("Starting…", "正在启动…")
                status?.textColor = .systemOrange
                detail?.stringValue = mobile.listenAddress ?? ""
            case .running:
                status?.stringValue = "\u{25CF} " + self.text("Ready", "已就绪")
                status?.textColor = .systemGreen
                detail?.stringValue = mobile.listenAddress ?? ""
            case .failed(let reason):
                status?.stringValue = "\u{25CF} " + self.text("Unavailable", "不可用")
                status?.textColor = .systemRed
                detail?.stringValue = reason
            }
            startStop?.title = mobile.state.isRunning
                ? self.text("Stop", "停止") : self.text("Start", "启动")
            if let invitation = mobile.invitation,
               let image = MobileAccessController.qrImage(for: invitation) {
                qr?.image = image
                qr?.contentTintColor = nil
            } else {
                qr?.image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: self.text("Pairing QR code", "配对二维码"))
                qr?.contentTintColor = .secondaryLabelColor
            }
            invitation?.stringValue = mobile.invitation ?? mobile.errorMessage ?? ""
            refresh.isEnabled = mobile.state.isRunning
            copy.isEnabled = mobile.invitation != nil
        }
        update()
        let tokens = mobile.objectWillChange.receive(on: RunLoop.main).sink { _ in update() }
        form.retained.append(tokens)
        if mobile.state.isRunning, mobile.invitation == nil {
            Task { [weak mobile] in await mobile?.refreshInvitation() }
        }
    }

    private func permissionBadge(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .systemGreen
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }
}
