import AppKit
import Combine

extension NativeSettingsController {
    func build(_ tab: OhMyGhosttySettingsTab, into form: NativeSettingsForm) {
        switch tab {
        case .general:
            form.section(text("Language & Quit", "语言与退出"))
            picker(form, strings.languageLabel, \.language, [(.system, strings.languageSystem), (.english, "English"), (.simplifiedChinese, "简体中文")])
            toggle(form, strings.quitWithoutConfirmationLabel, \.quitWithoutConfirmation)
            core(.lifecycle, in: form)
        case .appearance: appearance(form)
        case .tabs:
            form.section(strings.layoutSection)
            picker(form, strings.tabLayoutLabel, \.tabLayout, [(.vertical, strings.verticalOption), (.horizontal, strings.horizontalOption)])
            toggle(form, strings.showSidebarLabel, \.sidebarVisible)
            number(form, strings.sidebarWidthLabel, \.defaultSidebarWidth, range: 176...480)
            form.section(strings.organizationSection)
            picker(form, strings.groupingLabel, \.groupingMode, GhosttyTabGroupingMode.allCases.map { ($0, strings.groupingTitle($0)) })
            picker(form, strings.orderingLabel, \.orderingMode, GhosttyTabOrderingMode.allCases.map { ($0, strings.orderingTitle($0)) })
            picker(form, strings.pathDisplayLabel, \.tabPathDisplay, OhMyGhosttyTabPathDisplay.allCases.map { ($0, strings.pathDisplayTitle($0)) })
            form.section(text("Display", "显示"))
            picker(form, strings.rowDensityLabel, \.tabRowDensity, OhMyGhosttyTabRowDensity.allCases.map { ($0, strings.densityTitle($0)) })
            toggle(form, strings.showShortcutLabelsLabel, \.showShortcutLabels)
            more(form, text("More tab options", "更多标签选项")) { [weak self] page in
                guard let self else { return }
                page.section(self.strings.appearanceTabsSection)
                self.number(page, self.strings.tabIconSizeLabel, \.tabIconSize, range: 12...20)
                self.toggle(page, self.strings.rememberSidebarWidthLabel, \.rememberSidebarWidth)
                self.picker(page, self.strings.terminalResizeRenderingLabel, \.terminalResizeRendering,
                            TerminalResizeRenderingMode.allCases.map { ($0, self.strings.terminalResizeRenderingTitle($0)) })
                page.row(self.strings.resetTabsButton, control: SettingsActionButton(self.text("Reset", "重置")) { [weak self] in
                    self?.settings.resetTabs(); self?.select(.tabs)
                })
            }
        case .terminal: terminal(form)
        case .controls: controls(form)
        case .editor: editor(form)
        case .keyboard: keyboard(form)
        case .git:
            form.section(strings.gitSection)
            picker(form, strings.gitAutoFetchLabel, \.gitAutoFetchInterval,
                   Array(Set([0, 1, 2, 5, 10, 15, 30, 60, settings.gitAutoFetchInterval])).sorted().map { ($0, strings.gitAutoFetchIntervalTitle($0)) })
            form.section(text("Commit messages", "提交信息"))
            let models = form.row(text("AI models", "AI 模型"), control:
                SettingsActionButton(text("Add Models…", "添加模型…")) { [weak self] in
                    guard let self else { return }
                    GitCommitAISettingsPanel.presentAddModels(settings: self.settings, from: self.view.window)
                })
            let coordinator = GitCommitAIRoutesTable.Coordinator(settings: settings)
            let routes = GitCommitAIRoutesTable.makeNativeView(coordinator: coordinator)
            routes.hasVerticalScroller = false
            form.retained.append(coordinator)
            // The list grows with its rows; the page is the only scroll area.
            let height = form.embed(routes, height: 0)
            let copy = strings
            let divider = form.embedSeparator
            let update: ([GitCommitAIRoute]) -> Void = { [weak coordinator, weak routes, weak divider] list in
                divider?.isHidden = list.isEmpty
                coordinator?.tableView?.reloadData()
                height?.constant = CGFloat(list.count) * 40
                routes?.isHidden = list.isEmpty
                models?.setSubtitle(list.isEmpty
                    ? copy.t("No models yet. Add one to generate commit messages with AI.", "尚未添加模型。添加后即可用 AI 生成提交信息。")
                    : copy.t("Tried from top to bottom. Drag or use the arrows to reorder.", "按从上到下的顺序尝试，可拖动或用箭头调整。"))
            }
            update(settings.gitCommitAIRoutes)
            let token = settings.$gitCommitAIRoutes.receive(on: RunLoop.main).sink { update($0) }
            form.retained.append(token)
            form.section(text("Commit style", "提交风格"))
            form.row(text("Custom prompt", "自定义提示词"),
                     subtitle: text("Custom instructions for generated messages.", "自定义生成提交信息时使用的提示词。"),
                     control: SettingsActionButton(text("Edit…", "编辑…")) { [weak self] in
                guard let self else { return }; GitCommitAISettingsPanel.presentPrompt(settings: self.settings, from: self.view.window)
            })
        case .ssh: remoteHosts(form)
        case .mobile: mobileAccess(form)
        case .agents: agentOverview(form)
        case .plugins: plugins(form)
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
            buildOMGDoctorSection(form, doctor: doctor)
        }
    }

