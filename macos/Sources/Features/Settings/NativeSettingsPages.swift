import AppKit
import Combine

extension NativeSettingsController {
    func build(_ tab: OhMyGhosttySettingsTab, into form: NativeSettingsForm) {
        switch tab {
        case .general: general(form)
        case .appearance: appearance(form)
        case .tabs: tabsPage(form)
        case .terminal: terminal(form)
        case .controls: controls(form)
        case .editor: editor(form)
        case .keyboard: keyboard(form)
        case .git:
            form.section(strings.gitSection)
            picker(
                form,
                strings.gitAutoFetchLabel,
                \.gitAutoFetchInterval,
                Array(Set([0, 1, 2, 5, 10, 15, 30, 60, settings.gitAutoFetchInterval])).sorted()
                    .map { ($0, strings.gitAutoFetchIntervalTitle($0)) }
            )
            aiCommitSection(form)
        case .ssh: remoteHosts(form)
        case .mobile: mobileAccess(form)
        case .agents: aiOverview(form)
        case .advanced:
            form.section(strings.settingsLocationsSection)
            let files = NSStackView(views: [
                SettingsActionButton(strings.revealButton) { [weak settings] in
                    settings?.ensureFileExists()
                    NSWorkspace.shared.activateFileViewerSelecting([OhMyGhosttySettings.fileURL])
                },
                SettingsActionButton(strings.openFileButton) { [weak settings] in
                    settings?.ensureFileExists(); NSWorkspace.shared.open(OhMyGhosttySettings.fileURL)
                }
            ])
            form.row(strings.settingsFileLabel,
                     subtitle: (OhMyGhosttySettings.fileURL.path as NSString).abbreviatingWithTildeInPath, control: files)
            form.row(text("Ghostty Config", "Ghostty 配置文件"),
                     subtitle: text("Terminal defaults that OMG settings build on.", "终端默认配置，OMG 设置在其之上生效。"),
                     control: SettingsActionButton(strings.openFileButton) {
                (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
            })
            form.row(text("Reload OMG Settings", "重新加载 OMG 设置"),
                     subtitle: text("Apply edits made to the settings file by hand.", "应用对设置文件的手动修改。"),
                     control: SettingsActionButton(strings.reloadButton) { [weak self] in
                self?.settings.reloadFromDisk(); self?.select(.advanced)
            })
            form.note(strings.precedenceLabel + " · " + strings.precedenceValue)
            if let error = settings.lastError { form.note(error) }
            plugins(form)
            buildOMGDoctorSection(form, doctor: doctor)
        }
    }

    private func general(_ form: NativeSettingsForm) {
        form.section(CoreSetting.Group.lifecycle.title(strings))
        picker(
            form,
            strings.languageLabel,
            \.language,
            [(.system, strings.languageSystem), (.english, "English"), (.simplifiedChinese, "简体中文")]
        )
        toggle(form, strings.quitWithoutConfirmationLabel, \.quitWithoutConfirmation, help: strings.quitWithoutConfirmationCaption)
        for field in CoreSetting.all where field.group == .lifecycle {
            core(field.key, in: form)
        }

        form.section(strings.notificationsSection)
        core("desktop-notifications", in: form)
        toggle(form, strings.notifyTaskCompleteLabel, \.notifyTaskComplete)
        toggle(form, strings.notifyAttentionLabel, \.notifyAttention)
        toggle(form, strings.notificationSoundLabel, \.notificationSound)
        let tones = AgentNotificationSoundTone.allCases
        let tonePopup = SettingsPopup(
            titles: tones.map { strings.notificationSoundToneTitle($0) },
            selected: tones.firstIndex(of: settings.notificationSoundTone) ?? 0
        ) { [weak settings] index in
            guard tones.indices.contains(index) else { return }
            let tone = tones[index]
            settings?.notificationSoundTone = tone
            AgentActivityNotification.previewSound(tone)
        }
        tonePopup.isEnabled = settings.notificationSound
        form.row(strings.notificationSoundToneLabel, control: tonePopup)
        let syncToneControl = { [weak settings, weak tonePopup] in
            guard let settings, let tonePopup else { return }
            tonePopup.isEnabled = settings.notificationSound
            tonePopup.selectItem(at: tones.firstIndex(of: settings.notificationSoundTone) ?? 0)
        }
        form.refreshers.append(syncToneControl)
        form.retained.append(
            settings.$notificationSound.combineLatest(settings.$notificationSoundTone)
                .receive(on: RunLoop.main)
                .sink { _ in syncToneControl() }
        )
    }

    private func tabsPage(_ form: NativeSettingsForm) {
        form.section(strings.layoutSection)
        picker(
            form,
            strings.tabLayoutLabel,
            \.tabLayout,
            [(.vertical, strings.verticalOption), (.horizontal, strings.horizontalOption)]
        )
        picker(
            form,
            strings.sidebarViewModeLabel,
            \.tabSidebarViewMode,
            GhosttyTabSidebarViewMode.allCases.map { ($0, strings.sidebarViewModeTitle($0)) }
        )
        toggle(form, strings.showSidebarLabel, \.sidebarVisible)
        number(form, strings.sidebarWidthLabel, \.defaultSidebarWidth, range: 176...480)
        toggle(form, strings.rememberSidebarWidthLabel, \.rememberSidebarWidth)

        form.section(strings.organizationSection)
        picker(form, strings.groupingLabel, \.groupingMode, GhosttyTabGroupingMode.allCases.map { ($0, strings.groupingTitle($0)) })
        picker(form, strings.orderingLabel, \.orderingMode, GhosttyTabOrderingMode.allCases.map { ($0, strings.orderingTitle($0)) })
        picker(form, strings.pathDisplayLabel, \.tabPathDisplay, OhMyGhosttyTabPathDisplay.allCases.map { ($0, strings.pathDisplayTitle($0)) })

        form.section(strings.inboxViewSection)
        picker(form, strings.inboxGroupingLabel, \.tabInboxGroupingMode,
               GhosttyTabGroupingMode.allCases.map { ($0, strings.groupingTitle($0)) })
        picker(form, strings.inboxOrderingLabel, \.tabInboxOrderingMode,
               GhosttyTabOrderingMode.allCases.map { ($0, strings.orderingTitle($0)) })
        picker(form, strings.inboxContinueMinutesLabel, \.tabInboxContinueMinutes,
               OhMyGhosttySettings.inboxContinueMinuteOptions.map { ($0, strings.inboxContinueMinutesTitle($0)) })

        aiTitleSection(form)

        form.section(strings.tabsDisplaySection)
        picker(form, strings.rowDensityLabel, \.tabRowDensity, OhMyGhosttyTabRowDensity.allCases.map { ($0, strings.densityTitle($0)) })
        number(form, strings.tabIconSizeLabel, \.tabIconSize, range: 12...20)
        toggle(form, strings.showShortcutLabelsLabel, \.showShortcutLabels)
        form.row(strings.resetTabsButton, control: SettingsActionButton(text("Reset", "重置")) { [weak self] in
            self?.settings.resetTabs(); self?.select(.tabs)
        })
    }

    private func terminal(_ form: NativeSettingsForm) {
        form.section(strings.sessionRecoverySection)
        picker(form, strings.startupModeLabel, \.startupMode, OMGStartupMode.allCases.map { ($0, strings.startupModeTitle($0)) })

        form.section(strings.newSessionInheritanceSection, caption: strings.newSessionInheritanceCaption)
        picker(form, strings.newTabInheritanceLabel, \.newTabInheritance,
               NewSessionInheritance.allCases.map { ($0, strings.newSessionInheritanceTitle($0)) })
        picker(form, strings.newSplitInheritanceLabel, \.newSplitInheritance,
               NewSessionInheritance.allCases.map { ($0, strings.newSessionInheritanceTitle($0)) })
        form.note(strings.newSessionInheritanceResumeWarning)

        form.section(strings.runtimeTitle, caption: strings.runtimeKeepOnQuitCaption)
        form.row(text("Local and SSH sessions", "本地与 SSH 会话"),
                 control: SettingsActionButton(text("View all sessions…", "查看所有会话…")) { SessionRuntimeOverview.show() },
                 help: "omg +sessions list · omg +sessions close --all --yes")
        form.row(strings.runtimeLocalOpen, control: SettingsActionButton(text("Open…", "打开…")) { [weak self] in
            guard let self, let window = self.view.window else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let self, let url = panel.url else { return }
                do { try SessionRuntimeConnections.shared.openLocal(workingDirectory: url.path, policy: self.validatedRuntimePolicy()) } catch { self.showError(error) }
            }
        })
        let closes = SessionRuntimeCloseQueue.shared
        let count = NSTextField(labelWithString: String(closes.requests.count))
        let pending = form.row(text("Pending closes", "待确认的关闭请求"),
            control: NSStackView(views: [count, SettingsActionButton(text("Retry", "重试")) { closes.retry() }]))
        pending?.setVisible(!closes.requests.isEmpty)
        let pendingToken = closes.$requests.receive(on: RunLoop.main).sink { [weak count] requests in
            count?.stringValue = String(requests.count)
            pending?.setVisible(!requests.isEmpty)
        }
        form.retained.append(pendingToken)

        toggle(form, text("Use background sessions for new terminals", "新终端使用后台会话"), \.localRuntimeEnabled,
               help: strings.runtimeLocalRuntimeCaption)
        toggle(form, text("Persist Quick Terminal in background session", "快捷终端启用持久化后台会话"), \.quickTerminalRuntimeEnabled,
               help: strings.runtimeQuickTerminalCaption)
        toggle(form, strings.runtimeKeepLocalOnQuit, \.keepLocalSessionsOnQuit)
        toggle(form, strings.runtimeKeepSSHOnQuit, \.keepSSHSessionsOnQuit)
        number(form, text("Disconnected lifetime (hours)", "断开后保留时长（小时）"), \.runtimeDetachedHours, range: 0...8760,
               help: text("0 means no time limit.", "0 表示不限时长。"))
        let formatter = ISO8601DateFormatter()
        let date = SettingsDatePicker(value: formatter.date(from: settings.runtimeExpiration) ?? Date().addingTimeInterval(86_400)) { [weak settings] in
            settings?.runtimeExpiration = formatter.string(from: $0)
        }
        date.isEnabled = !settings.runtimeExpiration.isEmpty
        let enabled = SettingsSwitch(value: date.isEnabled) { [weak settings, weak date] value in
            date?.isEnabled = value
            settings?.runtimeExpiration = value ? formatter.string(from: date?.dateValue ?? Date()) : ""
        }
        form.row(text("Expiration date", "截止时间"), control: NSStackView(views: [enabled, date]))
        toggle(form, text("Clean up completed Agent sessions", "回收已完成的 Agent 会话"), \.runtimeCloseOnAgentDone,
               help: strings.runtimeCloseOnDoneCaption)
        number(form, strings.runtimeDoneGrace, \.runtimeDoneGraceSeconds, range: 1...86400)

        core(.shell, in: form)
    }

