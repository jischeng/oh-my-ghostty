import AppKit
import Combine

extension NativeSettingsController {
    func mobileAccess(_ form: NativeSettingsForm) {
        let mobile = mobileAccessController
        let allowTitle = text("Allow iPhone Connections", "允许 iPhone 连接")
        var lastStartAttempt: ContinuousClock.Instant?
        var pendingSwitchOff: DispatchWorkItem?
        let allow = SettingsSwitch(value: mobile.state == .starting || mobile.state.isRunning) { [weak mobile] enabled in
            pendingSwitchOff?.cancel()
            pendingSwitchOff = nil
            if enabled {
                lastStartAttempt = .now
                mobile?.start()
            } else {
                lastStartAttempt = nil
                mobile?.stop()
            }
        }
        let statusControl = MobileGatewayStatusControl()
        let copyTitle = text("Copy Pairing Link", "复制配对链接")
        let copiedTitle = text("Copied ✓", "已复制 ✓")
        let enlargeTitle = text("Enlarge QR Code…", "放大二维码…")

        let copyLink = SettingsActionButton(copyTitle) {}
        let showQR = SettingsActionButton(enlargeTitle) {}
        let revokeTitle = text("Revoke All…", "撤销所有配对…")
        let revokeButton = SettingsActionButton(revokeTitle) { [weak self, weak mobile] in
            guard let self, let mobile else { return }
            self.confirm(
                self.text("Revoke all mobile pairings?", "撤销所有移动设备配对？"),
                message: self.text(
                    "The current QR code and invitation link become invalid immediately and every paired device is disconnected. Running terminal sessions are preserved.",
                    "当前二维码与配对链接将立即失效，所有已配对设备都会断开；正在运行的终端会话不会被关闭。"
                ),
                actionTitle: self.text("Revoke", "撤销")
            ) {
                mobile.revokePairings()
            }
        }

        let pairingCard = MobilePairingHeroCard(
            title: text("Scan QR Code with OMG Mobile", "使用 OMG Mobile 扫码配对"),
            stepsText: text(
                "1. Open OMG Mobile on your iPhone and go to Settings → Devices.\n2. Scan the QR code on the left, or copy the pairing link below.",
                "1. 在 iPhone 上打开 OMG Mobile，进入「设置 → 设备」。\n2. 扫描左侧二维码，或复制下方配对链接完成连接。"
            ),
            capabilities: [
                ("terminal", text("View & create sessions", "查看与创建终端会话")),
                ("keyboard", text("Live input & resize", "实时输入与尺寸同步")),
                ("folder", text("Browse & edit files", "浏览与编辑项目文件")),
                ("lock.shield", text("Private LAN token auth", "局域网私有密钥鉴权")),
            ],
            copyButton: copyLink,
            enlargeButton: showQR
        )

        copyLink.invoke = { [weak self, weak mobile, weak copyLink] in
            guard let self, let mobile else { return }
            let flashCopied = {
                copyLink?.title = copiedTitle
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copyLink?.title = copyTitle
                }
            }
            if mobile.invitation != nil {
                mobile.copyInvitation()
                flashCopied()
                return
            }
            Task { [weak self, weak mobile] in
                guard let self, let mobile else { return }
                await mobile.refreshInvitation()
                if mobile.invitation != nil {
                    mobile.copyInvitation()
                    flashCopied()
                } else if let message = mobile.errorMessage {
                    self.showError(message)
                }
            }
        }

        showQR.invoke = { [weak self, weak mobile] in
            guard let self, let mobile else { return }
            Task { [weak self, weak mobile] in
                guard let self, let mobile else { return }
                if mobile.invitation == nil { await mobile.refreshInvitation() }
                guard let invitation = mobile.invitation else {
                    if let message = mobile.errorMessage { self.showError(message) }
                    return
                }
                self.presentAsSheet(MobilePairingSheet(
                    invitation: invitation,
                    endpoint: mobile.displayEndpoint ?? self.text("LAN", "局域网"),
                    titleText: self.text("Pair iPhone with OMG", "配对 iPhone"),
                    instructionText: self.text(
                        "Open OMG Mobile → Settings → Devices → Scan QR Code.",
                        "打开 OMG Mobile → 设置 → 设备 → 扫描二维码。"
                    ),
                    copyTitle: copyTitle,
                    copiedTitle: copiedTitle,
                    closeTitle: self.text("Done", "完成")
                ))
            }
        }