    private func terminal(_ form: NativeSettingsForm) {
        form.section(text("On launch", "启动时"))
        picker(form, strings.startupModeLabel, \.startupMode, OMGStartupMode.allCases.map { ($0, strings.startupModeTitle($0)) })
        form.section(strings.newSessionInheritanceSection, caption: strings.newSessionInheritanceCaption)
        picker(form, strings.newTabInheritanceLabel, \.newTabInheritance,
               NewSessionInheritance.allCases.map { ($0, strings.newSessionInheritanceTitle($0)) })
        picker(form, strings.newSplitInheritanceLabel, \.newSplitInheritance,
               NewSessionInheritance.allCases.map { ($0, strings.newSessionInheritanceTitle($0)) })
        form.note(strings.newSessionInheritanceResumeWarning)
        form.section(text("When quitting OMG", "退出 OMG 时"),
                     caption: text("Leave a switch off to keep those sessions running in the background.", "关闭开关后，相应会话会在退出 OMG 后继续运行。"))
        for (title, key) in [(text("Close local sessions on quit", "退出时关闭本地会话"), \OhMyGhosttySettings.keepLocalSessionsOnQuit),
                             (text("Close SSH sessions on quit", "退出时关闭 SSH 会话"), \OhMyGhosttySettings.keepSSHSessionsOnQuit)] {
            let control = SettingsSwitch(value: !settings[keyPath: key]) { [weak settings] in settings?[keyPath: key] = !$0 }
            form.row(title, control: control)
            form.refreshers.append { [weak settings, weak control] in
                if let settings { control?.state = settings[keyPath: key] ? .off : .on }
            }
        }
        form.section(text("Session management", "会话管理"))
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
        more(form, text("Session options", "会话选项")) { [weak self] page in
            guard let self else { return }
            page.section(self.text("Retention", "保留"))
            self.number(page, self.text("Disconnected lifetime (hours)", "断开后保留时长（小时）"), \.runtimeDetachedHours, range: 0...8760,
                        help: self.text("0 means no time limit.", "0 表示不限时长。"))
            let formatter = ISO8601DateFormatter()
            let date = SettingsDatePicker(value: formatter.date(from: self.settings.runtimeExpiration) ?? Date().addingTimeInterval(86_400)) { [weak settings = self.settings] in settings?.runtimeExpiration = formatter.string(from: $0)
            }
            date.isEnabled = !self.settings.runtimeExpiration.isEmpty
            let enabled = SettingsSwitch(value: date.isEnabled) { [weak settings = self.settings, weak date] value in
                date?.isEnabled = value
                settings?.runtimeExpiration = value ? formatter.string(from: date?.dateValue ?? Date()) : ""
            }
            page.row(self.text("Expiration date", "截止时间"), control: NSStackView(views: [enabled, date]))
            self.toggle(page, self.text("Clean up completed Agent sessions", "回收已完成的 Agent 会话"), \.runtimeCloseOnAgentDone,
                        help: self.strings.runtimeCloseOnDoneCaption)
            self.number(page, self.strings.runtimeDoneGrace, \.runtimeDoneGraceSeconds, range: 1...86400)
            page.section(self.text("Local terminals", "本地终端"))
            self.toggle(page, self.text("Use background sessions for new terminals", "新终端使用后台会话"), \.localRuntimeEnabled,
                        help: self.strings.runtimeLocalRuntimeCaption)
            self.toggle(page, self.text("Persist Quick Terminal in background session", "快捷终端启用持久化后台会话"), \.quickTerminalRuntimeEnabled,
                        help: self.strings.runtimeQuickTerminalCaption)
        }
        core(.shell, in: form)
        more(form, text("Terminal notifications", "终端通知")) { [weak self] page in self?.core(.notifications, in: page) }
    }

