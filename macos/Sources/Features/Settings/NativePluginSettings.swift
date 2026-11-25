import AppKit
import Combine

private final class DoctorObserverToken {
    let cancellable: AnyCancellable
    init(_ cancellable: AnyCancellable) {
        self.cancellable = cancellable
    }
}

@MainActor
private final class DoctorActionOrBadgeControl: NSView {
    let actionButton: SettingsActionButton
    let statusBadge: NSTextField
    private var activeConstraints: [NSLayoutConstraint] = []

    init(actionButton: SettingsActionButton, statusBadge: NSTextField) {
        self.actionButton = actionButton
        self.statusBadge = statusBadge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionButton)
        addSubview(statusBadge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(showActionButton: Bool) {
        NSLayoutConstraint.deactivate(activeConstraints)
        actionButton.isHidden = !showActionButton
        statusBadge.isHidden = showActionButton
        let activeView: NSView = showActionButton ? actionButton : statusBadge
        activeConstraints = [
            activeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            activeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            activeView.topAnchor.constraint(equalTo: topAnchor),
            activeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(activeConstraints)
        invalidateIntrinsicContentSize()
    }
}

extension NativeSettingsController {
    func plugins(_ form: NativeSettingsForm) {
        let manager = PluginInstallationManager.shared
        form.section(strings.officialPluginsSection)
        let official = PluginInstallationManager.officialPlugins
        let manifests = official + manager.installed.filter { installed in
            !official.contains { $0.id == installed.id }
        }
        for manifest in manifests {
            let enabled = manager.isInstalled(manifest.id) && manager.isEnabled(manifest.id)
            let name = manifest.id == SSHPlugin.pluginID ? "SSH" : manifest.id
            let caption = manifest.id == SSHPlugin.pluginID
                ? strings.sshPluginCaption
                : strings.genericPluginCaption
            let subtitle = "v\(manifest.version) · \(caption)"
            let control = SettingsSwitch(value: enabled) { [weak self] on in
                do {
                    if !manager.isInstalled(manifest.id) { try manager.installOfficial(manifest.id) }
                    if on { try manager.enable(manifest.id) } else { try manager.disable(manifest.id) }
                } catch { self?.showError(error) }
            }
            var actions: [NSView] = []
            if official.contains(where: { $0.id == manifest.id }), manager.isInstalled(manifest.id) {
                let update = SettingsActionButton(text("Update", "更新")) { [weak self] in
                    do { try manager.installOfficial(manifest.id) } catch { self?.showError(error) }
                }
                actions.append(update)
            }
            actions.append(control)
            let controlStack = NSStackView(views: actions)
            controlStack.spacing = 10
            form.row(name, subtitle: subtitle, control: controlStack)
        }
        form.note(strings.officialPluginsCaption)

        let extraInstalled = manager.installed.filter { installed in
            !official.contains { $0.id == installed.id }
        }
        for manifest in extraInstalled {
            form.row(
                manifest.id,
                control: SettingsActionButton(text("Uninstall…", "卸载…")) { [weak self] in
                    self?.confirm(self?.text("Uninstall \(manifest.id)?", "卸载 \(manifest.id)？") ?? "") { [weak self] in
                        do {
                            try manager.uninstall(manifest.id)
                            self?.select(.advanced)
                        } catch {
                            self?.showError(error)
                        }
                    }
                }
            )
        }
    }

    func buildOMGDoctorSection(_ form: NativeSettingsForm, doctor: OMGDoctorService) {
        let initialReport = doctor.report
        let currentStrings = strings
        form.section(currentStrings.doctorSection)

        let grantButton = SettingsActionButton(currentStrings.doctorGrantAccessibilityButton) {
            _ = doctor.grantAccessibilityPermission()
        }
        let accessibilityBadge = makeDoctorStatusBadge(initialReport.accessibility.status)
        let accessibilityContainer = DoctorActionOrBadgeControl(
            actionButton: grantButton,
            statusBadge: accessibilityBadge
        )
        accessibilityContainer.update(showActionButton: initialReport.accessibility.needsGrantAction)

        let accessibilityRow = form.row(
            currentStrings.doctorAccessibilityLabel,
            subtitle: initialReport.accessibility.summary(strings: currentStrings),
            control: accessibilityContainer
        )

        let trustButton = SettingsActionButton(currentStrings.doctorInstallSignerTrustButton) {}
        trustButton.invoke = { [weak trustButton] in
            trustButton?.isEnabled = false
            Task { @MainActor [weak trustButton] in
                defer { trustButton?.isEnabled = true }
                _ = await doctor.installReleaseSignerTrust()
            }
        }
        let signerTrustBadge = makeDoctorStatusBadge(initialReport.signerTrust.status)
        let signerTrustContainer = DoctorActionOrBadgeControl(
            actionButton: trustButton,
            statusBadge: signerTrustBadge
        )
        signerTrustContainer.update(showActionButton: initialReport.signerTrust.needsTrustAction)

        let signerTrustRow = form.row(
            currentStrings.doctorSignerTrustLabel,
            subtitle: formatDoctorSignerTrustSubtitle(
                report: initialReport,
                lastError: doctor.lastSignerTrustError,
                strings: currentStrings
            ),
            control: signerTrustContainer
        )

        let runtimeSSHBadge = makeDoctorStatusBadge(initialReport.runtimeSSH.status)
        let runtimeSSHRow = form.row(
            currentStrings.doctorRuntimeSSHLabel,
            subtitle: initialReport.runtimeSSH.summary(strings: currentStrings),
            control: runtimeSSHBadge
        )

        let agentBackupBadge = makeDoctorStatusBadge(initialReport.agentBackups.status)
        let agentBackupRow = form.row(
            currentStrings.doctorAgentBackupLabel,
            subtitle: initialReport.agentBackups.summary(strings: currentStrings),
            control: agentBackupBadge
        )

        let reclaimButton = SettingsActionButton(currentStrings.doctorReclaimMemoryButton) {}
        reclaimButton.invoke = { [weak reclaimButton] in
            reclaimButton?.isEnabled = false
            Task { @MainActor [weak reclaimButton] in
                defer { reclaimButton?.isEnabled = true }
                _ = await doctor.reclaimIdleResources()
            }
        }
        let resourcesRow = form.row(
            currentStrings.doctorResourcesLabel,
            subtitle: formatDoctorResourcesSubtitle(
                report: initialReport,
                lastReclaim: doctor.lastReclaimResult,
                strings: currentStrings
            ),
            control: reclaimButton
        )

        let refreshButton = SettingsActionButton(currentStrings.doctorRefreshButton) {}
        refreshButton.invoke = { [weak refreshButton] in
            refreshButton?.isEnabled = false
            Task { @MainActor [weak refreshButton] in
                defer { refreshButton?.isEnabled = true }
                await doctor.refresh()
            }
        }
        let snapshotRow = form.row(
            text("Diagnostics Snapshot", "诊断快照"),
            subtitle: formatDoctorOverallSubtitle(report: initialReport, strings: currentStrings),
            control: refreshButton
        )

        form.note(currentStrings.doctorCaption)

        struct DoctorSectionBindings {
            let accessibilityRow: NativeSettingsRow?
            let signerTrustRow: NativeSettingsRow?
            let runtimeSSHRow: NativeSettingsRow?
            let agentBackupRow: NativeSettingsRow?
            let resourcesRow: NativeSettingsRow?
            let snapshotRow: NativeSettingsRow?
            weak var accessibilityContainer: DoctorActionOrBadgeControl?
            weak var accessibilityBadge: NSTextField?
            weak var signerTrustContainer: DoctorActionOrBadgeControl?
            weak var signerTrustBadge: NSTextField?
            weak var runtimeSSHBadge: NSTextField?
            weak var agentBackupBadge: NSTextField?
        }
        let bindings = DoctorSectionBindings(
            accessibilityRow: accessibilityRow,
            signerTrustRow: signerTrustRow,
            runtimeSSHRow: runtimeSSHRow,
            agentBackupRow: agentBackupRow,
            resourcesRow: resourcesRow,
            snapshotRow: snapshotRow,
            accessibilityContainer: accessibilityContainer,
            accessibilityBadge: accessibilityBadge,
            signerTrustContainer: signerTrustContainer,
            signerTrustBadge: signerTrustBadge,
            runtimeSSHBadge: runtimeSSHBadge,
            agentBackupBadge: agentBackupBadge
        )

        let subscription = doctor.$report
            .combineLatest(doctor.$lastReclaimResult, doctor.$lastSignerTrustError)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] report, lastReclaim, lastTrustError in
                guard let self else { return }
                let localized = self.strings
                bindings.accessibilityRow?.setSubtitle(report.accessibility.summary(strings: localized))
                if let badge = bindings.accessibilityBadge {
                    self.applyDoctorStatusBadge(badge, status: report.accessibility.status, strings: localized)
                }
                bindings.accessibilityContainer?.update(showActionButton: report.accessibility.needsGrantAction)

                bindings.signerTrustRow?.setSubtitle(
                    self.formatDoctorSignerTrustSubtitle(
                        report: report,
                        lastError: lastTrustError,
                        strings: localized
                    )
                )
                if let badge = bindings.signerTrustBadge {
                    self.applyDoctorStatusBadge(badge, status: report.signerTrust.status, strings: localized)
                }
                bindings.signerTrustContainer?.update(showActionButton: report.signerTrust.needsTrustAction)

                bindings.runtimeSSHRow?.setSubtitle(report.runtimeSSH.summary(strings: localized))
                if let badge = bindings.runtimeSSHBadge {
                    self.applyDoctorStatusBadge(badge, status: report.runtimeSSH.status, strings: localized)
                }

                bindings.agentBackupRow?.setSubtitle(report.agentBackups.summary(strings: localized))
                if let badge = bindings.agentBackupBadge {
                    self.applyDoctorStatusBadge(badge, status: report.agentBackups.status, strings: localized)
                }

                bindings.resourcesRow?.setSubtitle(
                    self.formatDoctorResourcesSubtitle(
                        report: report,
                        lastReclaim: lastReclaim,
                        strings: localized
                    )
                )
                bindings.snapshotRow?.setSubtitle(self.formatDoctorOverallSubtitle(report: report, strings: localized))
            }
        form.retained.append(DoctorObserverToken(subscription))

        Task { @MainActor [weak form] in
            guard form != nil else { return }
            await doctor.refresh()
        }
    }