        let networkTitles: () -> [String] = { [weak self, weak mobile] in
            guard let self else { return ["LAN", "Tailscale"] }
            let lanText = mobile?.lanAddress.map { self.text("Wi-Fi / LAN (\($0))", "局域网 (\($0))") }
                ?? self.text("Wi-Fi / LAN", "局域网")
            let tsText = mobile?.tailscaleAddress.map { "Tailscale (\($0))" }
                ?? self.text("Tailscale (Not Connected)", "Tailscale（未连接）")
            return [lanText, tsText]
        }
        let networkPopup = SettingsPopup(
            titles: networkTitles(),
            selected: mobile.networkMode == .tailscale ? 1 : 0
        ) { [weak mobile] index in
            mobile?.setNetworkMode(index == 1 ? .tailscale : .lan)
        }

        let publicURLField = SettingsTextField(
            mobile.publicURL,
            placeholder: "wss://example.com:18791"
        ) { [weak self, weak mobile] value in
            guard let self, let mobile else { return }
            if !mobile.setPublicURL(value), let message = mobile.errorMessage {
                self.showError(message)
            }
        }
        publicURLField.action = #selector(NSTextField.selectText(_:))

        form.section(text("LAN Gateway", "局域网网关"))
        form.row(
            allowTitle,
            subtitle: text(
                "Share local terminal sessions and workspaces with paired iPhones on the same Wi-Fi / LAN while OMG is running.",
                "在 OMG 运行期间，将本地终端会话与工作区安全共享给同一局域网下的 iPhone。"
            ),
            control: allow
        )
        let statusRow = form.row(
            text("Gateway Status", "网关状态"),
            subtitle: text(
                "Both devices must be on the same local network.",
                "iPhone 与当前 Mac 需处于同一局域网（Wi-Fi）。"
            ),
            control: statusControl
        )
        form.row(
            text("Network Interface", "网络接口"),
            subtitle: text(
                "Choose Wi-Fi / LAN for local access, or Tailscale (100.64.0.0/10) for zero-config encrypted remote access.",
                "同 Wi-Fi 下选择「局域网」；异地连接无需公网主机，开启 Tailscale 即可直接互联。"
            ),
            control: networkPopup
        )
        form.row(
            text("External WSS URL", "外部 WSS 入口"),
            subtitle: text(
                "Optional. If exposed via your own VPS / Nginx reverse proxy, enter its wss:// URL so the QR code uses that TLS endpoint.",
                "可选。若通过自有 VPS / Nginx 反向代理暴露网关（本地转发 127.0.0.1:\(mobile.port)），填写 wss:// 地址后二维码将使用该加密入口。"
            ),
            control: publicURLField
        )
        let statusSubtitle = statusRow?.labels.arrangedSubviews.dropFirst().first as? NSTextField

        form.section(text("Device Pairing", "设备配对"))
        form.addCustomRow(pairingCard)
        form.row(
            text("Pairing Token", "配对密钥"),
            subtitle: text(
                "Resetting the token stops the gateway, disconnects all paired devices, and invalidates previous QR codes.",
                "重置密钥会停止网关并断开所有已配对设备，已生成的二维码与链接将立即失效。"
            ),
            control: revokeButton
        )