    private func appearance(_ form: NativeSettingsForm) {
        form.section(strings.terminalThemeSection)
        picker(form, strings.appearancePickerLabel, \.windowThemeOverride, [
            (nil, text("Follow terminal", "跟随终端")), (.system, text("System", "系统")), (.light, text("Light", "浅色")), (.dark, text("Dark", "深色"))
        ])
        let gallery = NativeThemeGallery(settings: settings)
        form.addChild(gallery)
        form.embed(gallery.view, height: NativeThemeGallery.height)
        form.section(strings.fontSection)
        picker(form, strings.fontFamilyLabel, \.fontFamilyOverride,
               [(nil, text("Default", "默认"))] + Array(Set(NSFontManager.shared.availableFontFamilies +
                [settings.fontFamilyOverride].compactMap { $0 })).sorted().map { (Optional($0), $0) })
        optionalNumber(form, strings.fontSizeLabel, \.fontSizeOverride, fallback: { [weak self] in
            guard let self else { return 13 }
            let value = self.settings.effectiveAppearance(using: self.inheritedConfig).fontSize
            return value.inheritedValue ?? value.defaultValue
        }, range: 6...72, step: 0.5)
        core("window-inherit-font-size", in: form)
        form.section(strings.cursorSection)
        picker(form, strings.cursorStyleLabel, \.cursorStyleOverride,
               [(nil, text("Default", "默认"))] + OhMyGhosttyCursorStyle.allCases.map { (Optional($0), strings.cursorTitle($0)) })
        core("cursor-style-blink", in: form)
        form.section(strings.transparencySection)
        picker(form, strings.backgroundBlurLabel, \.backgroundBlurOverride,
               [(nil, text("Default", "默认"))] + OhMyGhosttyBackgroundBlur.allCases.map { (Optional($0), strings.blurTitle($0)) })
        form.section(strings.focusedSplitBorderSection)
        toggle(form, strings.focusedSplitBorderLabel, \.focusedSplitBorder)
        picker(form, text("Marker position", "标记线位置"), \.focusedSplitBorderPosition, [
            (.top, text("Top", "顶部")), (.bottom, text("Bottom", "底部")),
            (.left, text("Left", "左侧")), (.right, text("Right", "右侧"))
        ])
        number(form, text("Marker thickness (pt)", "标记线粗细（pt）"), \.focusedSplitBorderWidth, range: 1...6, step: 0.5)
        optionalNumber(form, text("Focused pane background opacity", "聚焦 Pane 背景不透明度"), \.backgroundOpacityOverride, fallback: { [weak self] in
            guard let self else { return 1 }
            return self.settings.effectiveAppearance(using: self.inheritedConfig).backgroundOpacity.inheritedValue ?? 1
        }, range: 0.05...1, step: 0.05)
        let unfocusedOpacity = SettingsSlider(value: settings.unfocusedSplitOpacity, minimum: 0.15) { [weak settings] in
            settings?.unfocusedSplitOpacity = $0
        }
        let resetOpacity = SettingsActionButton(text("Default", "默认")) { [weak settings] in
            settings?.unfocusedSplitOpacity = 0.9
        }
        form.row(text("Unfocused pane opacity", "非聚焦 Pane 不透明度"), control: NSStackView(views: [unfocusedOpacity, resetOpacity]))
        form.refreshers.append { [weak settings, weak unfocusedOpacity] in
            if let settings { unfocusedOpacity?.setValue(settings.unfocusedSplitOpacity) }
        }
        form.note(text(
            "Background opacity also affects sidebars. Unfocused opacity controls native split dimming; 100% disables dimming.",
            "背景不透明度也影响侧栏等界面。非聚焦不透明度控制原生分屏淡化，100% 表示不淡化。"
        ))
        form.section(strings.resizeRenderingSection)
        let resizeModes = TerminalResizeRenderingMode.allCases
        let resizePopup = SettingsPopup(
            titles: resizeModes.map { strings.terminalResizeRenderingTitle($0) },
            selected: resizeModes.firstIndex(of: settings.terminalResizeRendering) ?? 0
        ) { [weak settings] index in
            guard resizeModes.indices.contains(index) else { return }
            settings?.terminalResizeRendering = resizeModes[index]
        }
        form.row(
            strings.terminalResizeRenderingLabel,
            control: resizePopup,
            help: strings.terminalResizeRenderingCaption
        )
        form.refreshers.append { [weak settings, weak resizePopup] in
            guard let settings else { return }
            resizePopup?.selectItem(at: resizeModes.firstIndex(of: settings.terminalResizeRendering) ?? 0)
        }
        form.section(text("Reset", "重置"))
        form.row(strings.resetAppearanceButton,
                 subtitle: text("Uses terminal defaults until you choose a value.", "未自定义的选项沿用终端配置。"),
                 control: SettingsActionButton(text("Reset", "重置")) { [weak self] in
            self?.settings.resetAppearance(); self?.select(.appearance)
        })
    }

