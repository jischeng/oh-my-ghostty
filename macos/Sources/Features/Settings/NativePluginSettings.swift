import AppKit

extension NativeSettingsController {
    func plugins(_ form: NativeSettingsForm) {
        let doctor = OMGDoctorService.shared
        buildOMGDoctorSection(form, doctor: doctor)

        let manager = PluginInstallationManager.shared
        form.section(strings.officialPluginsSection)
        let official = PluginInstallationManager.officialPlugins
        let manifests = official + manager.installed.filter { installed in
            !official.contains { $0.id == installed.id }
        }
        for manifest in manifests {
            let enabled = manager.isEnabled(manifest.id)
            let name = manifest.id == SSHPlugin.pluginID ? "SSH" : manifest.id
            let control = SettingsSwitch(value: enabled) { [weak self] on in
                do {
                    if !manager.isInstalled(manifest.id) { try manager.installOfficial(manifest.id) }
                    if on { try manager.enable(manifest.id) } else { try manager.disable(manifest.id) }
                } catch { self?.showError(error) }
            }
            let details = SettingsActionButton(text("Details…", "详情…")) { [weak self] in
                guard let self else { return }
                self.push(name, previous: { [weak self] in self?.select(.plugins) }, build: { page in
                    page.section(name)
                    page.row(self.text("Version", "版本"), control: NSTextField(labelWithString: manifest.version))
                    if official.contains(where: { $0.id == manifest.id }) {
                        page.row(
                            self.text("Update package", "更新插件包"),
                            control: SettingsActionButton(self.text("Update", "更新")) { [weak self] in
                                do { try manager.installOfficial(manifest.id) } catch { self?.showError(error) }
                            }
                        )
                    }
                    page.note(
                        manifest.id == SSHPlugin.pluginID
                            ? self.strings.sshPluginCaption
                            : self.strings.genericPluginCaption
                    )
                    page.note(manifest.capabilities.map { String(describing: $0) }.joined(separator: " · "))
                })
            }
            form.row(name, control: NSStackView(views: [control, details]))
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
                            self?.select(.plugins)
                        } catch {
                            self?.showError(error)
                        }
                    }
                }
            )
        }
    }

    private func buildOMGDoctorSection(_ form: NativeSettingsForm, doctor: OMGDoctorService) {
        let report = doctor.report
        form.section(strings.doctorSection)

        let accessibilityControl: NSView
        if report.accessibility.needsGrantAction {
            accessibilityControl = SettingsActionButton(strings.doctorGrantAccessibilityButton) { [weak self] in
                _ = doctor.grantAccessibilityPermission()
                if self?.isShowing(OhMyGhosttySettingsTab.plugins.rawValue) == true {
                    self?.select(.plugins)
                }
            }
        } else {
            accessibilityControl = makeDoctorStatusBadge(report.accessibility.status)
        }
        form.row(
            strings.doctorAccessibilityLabel,
            subtitle: report.accessibility.summary(strings: strings),
            control: accessibilityControl
        )

        form.row(
            strings.doctorRuntimeSSHLabel,
            subtitle: report.runtimeSSH.summary(strings: strings),
            control: makeDoctorStatusBadge(report.runtimeSSH.status)
        )

        form.row(
            strings.doctorAgentBackupLabel,
            subtitle: report.agentBackups.summary(strings: strings),
            control: makeDoctorStatusBadge(report.agentBackups.status)
        )

        let reclaimButton = SettingsActionButton(strings.doctorReclaimMemoryButton) {}
        reclaimButton.invoke = { [weak self, weak reclaimButton] in
            reclaimButton?.isEnabled = false
            Task { @MainActor [weak self, weak reclaimButton] in
                defer { reclaimButton?.isEnabled = true }
                _ = await doctor.reclaimIdleResources()
                if self?.isShowing(OhMyGhosttySettingsTab.plugins.rawValue) == true {
                    self?.select(.plugins)
                }
            }
        }
        var resourceSubtitle = report.resources.summary(strings: strings)
        if let lastReclaim = doctor.lastReclaimResult {
            let note = strings.t(
                "Last reclaim freed \(lastReclaim.reclaimedWebViews) WebViews and \(lastReclaim.reclaimedLSPServers) LSP servers.",
                "上次回收释放了 \(lastReclaim.reclaimedWebViews) 个 WebView 与 \(lastReclaim.reclaimedLSPServers) 个语言服务。"
            )
            resourceSubtitle += "\n" + note
        }
        form.row(
            strings.doctorResourcesLabel,
            subtitle: resourceSubtitle,
            control: reclaimButton
        )

        let refreshButton = SettingsActionButton(strings.doctorRefreshButton) {}
        refreshButton.invoke = { [weak self, weak refreshButton] in
            refreshButton?.isEnabled = false
            Task { @MainActor [weak self, weak refreshButton] in
                defer { refreshButton?.isEnabled = true }
                await doctor.refresh()
                if self?.isShowing(OhMyGhosttySettingsTab.plugins.rawValue) == true {
                    self?.select(.plugins)
                }
            }
        }
        form.row(
            text("Diagnostics Snapshot", "诊断快照"),
            subtitle: report.overallStatus == .healthy
                ? text("All core host checks are healthy.", "所有核心宿主检查项均正常。")
                : text("One or more checks require attention.", "存在需要关注的诊断项。"),
            control: refreshButton
        )

        form.note(strings.doctorCaption)

        Task { @MainActor [weak self] in
            let previous = doctor.report
            await doctor.refresh()
            if doctor.report != previous,
               self?.isShowing(OhMyGhosttySettingsTab.plugins.rawValue) == true {
                self?.select(.plugins)
            }
        }
    }

    private func makeDoctorStatusBadge(_ status: OMGDoctorHealthStatus) -> NSTextField {
        let title = status == .healthy ? strings.doctorStatusHealthy : strings.doctorStatusAttention
        let badge = NSTextField(labelWithString: title)
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.alignment = .right
        badge.textColor = status == .healthy ? .secondaryLabelColor : .systemOrange
        return badge
    }
}