    private func appearance(_ form: NativeSettingsForm) {
        form.section(text("Theme", "主题"))
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
        more(form, strings.editorThemeSection) { [weak self] page in
            guard let self else { return }
            page.section(self.strings.editorThemeSection)
            let catalogs = Array(Set(GhosttyThemeCatalog.availableThemes() + [self.settings.editorThemeName].compactMap { $0 })).sorted()
            let options = [("follow", self.strings.editorSyntaxThemeTitle(.followTerminal))] +
                catalogs.map { ("catalog:" + $0, $0) } +
                EditorSyntaxTheme.allCases.filter { $0 != .followTerminal }.map { ("builtin:" + $0.rawValue, self.strings.editorSyntaxThemeTitle($0)) }
            let selected = self.settings.editorThemeName.map { "catalog:" + $0 } ??
                (self.settings.editorSettings.followsOMG ? "follow" : "builtin:" + self.settings.editorSyntaxTheme.rawValue)
            page.row(self.strings.editorSyntaxThemeLabel, control: SettingsPopup(titles: options.map(\.1),
                selected: options.firstIndex { $0.0 == selected } ?? 0) { [weak settings = self.settings] index in
                    let value = options[index].0
                    if value.hasPrefix("catalog:") { settings?.editorThemeName = String(value.dropFirst(8)) } else {
                        settings?.editorThemeName = nil
                        settings?.editorSyntaxTheme = value == "follow" ? .followTerminal :
                            EditorSyntaxTheme(rawValue: String(value.dropFirst(8))) ?? .followTerminal
                    }
                })
            let opacity = SettingsNumberField(value: self.settings.editorOpacity, range: 0.05...1, step: 0.05) { [weak settings = self.settings] in settings?.editorOpacity = $0
            }
            opacity.field.isEnabled = !self.settings.editorSettings.followsOMG
            opacity.stepper.isEnabled = !self.settings.editorSettings.followsOMG
            page.row(self.strings.backgroundOpacityLabel, control: opacity)
            let blur = SettingsPopup(titles: OhMyGhosttyBackgroundBlur.allCases.map { self.strings.blurTitle($0) },
                                     selected: OhMyGhosttyBackgroundBlur.allCases.firstIndex(of: self.settings.editorBlur) ?? 0) { [weak settings = self.settings] in settings?.editorBlur = OhMyGhosttyBackgroundBlur.allCases[$0]
            }
            blur.isEnabled = !self.settings.editorSettings.followsOMG
            page.row(self.strings.backgroundBlurLabel, control: blur)
            let refresh = { [weak self, weak opacity, weak blur] in
                guard let self else { return }
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
                let value = editable ? self.settings.editorBlur : self.settings.backgroundBlurOverride ?? self.inheritedConfig.editorBackgroundBlur
                blur?.selectItem(at: OhMyGhosttyBackgroundBlur.allCases.firstIndex(of: value) ?? 0)
            }
            refresh()
            page.refreshers.append(refresh)
        }
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
        toggle(form, strings.quickInputControlJNewlineLabel, \.quickInputControlJNewline)
        form.toggle(strings.quickInputImportLabel, value: !settings.quickInputImportShortcut.isEmpty) { [weak settings] in
            settings?.quickInputImportShortcut = $0 ? "auto" : ""
        }
        if !settings.quickInputImportShortcut.isEmpty, settings.quickInputImportShortcut != "auto",
           QuickInputDraftBridge.keys(settings.quickInputImportShortcut) == nil {
            form.note(strings.quickInputImportInvalid)
        }
        more(form, strings.quickInputHistoryTitle) { [weak self] page in
            guard let self else { return }
            page.section(self.strings.quickInputHistoryTitle)
            self.picker(page, self.strings.quickInputHistoryScopeLabel, \.quickInputHistoryScope, QuickInputHistoryScope.allCases.map { ($0, self.strings.quickInputHistoryScopeName($0)) })
            self.picker(page, self.strings.quickInputHistoryInsertionLabel, \.quickInputHistoryInsertionMode, QuickInputHistoryInsertionMode.allCases.map { ($0, self.strings.quickInputHistoryInsertionName($0)) })
            self.number(page, self.strings.quickInputHistoryRetentionLabel, \.quickInputHistoryRetentionDays, range: 1...365)
            self.toggle(page, self.strings.quickInputHistoryKeepLabel, \.quickInputHistoryKeepAfterQuit, help: self.strings.quickInputHistoryPrivacyCaption)
            page.row(self.strings.quickInputHistoryClearButton, control: SettingsActionButton(self.text("Clear…", "清除…")) { [weak self] in
                guard let self else { return }
                self.confirm(self.strings.quickInputHistoryClearTitle, message: self.strings.quickInputHistoryClearMessage,
                             actionTitle: self.strings.quickInputHistoryClearConfirm) { QuickInputHistoryStore.shared.clear() }
            })
            if QuickInputHistoryStore.shared.storageError != nil { page.note(self.strings.quickInputHistoryStorageError) }
        }
        core(.selection, in: form)
        more(form, text("Clipboard and mouse", "剪贴板与鼠标")) { [weak self] page in
            self?.core(.clipboard, in: page); self?.core(.mouse, in: page); self?.core(.keyboard, in: page)
        }
    }