    private var inheritedConfig: Ghostty.Config {
        (NSApp.delegate as? AppDelegate)?.ghostty.inheritedConfig ?? Ghostty.Config(at: nil)
    }

    private func optionalNumber(_ form: NativeSettingsForm, _ title: String,
                                _ key: ReferenceWritableKeyPath<OhMyGhosttySettings, Double?>,
                                fallback: @escaping () -> Double, range: ClosedRange<Double>, step: Double) {
        if range.upperBound == 1 {
            let control = SettingsSlider(value: settings[keyPath: key] ?? fallback()) { [weak settings] in settings?[keyPath: key] = $0 }
            let reset = SettingsActionButton(text("Default", "默认")) { [weak settings, weak control] in
                settings?[keyPath: key] = nil; control?.setValue(fallback())
            }
            form.row(title, control: NSStackView(views: [control, reset]))
            form.refreshers.append { [weak settings, weak control] in
                control?.setValue(settings?[keyPath: key] ?? fallback())
            }
            return
        }
        let control = SettingsNumberField(value: settings[keyPath: key] ?? fallback(), range: range, step: step) { [weak settings] in settings?[keyPath: key] = $0
        }
        let reset = SettingsActionButton(text("Default", "默认")) { [weak settings, weak control] in
            settings?[keyPath: key] = nil
            control?.field.doubleValue = fallback()
            control?.stepper.doubleValue = fallback()
        }
        let stack = NSStackView(views: [control, reset])
        stack.spacing = 8
        form.row(title, control: stack)
        form.refreshers.append { [weak settings, weak control] in
            guard let control, control.field.currentEditor() == nil else { return }
            control.field.doubleValue = settings?[keyPath: key] ?? fallback()
            control.stepper.doubleValue = control.field.doubleValue
        }
    }