        var refreshingInvite = false
        let switchSettleDuration = Duration.milliseconds(200)
        let update = { [weak self, weak allow, weak statusControl, weak statusSubtitle, weak networkPopup, weak publicURLField, weak pairingCard, weak showQR, weak copyLink, weak revokeButton, weak mobile] in
            guard let self, let mobile else { return }
            let desiredOn = mobile.state == .starting || mobile.state.isRunning
            if desiredOn {
                pendingSwitchOff?.cancel()
                pendingSwitchOff = nil
                if mobile.state == .starting, lastStartAttempt == nil {
                    lastStartAttempt = .now
                }
                if allow?.state != .on { allow?.state = .on }
            } else if case .failed = mobile.state,
                      allow?.state == .on,
                      let started = lastStartAttempt,
                      started.duration(to: .now) < switchSettleDuration {
                if pendingSwitchOff == nil {
                    let remaining = switchSettleDuration - started.duration(to: .now)
                    let seconds = Double(remaining.components.seconds)
                        + Double(remaining.components.attoseconds) / 1e18
                    let work = DispatchWorkItem { [weak allow, weak mobile] in
                        pendingSwitchOff = nil
                        lastStartAttempt = nil
                        guard let mobile, mobile.state != .starting, !mobile.state.isRunning else { return }
                        if allow?.state != .off { allow?.state = .off }
                    }
                    pendingSwitchOff = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, seconds), execute: work)
                }
            } else {
                pendingSwitchOff?.cancel()
                pendingSwitchOff = nil
                lastStartAttempt = nil
                if allow?.state != .off { allow?.state = .off }
            }
            let titles = networkTitles()
            if networkPopup?.numberOfItems == 2 {
                networkPopup?.item(at: 0)?.title = titles[0]
                networkPopup?.item(at: 1)?.title = titles[1]
                networkPopup?.selectItem(at: mobile.networkMode == .tailscale ? 1 : 0)
            }
            if publicURLField?.currentEditor() == nil {
                publicURLField?.stringValue = mobile.publicURL
            }
            let endpoint = mobile.listenAddress ?? self.text("Unavailable", "不可用")
            let modePrefix = mobile.isUsingTailscale ? "Tailscale · " : "LAN · "
            let activeEndpoint = mobile.publicURL.isEmpty ? (modePrefix + endpoint) : mobile.publicURL

            switch mobile.state {
            case .stopped:
                statusControl?.configure(
                    endpoint: mobile.displayEndpoint ?? endpoint,
                    statusText: self.text("Stopped", "未启用"),
                    color: .secondaryLabelColor
                )
                statusSubtitle?.stringValue = self.text(
                    "Gateway is off. Paired devices are disconnected while off, but their pairing is kept.",
                    "网关未启用；关闭期间移动设备会暂时断开，但配对关系仍会保留。"
                )
                statusSubtitle?.textColor = .secondaryLabelColor
                pairingCard?.update(
                    qrImage: nil,
                    placeholderSymbol: "qrcode.viewfinder",
                    placeholderText: self.text("Turn on gateway to show QR", "开启上方网关后显示二维码"),
                    isRunning: false
                )
            case .starting:
                statusControl?.configure(
                    endpoint: mobile.displayEndpoint ?? endpoint,
                    statusText: self.text("Starting…", "正在启动…"),
                    color: .systemOrange
                )
                statusSubtitle?.stringValue = self.text(
                    "Starting local mobile gateway on LAN…",
                    "正在启动局域网移动网关并准备配对信息…"
                )
                statusSubtitle?.textColor = .secondaryLabelColor
                pairingCard?.update(
                    qrImage: nil,
                    placeholderSymbol: "qrcode",
                    placeholderText: self.text("Generating QR code…", "正在生成配对二维码…"),
                    isRunning: false
                )
            case .running:
                let statusText = mobile.connectedDevices > 0
                    ? self.text("\(mobile.connectedDevices) Connected", "\(mobile.connectedDevices) 台已连接")
                    : self.text("Ready", "已就绪")
                statusControl?.configure(
                    endpoint: activeEndpoint,
                    statusText: statusText,
                    color: .systemGreen
                )
                statusSubtitle?.stringValue = mobile.publicURL.isEmpty
                    ? self.text(
                        "Listening on local network (and 127.0.0.1:\(mobile.port)). Keep your iPhone and this Mac on the same Wi-Fi / LAN.",
                        "正在局域网（及 127.0.0.1:\(mobile.port)）监听连接，请确保 iPhone 与当前 Mac 处于同一局域网。"
                    )
                    : self.text(
                        "Listening locally on \(endpoint) & 127.0.0.1:\(mobile.port); QR code uses \(mobile.publicURL).",
                        "本地监听 \(endpoint) 与 127.0.0.1:\(mobile.port)；配对二维码使用 \(mobile.publicURL)。"
                    )
                statusSubtitle?.textColor = .secondaryLabelColor
                if let invitation = mobile.invitation, let qr = MobileAccessController.qrImage(for: invitation) {
                    pairingCard?.update(
                        qrImage: qr,
                        placeholderSymbol: "qrcode",
                        placeholderText: "",
                        isRunning: true
                    )
                } else {
                    pairingCard?.update(
                        qrImage: nil,
                        placeholderSymbol: "qrcode",
                        placeholderText: self.text("Loading QR code…", "正在加载二维码…"),
                        isRunning: true
                    )
                    if !refreshingInvite {
                        refreshingInvite = true
                        Task { @MainActor [weak mobile] in
                            await mobile?.refreshInvitation()
                            refreshingInvite = false
                        }
                    }
                }
            case .failed(let reason):
                statusControl?.configure(
                    endpoint: endpoint,
                    statusText: self.text("Unavailable", "不可用"),
                    color: .systemRed
                )
                statusSubtitle?.stringValue = mobile.errorMessage ?? reason
                statusSubtitle?.textColor = .systemRed
                pairingCard?.update(
                    qrImage: nil,
                    placeholderSymbol: "exclamationmark.triangle",
                    placeholderText: self.text("Gateway unavailable", "网关暂不可用"),
                    isRunning: false
                )
            }

            showQR?.isEnabled = mobile.state.isRunning
            copyLink?.isEnabled = mobile.state.isRunning || mobile.invitation != nil
            revokeButton?.isEnabled = mobile.state.isRunning || mobile.hasPairing || mobile.invitation != nil
        }

        update()
        let tokens = mobile.objectWillChange.receive(on: RunLoop.main).sink { _ in update() }
        form.retained.append(tokens)

        addPhoneProvisioningSection(to: form, provisioner: mobileDeviceProvisioner)
    }

    private func addPhoneProvisioningSection(
        to form: NativeSettingsForm,
        provisioner: MobileDeviceProvisioner
    ) {
        let devicePopup = SettingsPopup(titles: [text("Scanning…", "正在扫描…")], selected: 0) { [weak provisioner] index in
            guard let provisioner, index >= 0, index < provisioner.devices.count else { return }
            provisioner.selectDevice(udid: provisioner.devices[index].udid)
        }
        let scanButton = SettingsActionButton(text("Scan", "扫描")) { [weak provisioner] in
            guard let provisioner else { return }
            Task { @MainActor in await provisioner.scanDevices(silent: false) }
        }
        let deviceControl = NSStackView(views: [devicePopup, scanButton])
        deviceControl.orientation = .horizontal
        deviceControl.spacing = 8

        let signingLabel = NSTextField(labelWithString: "")
        signingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        signingLabel.alignment = .right

        let installButton = SettingsActionButton(text("Install / Refresh Now", "立即安装 / 刷新")) { [weak provisioner] in
            guard let provisioner else { return }
            let forceRenew: Bool
            switch provisioner.expiryStatus {
            case .missing, .expired, .expiringSoon:
                forceRenew = true
            case .unknown, .valid:
                forceRenew = false
            }
            provisioner.installOrRefreshSelectedDevice(forcePortalRefresh: forceRenew)
        }
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let installControl = NSStackView(views: [progress, installButton])
        installControl.orientation = .horizontal
        installControl.spacing = 8

        let autoRefreshSwitch = SettingsSwitch(value: provisioner.autoRefreshEnabled) { [weak provisioner] enabled in
            provisioner?.setAutoRefreshEnabled(enabled)
        }

        let copySourceTitle = text("Copy Source URL", "复制订阅地址")
        let copiedSourceTitle = text("Copied ✓", "已复制 ✓")
        let copySourceButton = SettingsActionButton(copySourceTitle) {}
        copySourceButton.invoke = { [weak provisioner, weak copySourceButton] in
            provisioner?.copySideStoreSourceURL()
            copySourceButton?.title = copiedSourceTitle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak copySourceButton] in
                copySourceButton?.title = copySourceTitle
            }
        }

        form.section(text("iPhone App (OMG Mobile)", "iPhone App（OMG Mobile）"))
        let deviceRow = form.row(
            text("Target Device", "目标设备"),
            subtitle: text("Connect via USB once for pairing; subsequent updates run over Wi-Fi.", "首次配对需使用 USB 连接并信任 Mac，后续可通过 Wi-Fi 无线安装与续签。"),
            control: deviceControl
        )
        let signingRow = form.row(
            text("7-Day Signing Status", "7 天签名状态"),
            subtitle: text("Checks cached provisioning profiles without contacting Apple unless renewal is needed.", "优先使用本地缓存描述文件签名，仅在缺失或快到期时连接 Apple 更新。"),
            control: signingLabel
        )
        let installRow = form.row(
            text("Install or Refresh App", "安装 / 刷新 iPhone App"),
            subtitle: text("Preserves your existing bundle ID and device pairings.", "自动保留已安装的 Bundle ID，不会重置手机上的配对密钥与记录。"),
            control: installControl
        )
        form.row(
            text("Wi-Fi Auto-Refresh", "Wi-Fi 自动续签"),
            subtitle: text(
                "Opt-in: silently renews 7-day signing when < 48h remain and your iPhone is reachable on Wi-Fi.",
                "可选：开启后，当 7 天签名剩余不足 48 小时且 iPhone 在同一 Wi-Fi 下可达时，在后台自动续签（默认关闭）。"
            ),
            control: autoRefreshSwitch
        )
        form.row(
            text("SideStore Source", "SideStore 订阅源"),
            subtitle: MobileDeviceProvisioner.altStoreSourceURL,
            control: copySourceButton
        )

        let deviceSubtitle = deviceRow?.labels.arrangedSubviews.dropFirst().first as? NSTextField
        let signingSubtitle = signingRow?.labels.arrangedSubviews.dropFirst().first as? NSTextField
        let installSubtitle = installRow?.labels.arrangedSubviews.dropFirst().first as? NSTextField

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let updateProvisioningUI = { [weak self, weak provisioner, weak devicePopup, weak scanButton, weak deviceSubtitle, weak signingLabel, weak signingSubtitle, weak installButton, weak progress, weak installSubtitle, weak autoRefreshSwitch] in
            guard let self, let provisioner else { return }

            if let popup = devicePopup {
                popup.removeAllItems()
                if provisioner.devices.isEmpty {
                    popup.addItem(withTitle: provisioner.isScanning
                        ? self.text("Scanning…", "正在扫描…")
                        : self.text("No iPhone Found", "未检测到已配对 iPhone"))
                    popup.isEnabled = false
                } else {
                    for dev in provisioner.devices {
                        let suffix = dev.osVersion.isEmpty ? dev.transport.displayLabel : "iOS \(dev.osVersion) · \(dev.transport.displayLabel)"
                        popup.addItem(withTitle: "\(dev.name) (\(suffix))")
                    }
                    popup.isEnabled = !provisioner.isBusy
                    if let selected = provisioner.selectedDevice,
                       let idx = provisioner.devices.firstIndex(of: selected) {
                        popup.selectItem(at: idx)
                    }
                }
            }
            scanButton?.isEnabled = !provisioner.isBusy

            if let dev = provisioner.selectedDevice {
                let installedLabel = dev.installedBundleID ?? self.text("Not probed / new install", "未检测到已安装版本（将全新安装）")
                deviceSubtitle?.stringValue = "UDID: \(dev.udid) · \(dev.transport.displayLabel) · \(installedLabel)"
            } else {
                deviceSubtitle?.stringValue = self.text(
                    "Connect via USB once, enable Developer Mode on iPhone, then click Scan.",
                    "请先通过 USB 连接 iPhone 并开启开发者模式，然后点击「扫描」。"
                )
            }

            let teamText = provisioner.activeTeamID ?? self.text("None", "无")
            let bundleText = provisioner.activeBundleID
            switch provisioner.expiryStatus {
            case .unknown:
                signingLabel?.stringValue = self.text("Unknown", "待检测")
                signingLabel?.textColor = .secondaryLabelColor
                signingSubtitle?.stringValue = "Team: \(teamText) · Bundle ID: \(bundleText)"
            case .missing(let reason):
                signingLabel?.stringValue = self.text("Not Provisioned", "未签名 / 无描述文件")
                signingLabel?.textColor = .systemOrange
                signingSubtitle?.stringValue = reason
            case .expired(let expiredAt):
                signingLabel?.stringValue = self.text("Expired", "已过期")
                signingLabel?.textColor = .systemRed
                signingSubtitle?.stringValue = "Team: \(teamText) · Bundle ID: \(bundleText) · " + self.text(
                    "Expired \(formatter.string(from: expiredAt))",
                    "已于 \(formatter.string(from: expiredAt)) 过期"
                )
            case .expiringSoon(let expiresAt, let remaining):
                let hours = max(1, Int(remaining / 3600))
                signingLabel?.stringValue = self.text("Expiring (\(hours)h left)", "即将过期（剩余 \(hours) 小时）")
                signingLabel?.textColor = .systemOrange
                signingSubtitle?.stringValue = "Team: \(teamText) · Bundle ID: \(bundleText) · " + self.text(
                    "Valid until \(formatter.string(from: expiresAt))",
                    "有效期至 \(formatter.string(from: expiresAt))"
                )
            case .valid(let expiresAt, let remaining):
                let days = Int(remaining / 86400)
                let hours = Int((remaining.truncatingRemainder(dividingBy: 86400)) / 3600)
                signingLabel?.stringValue = self.text("Valid (\(days)d \(hours)h left)", "有效（剩余 \(days) 天 \(hours) 小时）")
                signingLabel?.textColor = .systemGreen
                signingSubtitle?.stringValue = "Team: \(teamText) · Bundle ID: \(bundleText) · " + self.text(
                    "Valid until \(formatter.string(from: expiresAt))",
                    "有效期至 \(formatter.string(from: expiresAt))"
                )
            }

            switch provisioner.operationState {
            case .idle:
                progress?.stopAnimation(nil)
                installButton?.isEnabled = !provisioner.isBusy
                installSubtitle?.stringValue = self.text(
                    "Builds or re-signs OMGMobile and deploys directly over USB or Wi-Fi without opening Xcode.",
                    "无需打开 Xcode，直接通过 USB 或 Wi-Fi 完成签名并安装到 iPhone。"
                )
                installSubtitle?.textColor = .secondaryLabelColor
            case .installing(let step):
                progress?.startAnimation(nil)
                installButton?.isEnabled = false
                installSubtitle?.stringValue = step
                installSubtitle?.textColor = .secondaryLabelColor
            case .succeeded(let summary):
                progress?.stopAnimation(nil)
                installButton?.isEnabled = !provisioner.isBusy
                installSubtitle?.stringValue = summary
                installSubtitle?.textColor = .systemGreen
            case .failed(let message):
                progress?.stopAnimation(nil)
                installButton?.isEnabled = !provisioner.isBusy
                installSubtitle?.stringValue = message
                installSubtitle?.textColor = .systemRed
            }

            let desiredAuto = provisioner.autoRefreshEnabled ? NSControl.StateValue.on : .off
            if autoRefreshSwitch?.state != desiredAuto {
                autoRefreshSwitch?.state = desiredAuto
            }
        }

        updateProvisioningUI()
        let sub = provisioner.objectWillChange.receive(on: RunLoop.main).sink { _ in updateProvisioningUI() }
        form.retained.append(sub)

        if !OMGApplicationEnvironment.isRunningTests, provisioner.lastUpdatedAt == nil {
            Task { @MainActor [weak provisioner] in
                await provisioner?.scanDevices(silent: true)
            }
        }
    }

    private func showError(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = text("Could not create pairing invitation", "无法创建配对邀请")
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

private final class SharpQRImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        super.draw(dirtyRect)
    }
}

