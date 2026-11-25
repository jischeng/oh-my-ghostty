import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct NativeAISettingsTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func find<T: NSView>(_ type: T.Type, _ identifier: String, in view: NSView) throws -> T {
        try #require(descendants(view).compactMap { $0 as? T }
            .first { $0.accessibilityIdentifier() == identifier }, "missing \(identifier)")
    }

    /// A settings window on throwaway files, with fakes for everything that would leave the process.
    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "NativeAISettingsTests." + UUID().uuidString
        let settings: OhMyGhosttySettings
        let credentials: AICredentialStore
        let controller: NativeSettingsController
        let window: NSWindow
        let requests = Requests()
        var listResponse: (Data, Int) = (Data(#"{"data":[{"id":"alpha"},{"id":"beta"}]}"#.utf8), 200)

        init(language: OhMyGhosttyLanguage = .english) {
            settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
            settings.language = language
            credentials = AICredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
            let defaults = UserDefaults(suiteName: defaultsName) ?? .standard
            let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
            let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)
            controller = NativeSettingsController(settings: settings, initialSelection: .general,
                                                  registry: registry, agents: agents)
            controller.aiCredentials = credentials
            controller.aiAgentCatalog = AIAgentModelCatalog { agent in
                ["\(agent.rawValue)-one", "\(agent.rawValue)-two"]
            }
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(.init(width: 900, height: 680))
            let requests = requests
            controller.aiHTTPClient = AIHTTPClient { [weak self] request in
                requests.record(request)
                let (body, status) = await MainActor.run { self?.listResponse ?? (Data(), 500) }
                let url = request.url ?? URL(fileURLWithPath: "/")
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: nil)
                return (body, response ?? HTTPURLResponse())
            }
        }

        func close() {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            controller.activeModalSheet?.closePanel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        func record(_ request: URLRequest) { lock.lock(); stored.append(request); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func theAIPageUnifiesModelServicesCodingAgentsAndHistoryWithoutFeatureClutter() throws {
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let fixture = Fixture(language: language)
            defer { fixture.close() }
            let strings = SettingsStrings(language: language)
            let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
            fixture.settings.updateAIProvider(provider.id) { $0.mergeModels(["alpha"]) }
            fixture.controller.select(.agents)
            let view = fixture.controller.view
            view.layoutSubtreeIfNeeded()

            #expect(strings.tabTitle(.agents) == "AI")
            let form = try #require(fixture.controller.children.compactMap { $0 as? NativeSettingsForm }.first)
            let labels = descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
            for title in [strings.aiProvidersSection, strings.aiInstalledGroup,
                          strings.terminalCodingAgentsSection, strings.agentHistorySection,
                          strings.aiProviderSummary(fixture.settings.aiProviders[0])] {
                #expect(labels.contains(title), "missing \(title)")
            }
            // Feature-specific model assignments and notifications belong on their owning pages, not AI.
            #expect(!labels.contains(strings.aiTitleModelGroup))
            #expect(!labels.contains(strings.aiTaskModelsSection))
            #expect(!labels.contains(strings.notificationsSection))
            #expect(!descendants(view).contains { $0.accessibilityIdentifier() == "git.commit-ai.routes" })
            #expect(!descendants(view).contains { $0.accessibilityIdentifier() == "settings.ai.title.mode" })

            let rows = form.rowTitles
            let connection = try #require(rows.firstIndex(of: "Work proxy"))
            let addService = try #require(rows.firstIndex(of: strings.aiAddServiceLabel))
            let codex = try #require(rows.firstIndex(of: GitCommitAgent.codex.title))
            let claude = try #require(rows.firstIndex(of: GitCommitAgent.claude.title))
            let pi = try #require(rows.firstIndex(of: GitCommitAgent.pi.title))
            let opencode = try #require(rows.firstIndex(of: GitCommitAgent.opencode.title))
            let hooks = try #require(rows.firstIndex(of: strings.agentStatusHooksLabel))
            let historyLimit = try #require(rows.firstIndex(of: strings.agentHistoryLimitLabel))
            #expect(connection < addService && addService < codex)
            #expect(codex < claude && claude < pi && pi < opencode)
            #expect(opencode < hooks && hooks < historyLimit)
            #expect(rows.contains(strings.agentHistoryBackgroundIndexingLabel))

            _ = try find(NSButton.self, "settings.ai.provider." + provider.id.uuidString, in: view)
            _ = try find(NSButton.self, "settings.ai.provider.add", in: view)
            let manageLocalAgents = try find(NSButton.self, "settings.ai.coding-agents.local", in: view)
            for agent in GitCommitAgent.allCases {
                _ = try find(NSButton.self, "settings.ai.agent." + agent.rawValue, in: view)
            }
            // Showing the page asked no agent and no service for anything.
            #expect(fixture.controller.aiAgentCatalog.entry(.claude) == AIAgentModelCatalog.Entry())
            #expect(fixture.requests.all.isEmpty)

            // Managing local Coding Agents opens an inline modal sheet instead of pushing 2–3 subpages.
            manageLocalAgents.performClick(nil)
            #expect(fixture.controller.isShowing("agents"))
            let localSheet = try #require(fixture.controller.activeModalSheet as? LocalCodingAgentsSheetController)
            for agent in SupportedAgent.allCases {
                _ = try find(SettingsSwitch.self, "settings.ai.coding-agents.hook." + agent.rawValue, in: localSheet.view)
            }
            localSheet.closeSheet()
        }
    }

    @Test func addingAServiceBuffersInAModalSheetWithoutCreatingDraftGarbageOnCancel() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.select(.agents)
        try find(NSButton.self, "settings.ai.provider.add", in: controller.view).performClick(nil)

        // Clicking Add opens a modal sheet without polluting settings.aiProviders.
        #expect(fixture.settings.aiProviders.isEmpty)
        let cancelledSheet = try #require(controller.activeModalSheet as? AIProviderSheetController)
        cancelledSheet.nameField.stringValue = "Abandoned service"
        cancelledSheet.cancel()
        #expect(fixture.settings.aiProviders.isEmpty)

        // Now fill out and save a real API service; its key never enters settings.json or UI labels.
        try find(NSButton.self, "settings.ai.provider.add", in: controller.view).performClick(nil)
        let sheet = try #require(controller.activeModalSheet as? AIProviderSheetController)
        let sheetView = sheet.view

        let name = try find(SettingsTextField.self, "settings.ai.provider.name", in: sheetView)
        name.stringValue = "  Work proxy  "
        name.commit?(name.stringValue)
        #expect(name.stringValue == "Work proxy")

        let kind = try find(SettingsPopup.self, "settings.ai.provider.kind", in: sheetView)
        kind.selectItem(at: 1)
        kind.change?(1)
        #expect(sheet.draft.kind == .anthropic)

        let url = try find(SettingsTextField.self, "settings.ai.provider.base-url", in: sheetView)
        url.commit?("http://api.example.com")
        // Plain-HTTP remote host is rejected.
        #expect(sheet.draft.baseURL == "")
        url.commit?(" https://api.example.com/v1/messages ")
        #expect(sheet.draft.baseURL == "https://api.example.com/v1")
        #expect(url.stringValue == "https://api.example.com/v1")

        let key = try find(SettingsSecureField.self, "settings.ai.provider.api-key", in: sheetView)
        let clear = try find(NSButton.self, "settings.ai.provider.clear-api-key", in: sheetView)
        #expect(!clear.isEnabled)
        key.stringValue = "  secret-test-key  "
        key.commit?(key.stringValue)
        #expect(key.stringValue.isEmpty)
        #expect(clear.isEnabled)
        // Leaving the empty field does not erase the staged key.
        key.commit?("")
        #expect(clear.isEnabled)

        sheet.save()
        let provider = try #require(fixture.settings.aiProviders.first)
        #expect(provider.name == "Work proxy")
        #expect(provider.kind == .anthropic)
        #expect(provider.baseURL == "https://api.example.com/v1")
        #expect(fixture.credentials.apiKey(for: provider.id) == "secret-test-key")

        let saved = try String(contentsOf: fixture.directory.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!saved.contains("secret-test-key"))
        for view in descendants(controller.view) + descendants(sheetView) {
            #expect((view as? NSTextField)?.stringValue.contains("secret-test-key") != true)
            #expect((view as? NSTextField)?.placeholderString?.contains("secret-test-key") != true)
            #expect((view.accessibilityLabel() ?? "").contains("secret-test-key") == false)
        }

        // Reopen in edit mode to clear the stored key and toggle enabled off.
        try find(NSButton.self, "settings.ai.provider." + provider.id.uuidString, in: controller.view).performClick(nil)
        let editSheet = try #require(controller.activeModalSheet as? AIProviderSheetController)
        let editClear = try find(NSButton.self, "settings.ai.provider.clear-api-key", in: editSheet.view)
        #expect(editClear.isEnabled)
        editClear.performClick(nil)
        let enabled = try find(SettingsSwitch.self, "settings.ai.provider.enabled", in: editSheet.view)
        enabled.state = .off
        enabled.change?(false)
        editSheet.save()

        #expect(!fixture.credentials.hasAPIKey(for: provider.id))
        #expect(fixture.settings.aiProvider(provider.id)?.enabled == false)
    }

    @Test func fetchingReorderingEditingAndRemovingModelsWorksInsideTheProviderSheet() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) {
            $0.baseURL = "https://api.example.com"
            $0.models = [AIProviderModel(id: "alpha", contextWindow: 8_000)]
        }
        try fixture.credentials.setAPIKey("secret-test-key", for: provider.id)
        controller.select(.agents)
        controller.presentAIProviderSheet(id: provider.id)
        let sheet = try #require(controller.activeModalSheet as? AIProviderSheetController)

        try find(NSButton.self, "settings.ai.provider.fetch-models", in: sheet.view).performClick(nil)
        #expect(await settle { sheet.draft.models.count == 2 })
        #expect(sheet.draft.models == [
            AIProviderModel(id: "alpha", contextWindow: 8_000), AIProviderModel(id: "beta"),
        ])
        let request = try #require(fixture.requests.all.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-test-key")

        let add = try find(SettingsTextField.self, "settings.ai.provider.add-model-id", in: sheet.view)
        add.stringValue = " manual-model "
        try find(NSButton.self, "settings.ai.provider.add-model", in: sheet.view).performClick(nil)
        #expect(sheet.draft.models.map(\.id) == ["alpha", "beta", "manual-model"])
        #expect(add.stringValue.isEmpty)

        let table = try find(NSTableView.self, "settings.ai.models", in: sheet.view)
        #expect(await settle { table.numberOfRows == 3 })
        let cell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? AIModelListCell)
        cell.contextField.stringValue = "128k"
        cell.outputField.stringValue = "4,096"
        cell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                   object: cell.outputField))
        #expect(sheet.draft.models[1] == AIProviderModel(id: "beta", contextWindow: 128_000, maxOutputTokens: 4_096))
        #expect(cell.contextField.stringValue == "128000")

        // Reorder models inside the provider sheet so custom order is persisted on Save.
        #expect(sheet.list.moveModel("manual-model", by: -1))
        #expect(sheet.draft.models.map(\.id) == ["alpha", "manual-model", "beta"])

        // Removing a model and saving also cleans up routes pointing at that model.
        fixture.settings.aiTitleRoute = AITitleRoute(provider: provider.id, model: "beta")
        fixture.settings.gitCommitAIRoutes = [GitCommitAIRoute(provider: provider.id, model: "beta"),
                                              GitCommitAIRoute(provider: provider.id, model: "alpha")]
        let betaCell = try #require(table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? AIModelListCell)
        betaCell.removeButton.performClick(nil)
        sheet.save()

        #expect(fixture.settings.aiProvider(provider.id)?.models.map(\.id) == ["alpha", "manual-model"])
        #expect(fixture.settings.aiTitleRoute == nil)
        #expect(fixture.settings.gitCommitAIRoutes.map(\.model) == ["alpha"])
    }

    @Test func aFailedFetchKeepsTheListAndNeverShowsTheKey() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) {
            $0.baseURL = "https://api.example.com"
            $0.mergeModels(["alpha"])
        }
        try fixture.credentials.setAPIKey("secret-test-key", for: provider.id)
        fixture.listResponse = (Data(#"{"error":"upstream rejected secret-test-key"}"#.utf8), 500)
        controller.presentAIProviderSheet(id: provider.id)
        let sheet = try #require(controller.activeModalSheet as? AIProviderSheetController)
        let fetch = try find(NSButton.self, "settings.ai.provider.fetch-models", in: sheet.view)
        fetch.performClick(nil)
        #expect(await settle { fixture.requests.all.count == 1 && fetch.isEnabled })

        #expect(sheet.draft.models.map(\.id) == ["alpha"])
        let labels = descendants(sheet.view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains { $0.hasPrefix("HTTP 500") })
        #expect(!labels.contains { $0.contains("secret-test-key") })

        // Without a usable base URL nothing is sent at all.
        sheet.urlField.stringValue = ""
        sheet.urlField.commit?("")
        fetch.performClick(nil)
        #expect(fixture.requests.all.count == 1)
    }

    @Test func removingAConnectionDeletesItsKeyAndRoutes() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) { $0.mergeModels(["alpha"]) }
        fixture.settings.aiTitleRoute = AITitleRoute(provider: provider.id, model: "alpha")
        try fixture.credentials.setAPIKey("secret-test-key", for: provider.id)

        fixture.controller.select(.agents)
        fixture.controller.presentAIProviderSheet(id: provider.id)
        let sheet = try #require(fixture.controller.activeModalSheet as? AIProviderSheetController)
        _ = try find(NSButton.self, "settings.ai.provider.remove", in: sheet.view)

        sheet.deleteProviderConfirmed()
        #expect(fixture.settings.aiProviders.isEmpty)
        #expect(fixture.settings.aiTitleRoute == nil)
        #expect(!fixture.credentials.hasAPIKey(for: provider.id))
        #expect(!descendants(fixture.controller.view).contains {
            $0.accessibilityIdentifier() == "settings.ai.provider." + provider.id.uuidString
        })
    }

    @Test func clickingALocalCLIOpensItsModalSheetAndSharesDiscoveredModels() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.select(.agents)
        try find(NSButton.self, "settings.ai.agent.opencode", in: controller.view).performClick(nil)
        let sheet = try #require(controller.activeModalSheet as? AICLIProviderSheetController)

        let table = try find(NSTableView.self, "settings.ai.models", in: sheet.view)
        #expect(await settle { table.numberOfRows == 2 })
        #expect(controller.aiAgentCatalog.entry(.opencode).models == ["opencode-one", "opencode-two"])
        // A discovered list is read-only: no limit fields, no remove buttons.
        #expect(!descendants(sheet.view).contains {
            $0.accessibilityIdentifier() == "settings.ai.model.context-window"
        })
        let refresh = try find(NSButton.self, "settings.ai.agent.refresh-models", in: sheet.view)
        #expect(refresh.isEnabled)
        // Only Codex exposes the managed ACP helper package row.
        #expect(!descendants(sheet.view).contains {
            $0.accessibilityIdentifier() == "settings.ai.agent.codex.adapter-update"
        })

        // AI overview updates its CLI row subtitle immediately from the shared catalog.
        #expect(await settle {
            descendants(controller.view).compactMap { ($0 as? NSTextField)?.stringValue }
                .contains { $0.contains(SettingsStrings(language: .english).aiModelCount(2)) }
        })

        try find(NSButton.self, "settings.ai.agent.codex", in: controller.view).performClick(nil)
        let codexSheet = try #require(controller.activeModalSheet as? AICLIProviderSheetController)
        _ = try find(NSButton.self, "settings.ai.agent.codex.adapter-update", in: codexSheet.view)
    }

    @Test func pickersPreserveUserSelectionOrderAndUnifyAPIServicesWithLocalCLIs() throws {
        let strings = SettingsStrings(language: .english)
        let first = AIProvider(name: "Same name", baseURL: "https://one.example.com",
                               models: [AIProviderModel(id: "a"), AIProviderModel(id: "b"), AIProviderModel(id: "c")])
        let second = AIProvider(name: "Same name", baseURL: "https://two.example.com",
                                models: [AIProviderModel(id: "x")])
        let off = AIProvider(name: "Off", baseURL: "https://off.example.com", enabled: false,
                             models: [AIProviderModel(id: "y")])
        let empty = AIProvider(name: "Empty", baseURL: "https://empty.example.com")
        let eligible = AIUnifiedModelPickerController.eligibleProviders([first, off, empty, second])
        #expect(eligible == [first, second])

        // Unified multi-select picker combines enabled API services and Local CLIs and preserves click order.
        let catalog = AIAgentModelCatalog { agent in ["\(agent.rawValue)-live"] }
        catalog.recordModels(["codex-cached-1", "codex-cached-2"], for: .codex)
        var unifiedPicked: [AIUnifiedModelPickerController.PickedModel] = []
        let unified = AIUnifiedModelPickerController(
            providers: [first, off, empty, second],
            catalog: catalog,
            allowsMultiple: true,
            strings: strings,
            heading: "Add Generation Models"
        ) { unifiedPicked = $0 }
        _ = unified.view
        #expect(unified.sources == [
            .provider(first),
            .provider(second),
            .agent(.codex),
            .agent(.claude),
            .agent(.pi),
            .agent(.opencode),
        ])
        #expect(unified.sourcePopup.numberOfItems == 6)
        #expect(!unified.confirmButton.isEnabled)
        // Select an API model first ("c"), switch to Codex (cached!) and select a CLI model, then back to API ("a").
        unified.toggle("c")
        unified.selectSource(at: 2) // .agent(.codex)
        #expect(unified.modelTable.numberOfRows == 2)
        unified.toggle("codex-cached-2")
        unified.selectSource(at: 0) // back to .provider(first)
        unified.toggle("a")
        unified.confirm()
        #expect(unifiedPicked == [
            .init(target: .provider(first.id), model: "c"),
            .init(target: .agent(.codex), model: "codex-cached-2"),
            .init(target: .provider(first.id), model: "a"),
        ])

        // Unified single-select picker (used by `Choose Title Model`) replaces prior choices across API and CLI sources.
        var singlePicked: [AIUnifiedModelPickerController.PickedModel] = []
        let single = AIUnifiedModelPickerController(
            providers: [first, second],
            catalog: catalog,
            allowsMultiple: false,
            initialTarget: .provider(second.id),
            strings: strings,
            heading: "Choose Title Model"
        ) { singlePicked = $0 }
        _ = single.view
        #expect(single.currentSource == .provider(second))
        single.toggle("x")
        #expect(single.selected == [.init(target: .provider(second.id), model: "x")])
        single.selectSource(at: 2) // .agent(.codex)
        single.toggle("codex-cached-1")
        #expect(single.selected == [.init(target: .agent(.codex), model: "codex-cached-1")])
        single.confirm()
        #expect(singlePicked == [.init(target: .agent(.codex), model: "codex-cached-1")])

        // Chaining `New API Service…` from the title model picker opens `AIProviderSheetController` without creating garbage.
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.controller.select(.tabs)
        try find(NSButton.self, "settings.ai.title.choose-model", in: fixture.controller.view).performClick(nil)
        let titlePicker = try #require(fixture.controller.activeModalSheet as? AIUnifiedModelPickerController)
        #expect(!titlePicker.allowsMultiple)
        #expect(!titlePicker.addProviderButton.isHidden)
        titlePicker.addProvider()
        #expect(fixture.settings.aiProviders.isEmpty)
        #expect(fixture.controller.activeModalSheet is AIProviderSheetController)
    }

    @Test func automaticTabTitleControlsLiveOnViewsAndTabsPage() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let strings = SettingsStrings(language: .english)
        let controller = fixture.controller
        #expect(controller.aiTitleModelSummary() == strings.aiTitleModelUnset)

        fixture.settings.aiTitleRoute = AITitleRoute(agent: .codex, model: "gpt-5-codex")
        #expect(controller.aiTitleModelSummary() == "Codex · gpt-5-codex")

        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) { $0.mergeModels(["alpha"]) }
        fixture.settings.aiTitleRoute = AITitleRoute(provider: provider.id, model: "alpha")
        #expect(controller.aiTitleModelSummary() == "Work proxy · alpha")

        fixture.settings.updateAIProvider(provider.id) { $0.enabled = false }
        #expect(controller.aiTitleModelSummary().hasPrefix("Work proxy · alpha: "))

        fixture.settings.aiProviders = []
        #expect(controller.aiTitleModelSummary().hasPrefix("alpha: "))

        controller.select(.tabs)
        _ = try find(SettingsPopup.self, "settings.ai.title.mode", in: controller.view)
        let alwaysUseAI = try find(SettingsSwitch.self, "settings.ai.title.always-use-ai", in: controller.view)
        #expect(alwaysUseAI.isEnabled)
        alwaysUseAI.state = .on
        alwaysUseAI.change?(true)
        #expect(fixture.settings.agentSessionTitleAlwaysUseAI)
        fixture.settings.agentSessionTitleMode = .native
        controller.select(.tabs)
        let disabledAlwaysUseAI = try find(SettingsSwitch.self, "settings.ai.title.always-use-ai", in: controller.view)
        #expect(!disabledAlwaysUseAI.isEnabled)
        #expect(disabledAlwaysUseAI.state == .on)

        let clear = try find(NSButton.self, "settings.ai.title.clear-model", in: controller.view)
        #expect(clear.isEnabled)
        clear.performClick(nil)
        #expect(fixture.settings.aiTitleRoute == nil)
    }

    @Test func commitRoutesAndPromptSheetLiveOnGitPage() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) { $0.mergeModels(["alpha"]); $0.enabled = false }
        fixture.settings.gitCommitAIRoutes = [GitCommitAIRoute(agent: .claude, model: "sonnet"),
                                              GitCommitAIRoute(provider: provider.id, model: "alpha")]
        fixture.controller.select(.git)
        let table = try find(NSTableView.self, "git.commit-ai.routes", in: fixture.controller.view)
        #expect(table.numberOfRows == 2)
        let agentCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(agentCell.accessibilityLabel() == "Claude Code · sonnet")
        let apiCell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(apiCell.accessibilityLabel() == "Work proxy · alpha")
        let apiLabels = descendants(apiCell).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(apiLabels.contains("Work proxy (off)"))
        #expect(apiLabels.contains("alpha"))

        try find(NSButton.self, "settings.ai.commit.add-models", in: fixture.controller.view).performClick(nil)
        #expect(fixture.controller.activeModalSheet is AIUnifiedModelPickerController)

        try find(NSButton.self, "settings.ai.commit.edit-prompt", in: fixture.controller.view).performClick(nil)
        #expect(fixture.controller.activeModalSheet is GitCommitAIPromptController)
    }

    @Test func modalSheetsMaintainFullHeightChainCleanlyOnLiveWindowAndSaveCredentialsAtomically() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.window.orderFront(nil)
        fixture.controller.select(.git)

        // Open unified model picker on a real NSWindow -> verify full sheet height -> chain New API Service…
        try find(NSButton.self, "settings.ai.commit.add-models", in: fixture.controller.view).performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        let pickerSheet = try #require(fixture.window.attachedSheet)
        #expect(pickerSheet.frame.height >= 480, "Unified picker sheet frame: \(pickerSheet.frame)")

        let picker = try #require(fixture.controller.activeModalSheet as? AIUnifiedModelPickerController)
        picker.addProvider()
        #expect(await settle { fixture.controller.activeModalSheet is AIProviderSheetController })
        try await Task.sleep(for: .milliseconds(100))

        let providerWindow = try #require(fixture.window.attachedSheet)
        #expect(providerWindow.frame.height >= 500, "AIProviderSheetController frame must not collapse: \(providerWindow.frame)")
        let providerSheet = try #require(fixture.controller.activeModalSheet as? AIProviderSheetController)
        #expect(providerSheet.view.fittingSize.height >= 500)

        // Block credentials path with a directory so `setAPIKey` throws: `settings.aiProviders` must stay empty!
        let badCredDir = fixture.directory.appendingPathComponent("blocked-creds.json")
        try FileManager.default.createDirectory(at: badCredDir, withIntermediateDirectories: true)
        fixture.controller.aiCredentials = AICredentialStore(fileURL: badCredDir)
        fixture.controller.presentAIProviderSheet(id: nil)
        #expect(await settle { (fixture.controller.activeModalSheet as? AIProviderSheetController) !== providerSheet })
        let failingSheet = try #require(fixture.controller.activeModalSheet as? AIProviderSheetController)
        failingSheet.nameField.stringValue = "Should Not Persist"
        failingSheet.urlField.stringValue = "https://api.example.com"
        failingSheet.keyField.stringValue = "sk-fail-key"
        failingSheet.save()
        #expect(fixture.settings.aiProviders.isEmpty)

        // CLI provider sheet also maintains full readable height.
        fixture.controller.presentAICLIProviderSheet(.codex)
        #expect(await settle { fixture.controller.activeModalSheet is AICLIProviderSheetController })
        let cliSheet = try #require(fixture.controller.activeModalSheet as? AICLIProviderSheetController)
        #expect(cliSheet.view.fittingSize.height >= 480)
    }
}