    private func editor(_ form: NativeSettingsForm) {
        form.section(strings.editorOpeningSection)
        picker(form, strings.editorFileOpenDestinationLabel, \.editorFileOpenDestination, EditorOpenDestination.allCases.map { ($0, strings.editorOpenDestinationTitle($0)) })
        picker(form, strings.editorDirectoryOpenDestinationLabel, \.editorDirectoryOpenDestination, EditorOpenDestination.allCases.map { ($0, strings.editorOpenDestinationTitle($0)) })
        form.section(strings.editorBehaviorSection)
        picker(form, strings.editorKeymapPresetLabel, \.editorKeymapPreset, EditorKeymapPreset.allCases.map { ($0, strings.editorKeymapPresetTitle($0)) })
        toggle(form, strings.editorWordWrapLabel, \.editorWordWrap)
        toggle(form, strings.editorAutoClosePairsLabel, \.editorAutoClosePairs)
        form.section(strings.editorTypographySection)
        picker(form, strings.editorFontFamilyLabel, \.editorFontFamily, EditorFontFamily.allCases.map { ($0, strings.editorFontFamilyTitle($0)) })
        number(form, strings.editorFontSizeLabel, \.editorFontSize, range: 8...36, step: 0.5)
        number(form, strings.editorTabWidthLabel, \.editorTabWidth, range: 1...12)

        form.section(strings.editorThemeSection)
        picker(
            form,
            strings.editorBackgroundModeLabel,
            \.editorBackgroundMode,
            EditorBackgroundMode.allCases.map { ($0, strings.editorBackgroundModeTitle($0)) }
        )
        let catalogs = Array(Set(GhosttyThemeCatalog.availableThemes() + [settings.editorThemeName].compactMap { $0 })).sorted()
        let options = [("follow", strings.editorSyntaxThemeTitle(.followTerminal))] +
            catalogs.map { ("catalog:" + $0, $0) } +
            EditorSyntaxTheme.allCases.filter { $0 != .followTerminal }.map { ("builtin:" + $0.rawValue, strings.editorSyntaxThemeTitle($0)) }
        let selected = settings.editorThemeName.map { "catalog:" + $0 } ??
            (settings.editorSettings.followsOMG ? "follow" : "builtin:" + settings.editorSyntaxTheme.rawValue)
        let syntaxPopup = SettingsPopup(
            titles: options.map(\.1),
            selected: options.firstIndex { $0.0 == selected } ?? 0
        ) { [weak settings] index in
            guard options.indices.contains(index) else { return }
            let value = options[index].0
            if value.hasPrefix("catalog:") {
                settings?.editorThemeName = String(value.dropFirst(8))
            } else {
                settings?.editorThemeName = nil
                settings?.editorSyntaxTheme = value == "follow" ? .followTerminal :
                    EditorSyntaxTheme(rawValue: String(value.dropFirst(8))) ?? .followTerminal
            }
        }
        form.row(strings.editorSyntaxThemeLabel, control: syntaxPopup)

        let opacity = SettingsNumberField(value: settings.editorOpacity, range: 0.05...1, step: 0.05) { [weak settings] in
            settings?.editorOpacity = $0
        }
        opacity.field.isEnabled = !settings.editorSettings.followsOMG
        opacity.stepper.isEnabled = !settings.editorSettings.followsOMG
        form.row(strings.backgroundOpacityLabel, control: opacity)

        let blur = SettingsPopup(
            titles: OhMyGhosttyBackgroundBlur.allCases.map { strings.blurTitle($0) },
            selected: OhMyGhosttyBackgroundBlur.allCases.firstIndex(of: settings.editorBlur) ?? 0
        ) { [weak settings] in
            settings?.editorBlur = OhMyGhosttyBackgroundBlur.allCases[$0]
        }
        blur.isEnabled = !settings.editorSettings.followsOMG
        form.row(strings.backgroundBlurLabel, control: blur)

        let refreshThemeControls = { [weak self, weak syntaxPopup, weak opacity, weak blur] in
            guard let self else { return }
            let currentSelected = self.settings.editorThemeName.map { "catalog:" + $0 } ??
                (self.settings.editorSettings.followsOMG ? "follow" : "builtin:" + self.settings.editorSyntaxTheme.rawValue)
            syntaxPopup?.selectItem(at: options.firstIndex { $0.0 == currentSelected } ?? 0)
            let editable = !self.settings.editorSettings.followsOMG
            opacity?.field.isEnabled = editable
            opacity?.stepper.isEnabled = editable
            blur?.isEnabled = editable
            if opacity?.field.currentEditor() == nil {
                let value = editable ? self.settings.editorOpacity :
                    self.settings.effectiveAppearance(using: self.inheritedConfig).backgroundOpacity.effectiveValue
                opacity?.field.doubleValue = value
                opacity?.stepper.doubleValue = value
            }
            let blurValue = editable ? self.settings.editorBlur : self.settings.backgroundBlurOverride ?? self.inheritedConfig.editorBackgroundBlur
            blur?.selectItem(at: OhMyGhosttyBackgroundBlur.allCases.firstIndex(of: blurValue) ?? 0)
        }
        refreshThemeControls()
        form.refreshers.append(refreshThemeControls)

        form.section(text("Reset", "重置"))
        form.row(strings.resetEditorButton, control: SettingsActionButton(text("Reset", "重置")) { [weak self] in
            guard let self else { return }
            self.settings.editorFileOpenDestination = .currentPane
            self.settings.editorDirectoryOpenDestination = .currentPane
            self.settings.editorKeymapPreset = .idea
            self.settings.editorBackgroundMode = .followTerminal
            self.settings.editorSyntaxTheme = .followTerminal
            self.settings.editorThemeName = nil
            self.settings.editorAutoClosePairs = true
            self.settings.editorOpacity = 1
            self.settings.editorBlur = .disabled
            self.settings.editorFontFamily = .jetbrainsMono
            self.settings.editorFontSize = 13
            self.settings.editorTabWidth = 4
            self.settings.editorWordWrap = false
            self.select(.editor)
        })
    }