private final class MobileGatewayStatusControl: NSView {
    private let endpointBox = NSBox()
    private let endpointLabel = NSTextField(labelWithString: "")
    private let statusBox = NSBox()
    private let dotView = NSBox()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        endpointBox.boxType = .custom
        endpointBox.borderType = .lineBorder
        endpointBox.borderWidth = 1
        endpointBox.cornerRadius = 6
        endpointBox.fillColor = NSColor.labelColor.withAlphaComponent(0.045)
        endpointBox.borderColor = NSColor.labelColor.withAlphaComponent(0.09)
        endpointBox.contentViewMargins = .zero

        endpointLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        endpointLabel.textColor = .secondaryLabelColor
        endpointLabel.isSelectable = true
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false
        endpointBox.contentView?.addSubview(endpointLabel)

        statusBox.boxType = .custom
        statusBox.borderType = .lineBorder
        statusBox.borderWidth = 1
        statusBox.cornerRadius = 11
        statusBox.contentViewMargins = .zero

        dotView.boxType = .custom
        dotView.borderType = .noBorder
        dotView.cornerRadius = 3.5
        dotView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let badgeStack = NSStackView(views: [dotView, statusLabel])
        badgeStack.orientation = .horizontal
        badgeStack.alignment = .centerY
        badgeStack.spacing = 6
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        statusBox.contentView?.addSubview(badgeStack)