    private func keyboard(_ form: NativeSettingsForm) {
        form.section(strings.quickInputSection,
                     caption: text("Click a shortcut, then press the new key combination. Press Esc to cancel.",
                                   "点击快捷键后按下新的组合键即可修改，按 Esc 取消。"))
        shortcut(form, strings.quickInputShortcutLabel, value: settings.quickInputShortcut,
                 fallback: OMGKeyboardShortcut.defaultQuickInput.storageValue) { [weak settings] in settings?.quickInputShortcut = $0 }
        form.section(strings.rightSidebarShortcutsSection)
        for slot in 1...4 {
            shortcut(form, strings.inspectorPanelSlotLabel(slot: slot), value: settings.inspectorPanelShortcut(slot: slot),
                     fallback: OMGKeyboardShortcut.defaultInspectorPanel(slot: slot).storageValue) { [weak settings] in settings?.setInspectorPanelShortcut(slot: slot, value: $0)
            }
        }
        form.section(text("Workspaces", "工作区"),
                     caption: text("Workspace shortcuts must include Command.", "工作区快捷键必须包含 Command 键。"))
        for slot in 0...9 {
            shortcut(form, slot == 0 ? text("Workspace switcher", "工作区切换器") : text("Workspace \(slot)", "工作区 \(slot)"),
                     value: TerminalWorkspaceStore.shared.shortcut(slot: slot),
                     fallback: TerminalWorkspaceStore.defaultShortcut(slot: slot), workspaceSlot: slot) {
                TerminalWorkspaceStore.shared.setShortcut(slot: slot, value: $0)
            }
        }
        form.section(text("Terminal", "终端"))
        form.row(strings.keybindingsSection,
                 subtitle: text("Terminal keybindings are defined in the Ghostty config file.", "终端快捷键在 Ghostty 配置文件中定义。"),
                 control: SettingsActionButton(strings.openFileButton) { (NSApp.delegate as? AppDelegate)?.ghostty.openConfig() })
    }

    private func shortcut(_ form: NativeSettingsForm, _ title: String, value: String, fallback: String? = nil, workspaceSlot: Int? = nil,
                          change: @escaping (String) -> Void) {
        let button = ShortcutRecorderButton()
        button.updateShortcut(value)
        let conflict = NSTextField(wrappingLabelWithString: "")
        conflict.font = .systemFont(ofSize: 11)
        conflict.textColor = .systemOrange
        let copy = strings
        func update(_ value: String) {
            let duplicate = workspaceSlot.flatMap { TerminalWorkspaceStore.shared.shortcutConflict(slot: $0) } ??
                OMGKeyboardShortcut(storageValue: value)?.conflictingMenuItemTitle()
            conflict.stringValue = duplicate.map {
                copy.shortcutConflictCaption($0)
            } ?? ""
            conflict.isHidden = conflict.stringValue.isEmpty
        }
        update(value)
        var current = value
        // A fixed width keeps the column aligned while the title changes during recording.
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