    private func controls(_ form: NativeSettingsForm) {
        form.section(strings.quickInputSection)
        number(form, strings.quickInputHeightLabel, \.quickInputHeight,
               range: Double(AgentQuickInputMetrics.minimumHeight)...Double(AgentQuickInputMetrics.maximumHeight))
        let quickInputOpacity = SettingsSlider(
            value: settings.quickInputOpacity,
            minimum: AgentQuickInputMetrics.minimumOpacity
        ) { [weak settings] in
            settings?.quickInputOpacity = $0
        }
        let resetQuickInputOpacity = SettingsActionButton(text("Default", "默认")) { [weak settings, weak quickInputOpacity] in
            settings?.quickInputOpacity = AgentQuickInputMetrics.defaultOpacity
            quickInputOpacity?.setValue(AgentQuickInputMetrics.defaultOpacity)
        }
        form.row(
            strings.quickInputOpacityLabel,
            control: NSStackView(views: [quickInputOpacity, resetQuickInputOpacity]),
            help: strings.quickInputOpacityCaption
        )
        form.refreshers.append { [weak settings, weak quickInputOpacity] in
            if let settings { quickInputOpacity?.setValue(settings.quickInputOpacity) }
        }
        toggle(form, strings.openQuickInputOnAgentStartLabel, \.openQuickInputOnAgentStart,
               help: strings.openQuickInputOnAgentStartCaption)
        toggle(form, strings.openQuickInputOnAgentCompleteLabel, \.openQuickInputOnAgentComplete,
               help: strings.openQuickInputOnAgentCompleteCaption)
        toggle(form, strings.quickInputControlJNewlineLabel, \.quickInputControlJNewline)
        form.toggle(strings.quickInputImportLabel, value: !settings.quickInputImportShortcut.isEmpty) { [weak settings] in
            settings?.quickInputImportShortcut = $0 ? "auto" : ""
        }
        if !settings.quickInputImportShortcut.isEmpty, settings.quickInputImportShortcut != "auto",
           QuickInputDraftBridge.keys(settings.quickInputImportShortcut) == nil {
            form.note(strings.quickInputImportInvalid)
        }

        form.section(strings.quickInputHistoryTitle)
        picker(form, strings.quickInputHistoryScopeLabel, \.quickInputHistoryScope, QuickInputHistoryScope.allCases.map { ($0, strings.quickInputHistoryScopeName($0)) })
        let shareByDirectory = SettingsSwitch(value: settings.quickInputHistoryShareByDirectory) { [weak settings] in
            settings?.quickInputHistoryShareByDirectory = $0
        }
        shareByDirectory.isEnabled = settings.quickInputHistoryScope != .global
        form.row(
            strings.quickInputHistoryShareByDirectoryLabel,
            control: shareByDirectory,
            help: strings.quickInputHistoryShareByDirectoryCaption
        )
        form.refreshers.append { [weak settings, weak shareByDirectory] in
            guard let settings else { return }
            shareByDirectory?.state = settings.quickInputHistoryShareByDirectory ? .on : .off
            shareByDirectory?.isEnabled = settings.quickInputHistoryScope != .global
        }
        picker(form, strings.quickInputHistoryInsertionLabel, \.quickInputHistoryInsertionMode, QuickInputHistoryInsertionMode.allCases.map { ($0, strings.quickInputHistoryInsertionName($0)) })
        number(form, strings.quickInputHistoryRetentionLabel, \.quickInputHistoryRetentionDays, range: 1...365)
        toggle(form, strings.quickInputHistoryKeepLabel, \.quickInputHistoryKeepAfterQuit, help: strings.quickInputHistoryPrivacyCaption)
        form.row(strings.quickInputHistoryClearButton, control: SettingsActionButton(text("Clear…", "清除…")) { [weak self] in
            guard let self else { return }
            self.confirm(self.strings.quickInputHistoryClearTitle, message: self.strings.quickInputHistoryClearMessage,
                         actionTitle: self.strings.quickInputHistoryClearConfirm) { QuickInputHistoryStore.shared.clear() }
        })
        if QuickInputHistoryStore.shared.storageError != nil { form.note(strings.quickInputHistoryStorageError) }

        core(.selection, in: form)
        core(.clipboard, in: form)
        core(.mouse, in: form)
        core(.keyboard, in: form)
    }