        let row = NSStackView(views: [endpointBox, statusBox])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        guard let endpointContent = endpointBox.contentView,
              let statusContent = statusBox.contentView else { return }

        NSLayoutConstraint.activate([
            endpointLabel.leadingAnchor.constraint(equalTo: endpointContent.leadingAnchor, constant: 8),
            endpointLabel.trailingAnchor.constraint(equalTo: endpointContent.trailingAnchor, constant: -8),
            endpointLabel.topAnchor.constraint(equalTo: endpointContent.topAnchor, constant: 4),
            endpointLabel.bottomAnchor.constraint(equalTo: endpointContent.bottomAnchor, constant: -4),

            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),

            badgeStack.leadingAnchor.constraint(equalTo: statusContent.leadingAnchor, constant: 9),
            badgeStack.trailingAnchor.constraint(equalTo: statusContent.trailingAnchor, constant: -9),
            badgeStack.topAnchor.constraint(equalTo: statusContent.topAnchor, constant: 4),
            badgeStack.bottomAnchor.constraint(equalTo: statusContent.bottomAnchor, constant: -4),

            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(endpoint: String, statusText: String, color: NSColor) {
        endpointLabel.stringValue = endpoint
        statusLabel.stringValue = statusText
        statusLabel.textColor = color
        dotView.fillColor = color
        statusBox.fillColor = color.withAlphaComponent(0.12)
        statusBox.borderColor = color.withAlphaComponent(0.24)
    }
}

private final class MobilePairingHeroCard: NSView {
    private let qrContainer = NSBox()
    private let qrImageView = SharpQRImageView()
    private let placeholderStack = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private var capabilityIcons: [NSImageView] = []