    private func formatDoctorSignerTrustSubtitle(
        report: OMGDoctorReport,
        lastError: OMGSignerTrustInstallError?,
        strings: SettingsStrings
    ) -> String {
        var subtitle = report.signerTrust.summary(strings: strings)
        if let lastError {
            subtitle += "\n" + lastError.localizedSummary(strings: strings)
        }
        return subtitle
    }

    private func formatDoctorResourcesSubtitle(
        report: OMGDoctorReport,
        lastReclaim: OMGDoctorReclaimResult?,
        strings: SettingsStrings
    ) -> String {
        var subtitle = report.resources.summary(strings: strings)
        if let lastReclaim {
            let note = strings.t(
                "Last reclaim freed \(lastReclaim.reclaimedWebViews) WebViews and \(lastReclaim.reclaimedLSPServers) LSP servers.",
                "上次回收释放了 \(lastReclaim.reclaimedWebViews) 个 WebView 与 \(lastReclaim.reclaimedLSPServers) 个语言服务。"
            )
            subtitle += "\n" + note
        }
        return subtitle
    }

    private func formatDoctorOverallSubtitle(
        report: OMGDoctorReport,
        strings: SettingsStrings
    ) -> String {
        report.overallStatus == .healthy
            ? strings.t("All core host checks are healthy.", "所有核心宿主检查项均正常。")
            : strings.t("One or more checks require attention.", "存在需要关注的诊断项。")
    }

    private func makeDoctorStatusBadge(_ status: OMGDoctorHealthStatus) -> NSTextField {
        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.alignment = .right
        applyDoctorStatusBadge(badge, status: status, strings: strings)
        return badge
    }

    private func applyDoctorStatusBadge(
        _ badge: NSTextField,
        status: OMGDoctorHealthStatus,
        strings: SettingsStrings
    ) {
        badge.stringValue = status == .healthy ? strings.doctorStatusHealthy : strings.doctorStatusAttention
        badge.textColor = status == .healthy ? .systemGreen : .systemOrange
    }
}