    private func keyboard(_ form: NativeSettingsForm) {
        form.section(text("Windows & Panels", "窗口与面板"),
                     caption: text("Click a shortcut, then press the new key combination. Press Esc to cancel.",
                                   "点击快捷键后按下新的组合键即可修改，按 Esc 取消。"))
        shortcut(form, strings.quickInputShortcutLabel, value: settings.quickInputShortcut,
                 fallback: OMGKeyboardShortcut.defaultQuickInput.storageValue) { [weak settings] in settings?.quickInputShortcut = $0 }
        shortcut(form, text("Show or Hide Left Sidebar", "显示或隐藏左侧边栏"), value: settings.toggleSidebarShortcut,
                 fallback: OMGKeyboardShortcut.defaultToggleSidebar.storageValue,
                 menuAction: #selector(AppDelegate.toggleSidebar(_:))) { [weak settings] in settings?.toggleSidebarShortcut = $0 }
        shortcut(form, strings.toggleInboxShortcutLabel, value: settings.toggleInboxShortcut,
                 fallback: OMGKeyboardShortcut.defaultToggleInbox.storageValue,
                 menuAction: #selector(AppDelegate.toggleInbox(_:))) { [weak settings] in settings?.toggleInboxShortcut = $0 }
        shortcut(form, text("Show or Hide Right Sidebar", "显示或隐藏右侧边栏"), value: settings.toggleInspectorShortcut,
                 fallback: OMGKeyboardShortcut.defaultToggleInspector.storageValue,
                 menuAction: #selector(AppDelegate.toggleInspector(_:))) { [weak settings] in settings?.toggleInspectorShortcut = $0 }
        shortcut(form, text("Workspace switcher", "工作区切换器"), value: TerminalWorkspaceStore.shared.shortcut(slot: 0),
                 fallback: TerminalWorkspaceStore.defaultShortcut(slot: 0), workspaceSlot: 0) {
            TerminalWorkspaceStore.shared.setShortcut(slot: 0, value: $0)
        }
        numberShortcuts(form)
        form.section(text("Terminal", "终端"))
        form.row(strings.keybindingsSection,
                 subtitle: text("Terminal keybindings are defined in the Ghostty config file.", "终端快捷键在 Ghostty 配置文件中定义。"),
                 control: SettingsActionButton(strings.openFileButton) { (NSApp.delegate as? AppDelegate)?.ghostty.openConfig() })
    }

    /// One modifier choice per "modifier + digit" family instead of a row per digit.
    private func numberShortcuts(_ form: NativeSettingsForm) {
        typealias Modifiers = OMGNumberShortcutModifiers
        form.section(strings.numberShortcutsSection,
                     caption: text("Hold the modifier and press a number to jump straight to that position. Combinations used by another row are unavailable.",
                                   "按住修饰键再按数字，直接切换到对应位置。已被其他行占用的组合不可选。"))
        let settings = settings
        let store = TerminalWorkspaceStore.shared
        let digits = text("number", "数字")
        func title(_ value: Modifiers) -> String { value.symbols + " + " + digits }
        struct Family {
            let options: [Modifiers?]
            let current: () -> Modifiers?
            let popup: SettingsPopup
        }
        var families: [Family] = []
        let refresh = { (families: [Family]) in
            for (index, family) in families.enumerated() {
                let taken = families.enumerated().filter { $0.offset != index }.compactMap { $0.element.current() }
                family.popup.disabledIndices = Set(family.options.indices.filter { index in
                    family.options[index].map(taken.contains) ?? false
                })
            }
        }
        func family(_ label: String, range: String, options: [Modifiers], defaultTitle: String? = nil,
                    mixed: Bool = false, current: @escaping () -> Modifiers?, apply: @escaping (Modifiers?) -> Void) {
            // A leading nil entry is the inherited Ghostty default.
            let leading: [Modifiers?] = defaultTitle != nil ? [nil] : []
            let all = leading + options.map(Optional.init)
            let titles = all.map { $0.map(title) ?? defaultTitle ?? "" }
            let selected = defaultTitle != nil && settings.tabNumberModifiers == nil ? 0 : all.firstIndex(of: current()) ?? 0
            let popup = SettingsPopup(titles: titles, selected: selected) { index in
                guard all.indices.contains(index), all[index] != nil || defaultTitle != nil else { return }
                apply(all[index])
                refresh(families)
            }
            form.row(label, subtitle: range, control: popup)
            families.append(.init(options: all, current: current, popup: popup))
            if mixed, let shown = all[selected] { apply(shown) }
        }
        family(text("Left Sidebar Tabs", "左侧标签页"), range: text("Tabs 1–9", "标签页 1–9"),
               options: Modifiers.allCases.filter { $0 != .command },
               defaultTitle: title(.command) + text(" (Ghostty default)", "（Ghostty 默认）"),
               current: { settings.tabNumberModifiers ?? .command }, apply: { settings.tabNumberModifiers = $0 })
        family(text("Right Sidebar Panels", "右侧面板"), range: text("Panels 1–4", "面板 1–4"), options: Modifiers.allCases,
               mixed: Modifiers.shared(by: (1...4).map { settings.inspectorPanelShortcut(slot: $0) }) == nil,
               current: { Modifiers.shared(by: (1...4).map { settings.inspectorPanelShortcut(slot: $0) }) ?? .option },
               apply: { value in
                   guard let value else { return }
                   for slot in 1...4 { settings.setInspectorPanelShortcut(slot: slot, value: value.shortcut(digit: slot)) }
               })
        // Workspace shortcuts are matched only for Command chords.
        family(text("Workspaces", "工作区"), range: text("Workspaces 1–9", "工作区 1–9"),
               options: Modifiers.allCases.filter { $0.flags.contains(.command) },
               mixed: Modifiers.shared(by: (1...9).map { store.shortcut(slot: $0) }) == nil,
               current: { Modifiers.shared(by: (1...9).map { store.shortcut(slot: $0) }) ?? .controlCommand },
               apply: { value in
                   guard let value else { return }
                   for slot in 1...9 { store.setShortcut(slot: slot, value: value.shortcut(digit: slot)) }
               })
        refresh(families)
    }

    private func shortcut(_ form: NativeSettingsForm, _ title: String, value: String, fallback: String? = nil, workspaceSlot: Int? = nil,
                          menuAction: Selector? = nil, change: @escaping (String) -> Void) {
        let button = ShortcutRecorderButton()
        button.updateShortcut(value)
        let conflict = NSTextField(wrappingLabelWithString: "")
        conflict.font = .systemFont(ofSize: 11)
        conflict.textColor = .systemOrange
        let copy = strings
        func update(_ value: String) {
            let duplicate = workspaceSlot.flatMap { TerminalWorkspaceStore.shared.shortcutConflict(slot: $0) } ??
                OMGKeyboardShortcut(storageValue: value)?.conflictingMenuItemTitle(excluding: menuAction)
            conflict.stringValue = duplicate.map {
                copy.shortcutConflictCaption($0)
            } ?? ""
            conflict.isHidden = conflict.stringValue.isEmpty
        }
        update(value)
        var current = value
        button.widthAnchor.constraint(equalToConstant: 120).isActive = true
        button.toolTip = text("Click, then press a new shortcut", "点击后按下新的快捷键")
        let reset = SettingsActionButton("") {}
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: text("Reset", "重置"))
        reset.imagePosition = .imageOnly
        reset.isBordered = false
        reset.toolTip = text("Restore default shortcut", "恢复默认快捷键")
        reset.isEnabled = fallback != nil && value != fallback
        button.onCapture = { [weak button, weak reset] shortcut in
            guard workspaceSlot == nil || shortcut.modifiers.contains(.command) else {
                button?.updateShortcut(current); NSSound.beep(); return
            }
            current = shortcut.storageValue
            change(current); button?.updateShortcut(current); update(current)
            reset?.isEnabled = fallback != nil && current != fallback
        }
        let controls = NSStackView(views: [button])
        if let fallback {
            reset.invoke = { [weak reset] in
                current = fallback
                change(fallback); button.updateShortcut(fallback); update(fallback)
                reset?.isEnabled = false
            }
            controls.addArrangedSubview(reset)
        }
        if let row = form.row(title, control: controls) {
            row.labels.addArrangedSubview(conflict)
            conflict.widthAnchor.constraint(equalTo: row.labels.widthAnchor).isActive = true
        }
    }

    func confirm(_ title: String, message: String = "", actionTitle: String? = nil, action: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: actionTitle ?? text("Continue", "继续"))
        alert.addButton(withTitle: text("Cancel", "取消"))
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }
}