    init(
        title: String,
        stepsText: String,
        capabilities: [(symbol: String, label: String)],
        copyButton: NSButton,
        enlargeButton: NSButton
    ) {
        super.init(frame: .zero)
        qrContainer.boxType = .custom
        qrContainer.borderType = .lineBorder
        qrContainer.borderWidth = 1
        qrContainer.cornerRadius = 12
        qrContainer.contentViewMargins = .zero
        qrContainer.translatesAutoresizingMaskIntoConstraints = false

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderIcon.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        placeholderIcon.contentTintColor = .tertiaryLabelColor
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 11, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 8
        placeholderStack.addArrangedSubview(placeholderIcon)
        placeholderStack.addArrangedSubview(placeholderLabel)
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false

        if let content = qrContainer.contentView {
            content.addSubview(qrImageView)
            content.addSubview(placeholderStack)
            NSLayoutConstraint.activate([
                qrContainer.widthAnchor.constraint(equalToConstant: 148),
                qrContainer.heightAnchor.constraint(equalToConstant: 148),
                qrImageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                qrImageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                qrImageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                qrImageView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
                placeholderStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                placeholderStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                placeholderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 124),
            ])
        }

        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.textColor = .labelColor
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let steps = NSTextField(wrappingLabelWithString: stepsText)
        steps.font = .systemFont(ofSize: 12)
        steps.textColor = .secondaryLabelColor
        steps.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        for pair in stride(from: 0, to: capabilities.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            for index in pair..<min(pair + 2, capabilities.count) {
                let item = capabilities[index]
                let chip = makeCapabilityChip(symbol: item.symbol, title: item.label)
                row.addArrangedSubview(chip)
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        let actions = NSStackView(views: [copyButton, enlargeButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let rightColumn = NSStackView(views: [heading, steps, grid, actions])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 10
        rightColumn.setCustomSpacing(12, after: grid)
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        let mainRow = NSStackView(views: [qrContainer, rightColumn])
        mainRow.orientation = .horizontal
        mainRow.alignment = .centerY
        mainRow.spacing = 20
        mainRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainRow)

        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            steps.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            grid.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            mainRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainRow.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            mainRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeCapabilityChip(symbol: String, title: String) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.borderWidth = 0.5
        box.cornerRadius = 6
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
        box.borderColor = NSColor.labelColor.withAlphaComponent(0.08)
        box.contentViewMargins = .zero

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        capabilityIcons.append(icon)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        if let content = box.contentView {
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 5),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            ])
        }
        return box
    }

    func update(qrImage: NSImage?, placeholderSymbol: String, placeholderText: String, isRunning: Bool) {
        if let qrImage {
            qrImageView.image = qrImage
            qrImageView.isHidden = false
            placeholderStack.isHidden = true
            qrContainer.fillColor = .white
            qrContainer.borderColor = NSColor.black.withAlphaComponent(0.12)
        } else {
            qrImageView.image = nil
            qrImageView.isHidden = true
            placeholderStack.isHidden = false
            placeholderIcon.image = NSImage(systemSymbolName: placeholderSymbol, accessibilityDescription: nil)
            placeholderLabel.stringValue = placeholderText
            qrContainer.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
            qrContainer.borderColor = NSColor.labelColor.withAlphaComponent(0.10)
        }
        let tint: NSColor = isRunning ? .systemGreen : .tertiaryLabelColor
        for icon in capabilityIcons {
            icon.contentTintColor = tint
        }
    }
}

private final class MobilePairingSheet: NSViewController {
    private let invitation: String
    private let endpoint: String
    private let titleText: String
    private let instructionText: String
    private let copyTitle: String
    private let copiedTitle: String
    private let closeTitle: String

    init(
        invitation: String,
        endpoint: String,
        titleText: String,
        instructionText: String,
        copyTitle: String,
        copiedTitle: String,
        closeTitle: String
    ) {
        self.invitation = invitation
        self.endpoint = endpoint
        self.titleText = titleText
        self.instructionText = instructionText
        self.copyTitle = copyTitle
        self.copiedTitle = copiedTitle
        self.closeTitle = closeTitle
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 420, height: 500)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let endpointBadge = NSTextField(labelWithString: "LAN · " + endpoint)
        endpointBadge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        endpointBadge.textColor = .secondaryLabelColor

        let qrCard = NSBox()
        qrCard.boxType = .custom
        qrCard.borderType = .lineBorder
        qrCard.borderWidth = 1
        qrCard.cornerRadius = 16
        qrCard.fillColor = .white
        qrCard.borderColor = NSColor.black.withAlphaComponent(0.12)
        qrCard.contentViewMargins = .zero
        qrCard.translatesAutoresizingMaskIntoConstraints = false

        let qr = SharpQRImageView()
        qr.image = MobileAccessController.qrImage(for: invitation)
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints = false
        if let content = qrCard.contentView {
            content.addSubview(qr)
            NSLayoutConstraint.activate([
                qrCard.widthAnchor.constraint(equalToConstant: 260),
                qrCard.heightAnchor.constraint(equalToConstant: 260),
                qr.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                qr.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                qr.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                qr.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ])
        }

        let instruction = NSTextField(wrappingLabelWithString: instructionText)
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center

        let linkBox = NSBox()
        linkBox.boxType = .custom
        linkBox.borderType = .lineBorder
        linkBox.borderWidth = 0.5
        linkBox.cornerRadius = 8
        linkBox.fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        linkBox.borderColor = NSColor.labelColor.withAlphaComponent(0.10)
        linkBox.contentViewMargins = .zero

        let link = NSTextField(labelWithString: invitation)
        link.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        link.textColor = .tertiaryLabelColor
        link.lineBreakMode = .byTruncatingMiddle
        link.isSelectable = true
        link.translatesAutoresizingMaskIntoConstraints = false
        if let content = linkBox.contentView {
            content.addSubview(link)
            NSLayoutConstraint.activate([
                link.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                link.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                link.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
                link.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            ])
        }

        let copy = SettingsActionButton(copyTitle) {}
        copy.invoke = { [weak self, weak copy] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.invitation, forType: .string)
            copy?.title = self.copiedTitle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak copy] in
                guard let self else { return }
                copy?.title = self.copyTitle
            }
        }
        let close = SettingsActionButton(closeTitle) { [weak self] in
            self?.dismiss(self)
        }
        close.keyEquivalent = "\r"

        let actions = NSStackView(views: [copy, close])
        actions.spacing = 10

        let stack = NSStackView(views: [title, endpointBadge, qrCard, instruction, linkBox, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(16, after: endpointBadge)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
            linkBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}
