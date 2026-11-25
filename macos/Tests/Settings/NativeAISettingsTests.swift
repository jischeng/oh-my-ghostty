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

    @Test func theAIPageListsBothKindsOfProviderAndTheModelsPerTask() throws {
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
            for title in [strings.aiProvidersSection, strings.aiTitleModelGroup, strings.aiTaskModelsSection,
                          strings.terminalCodingAgentsSection, strings.agentNotificationsAndHistorySection,
                          strings.aiProviderSummary(fixture.settings.aiProviders[0])] {
                #expect(labels.contains(title), "missing \(title)")
            }
            // Local CLI models live behind one consolidated link instead of duplicating Agent rows on the main page.
            let rows = form.rowTitles
            #expect(!rows.contains(GitCommitAgent.claude.title))
            #expect(!descendants(view).contains { $0.accessibilityIdentifier() == "settings.ai.agent.claude" })

            let connection = try #require(rows.firstIndex(of: "Work proxy"))
            let addService = try #require(rows.firstIndex(of: strings.aiAddServiceLabel))
            let localCLIs = try #require(rows.firstIndex(of: strings.aiLocalCLIModelsLabel))
            let titles = try #require(rows.firstIndex(of: strings.agentSessionTitleLabel))
            let commitPrompt = try #require(rows.firstIndex(of: strings.gitCustomPromptLabel))
            let behavior = try #require(rows.firstIndex(of: strings.agentStatusHooksLabel))
            let notifications = try #require(rows.firstIndex(of: strings.notifyTaskCompleteLabel))
            let historyLimit = try #require(rows.firstIndex(of: strings.agentHistoryLimitLabel))
            #expect(connection < addService && addService < localCLIs)
            #expect(localCLIs < titles && titles < commitPrompt)
            #expect(commitPrompt < behavior && behavior < notifications && notifications < historyLimit)
            #expect(rows.contains(strings.aiTitleModelLabel))
            #expect(rows.contains(strings.agentHistoryBackgroundIndexingLabel))

            _ = try find(NSButton.self, "settings.ai.provider." + provider.id.uuidString, in: view)
            for identifier in ["settings.ai.provider.add", "settings.ai.local-cli-models",
                               "settings.ai.commit.add-models", "settings.ai.commit.edit-prompt",
                               "settings.ai.title.choose-model", "settings.ai.title.clear-model",
                               "settings.ai.coding-agents.local"] {
                _ = try find(NSButton.self, identifier, in: view)
            }
            _ = try find(SettingsPopup.self, "settings.ai.title.mode", in: view)
            let alwaysUseAI = try find(SettingsSwitch.self, "settings.ai.title.always-use-ai", in: view)
            #expect(alwaysUseAI.state == .off)
            #expect(alwaysUseAI.isEnabled)
            #expect(rows.contains(strings.agentSessionTitleAlwaysUseAILabel))
            _ = try find(NSTableView.self, "git.commit-ai.routes", in: view)
            // Showing the page asked no agent and no service for anything.
            #expect(fixture.controller.aiAgentCatalog.entry(.claude) == AIAgentModelCatalog.Entry())
            #expect(fixture.requests.all.isEmpty)
        }
    }

    @Test func aConnectionIsAddedEditedAndItsKeyNeverReachesSettingsOrAControl() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.select(.agents)
        try find(NSButton.self, "settings.ai.provider.add", in: controller.view).performClick(nil)

        let provider = try #require(fixture.settings.aiProviders.first)
        #expect(provider.name == SettingsStrings(language: .english).aiNewConnectionName)
        #expect(controller.isShowing("ai-provider:" + provider.id.uuidString))

        let name = try find(SettingsTextField.self, "settings.ai.provider.name", in: controller.view)
        name.stringValue = "  Work proxy  "
        name.commit?(name.stringValue)
        #expect(fixture.settings.aiProvider(provider.id)?.name == "Work proxy")
        #expect(name.stringValue == "Work proxy")
        name.commit?("   ")
        #expect(fixture.settings.aiProvider(provider.id)?.name == "Work proxy")

        let kind = try find(SettingsPopup.self, "settings.ai.provider.kind", in: controller.view)
        kind.selectItem(at: 1)
        kind.change?(1)
        #expect(fixture.settings.aiProvider(provider.id)?.kind == .anthropic)

        let url = try find(SettingsTextField.self, "settings.ai.provider.base-url", in: controller.view)
        url.commit?("http://api.example.com")
        // A plain-HTTP remote host is refused and the stored URL stays empty.
        #expect(fixture.settings.aiProvider(provider.id)?.baseURL == "")
        url.commit?(" https://api.example.com/v1/messages ")
        #expect(fixture.settings.aiProvider(provider.id)?.baseURL == "https://api.example.com/v1")
        #expect(url.stringValue == "https://api.example.com/v1")

        let key = try find(SettingsSecureField.self, "settings.ai.provider.api-key", in: controller.view)
        let clear = try find(NSButton.self, "settings.ai.provider.clear-api-key", in: controller.view)
        #expect(!clear.isEnabled)
        key.stringValue = "  secret-test-key  "
        key.commit?(key.stringValue)
        #expect(fixture.credentials.apiKey(for: provider.id) == "secret-test-key")
        #expect(key.stringValue.isEmpty)
        #expect(clear.isEnabled)
        // Leaving the empty field does not delete the stored key.
        key.commit?("")
        #expect(fixture.credentials.hasAPIKey(for: provider.id))

        let saved = try String(contentsOf: fixture.directory.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!saved.contains("secret-test-key"))
        for view in descendants(controller.view) {
            #expect((view as? NSTextField)?.stringValue.contains("secret-test-key") != true)
            #expect((view as? NSTextField)?.placeholderString?.contains("secret-test-key") != true)
            #expect((view.accessibilityLabel() ?? "").contains("secret-test-key") == false)
        }

        let enabled = try find(SettingsSwitch.self, "settings.ai.provider.enabled", in: controller.view)
        enabled.state = .off
        enabled.change?(false)
        #expect(fixture.settings.aiProvider(provider.id)?.enabled == false)

        clear.performClick(nil)
        #expect(!fixture.credentials.hasAPIKey(for: provider.id))
        #expect(!clear.isEnabled)

        // Back leads to the AI page, where the connection is listed under its new name.
        try find(NSButton.self, "settings.back", in: controller.view).performClick(nil)
        #expect(controller.isShowing("agents"))
        _ = try find(NSButton.self, "settings.ai.provider." + provider.id.uuidString, in: controller.view)
    }

    @Test func fetchingModelsMergesTheListAndLimitsAreEditedPerModel() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) {
            $0.baseURL = "https://api.example.com"
            $0.models = [AIProviderModel(id: "alpha", contextWindow: 8_000)]
        }
        try fixture.credentials.setAPIKey("secret-test-key", for: provider.id)
        controller.showAIProvider(provider.id)

        try find(NSButton.self, "settings.ai.provider.fetch-models", in: controller.view).performClick(nil)
        #expect(await settle { fixture.settings.aiProvider(provider.id)?.models.count == 2 })
        // The existing model keeps its limit; the new one is appended.
        #expect(fixture.settings.aiProvider(provider.id)?.models == [
            AIProviderModel(id: "alpha", contextWindow: 8_000), AIProviderModel(id: "beta"),
        ])
        let request = try #require(fixture.requests.all.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-test-key")

        let add = try find(SettingsTextField.self, "settings.ai.provider.add-model-id", in: controller.view)
        add.stringValue = " manual-model "
        try find(NSButton.self, "settings.ai.provider.add-model", in: controller.view).performClick(nil)
        #expect(fixture.settings.aiProvider(provider.id)?.models.map(\.id) == ["alpha", "beta", "manual-model"])
        #expect(add.stringValue.isEmpty)

        let table = try find(NSTableView.self, "settings.ai.models", in: controller.view)
        #expect(await settle { table.numberOfRows == 3 })
        let cell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? AIModelListCell)
        cell.contextField.stringValue = "128k"
        cell.outputField.stringValue = "4,096"
        cell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                   object: cell.outputField))
        #expect(fixture.settings.aiProvider(provider.id)?.model("beta")
            == AIProviderModel(id: "beta", contextWindow: 128_000, maxOutputTokens: 4_096))
        #expect(cell.contextField.stringValue == "128000")
        cell.contextField.stringValue = ""
        cell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                   object: cell.contextField))
        #expect(fixture.settings.aiProvider(provider.id)?.model("beta")?.contextWindow == nil)

        // Removing a model also removes the choices that pointed at it.
        fixture.settings.aiTitleRoute = AITitleRoute(provider: provider.id, model: "beta")
        fixture.settings.gitCommitAIRoutes = [GitCommitAIRoute(provider: provider.id, model: "beta"),
                                              GitCommitAIRoute(provider: provider.id, model: "alpha")]
        cell.removeButton.performClick(nil)
        #expect(fixture.settings.aiProvider(provider.id)?.models.map(\.id) == ["alpha", "manual-model"])
        #expect(fixture.settings.aiTitleRoute == nil)
        #expect(fixture.settings.gitCommitAIRoutes.map(\.model) == ["alpha"])
        #expect(await settle { table.numberOfRows == 2 })
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
        controller.showAIProvider(provider.id)
        let fetch = try find(NSButton.self, "settings.ai.provider.fetch-models", in: controller.view)
        fetch.performClick(nil)
        #expect(await settle { fixture.requests.all.count == 1 && fetch.isEnabled })

        #expect(fixture.settings.aiProvider(provider.id)?.models.map(\.id) == ["alpha"])
        let labels = descendants(controller.view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains { $0.hasPrefix("HTTP 500") })
        #expect(!labels.contains { $0.contains("secret-test-key") })

        // Without a usable base URL nothing is sent at all.
        fixture.settings.updateAIProvider(provider.id) { $0.baseURL = "" }
        fetch.performClick(nil)
        #expect(fixture.requests.all.count == 1)
    }

    @Test func removingAConnectionDeletesItsKeyAndLeavesThePage() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        try fixture.credentials.setAPIKey("secret-test-key", for: provider.id)
        fixture.controller.showAIProvider(provider.id)
        #expect(fixture.controller.isShowing("ai-provider:" + provider.id.uuidString))
        _ = try find(NSButton.self, "settings.ai.provider.remove", in: fixture.controller.view)

        // The page follows the settings: once the connection is gone it returns to the AI page.
        try fixture.settings.removeAIProvider(provider.id, credentials: fixture.credentials)
        #expect(await settle { fixture.controller.isShowing("agents") })
        #expect(!fixture.credentials.hasAPIKey(for: provider.id))
        #expect(!descendants(fixture.controller.view).contains {
            $0.accessibilityIdentifier() == "settings.ai.provider." + provider.id.uuidString
        })
        // A connection that no longer exists cannot be opened.
        fixture.controller.showAIProvider(provider.id)
        #expect(fixture.controller.isShowing("agents"))
    }

    @Test func anInstalledAgentPageDiscoversItsModelsOnFirstVisit() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.select(.agents)
        try find(NSButton.self, "settings.ai.local-cli-models", in: controller.view).performClick(nil)
        #expect(controller.isShowing("ai-local-cli-models"))
        for agent in GitCommitAgent.allCases {
            _ = try find(NSButton.self, "settings.ai.agent." + agent.rawValue, in: controller.view)
        }
        try find(NSButton.self, "settings.ai.agent.opencode", in: controller.view).performClick(nil)
        #expect(controller.isShowing("ai-agent:opencode"))

        let table = try find(NSTableView.self, "settings.ai.models", in: controller.view)
        #expect(await settle { table.numberOfRows == 2 })
        #expect(controller.aiAgentCatalog.entry(.opencode).models == ["opencode-one", "opencode-two"])
        // A discovered list is read-only: no limit fields, no remove buttons.
        #expect(!descendants(controller.view).contains {
            $0.accessibilityIdentifier() == "settings.ai.model.context-window"
        })
        let refresh = try find(NSButton.self, "settings.ai.agent.refresh-models", in: controller.view)
        #expect(refresh.isEnabled)
        // Only Codex has an adapter OMG can manage.
        #expect(!descendants(controller.view).contains {
            $0.accessibilityIdentifier() == "settings.ai.agent.codex.adapter-update"
        })

        try find(NSButton.self, "settings.back", in: controller.view).performClick(nil)
        #expect(controller.isShowing("ai-local-cli-models"))
        let subpageLabels = descendants(controller.view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(subpageLabels.contains { $0.contains(SettingsStrings(language: .english).aiModelCount(2)) })

        try find(NSButton.self, "settings.back", in: controller.view).performClick(nil)
        #expect(controller.isShowing("agents"))
        let labels = descendants(controller.view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains { $0.contains(SettingsStrings(language: .english).aiModelCount(2)) })
    }

    @Test func thePickerOffersOnlyUsableConnectionsAndReportsTheChoice() throws {
        let strings = SettingsStrings(language: .english)
        let first = AIProvider(name: "Same name", baseURL: "https://one.example.com",
                               models: [AIProviderModel(id: "a"), AIProviderModel(id: "b"), AIProviderModel(id: "c")])
        let second = AIProvider(name: "Same name", baseURL: "https://two.example.com",
                                models: [AIProviderModel(id: "x")])
        let off = AIProvider(name: "Off", baseURL: "https://off.example.com", enabled: false,
                             models: [AIProviderModel(id: "y")])
        let empty = AIProvider(name: "Empty", baseURL: "https://empty.example.com")
        let eligible = AIProviderModelPickerController.eligible([first, off, empty, second])
        #expect(eligible == [first, second])

        var chosen: (UUID, [String])?
        let multi = AIProviderModelPickerController(providers: eligible, allowsMultiple: true, strings: strings,
                                                    heading: "Add API Models") { chosen = ($0, $1) }
        _ = multi.view
        // Two connections may share a name; both stay in the menu.
        #expect(multi.providerPopup.numberOfItems == 2)
        #expect(multi.modelTable.numberOfRows == 3)
        #expect(multi.addProviderButton.isHidden)
        #expect(!multi.confirmButton.isEnabled)
        multi.toggle("c")
        multi.toggle("a")
        #expect(multi.confirmButton.isEnabled)
        multi.confirm()
        #expect(chosen?.0 == first.id)
        // Reported in the connection's order, not in click order.
        #expect(chosen?.1 == ["a", "c"])

        let single = AIProviderModelPickerController(providers: eligible, allowsMultiple: false, strings: strings,
                                                     heading: "Choose Title Model") { chosen = ($0, $1) }
        _ = single.view
        single.toggle("a")
        single.toggle("b")
        #expect(single.selected == ["b"])
        // Switching the connection starts the choice over.
        single.select(providerAt: 1)
        #expect(single.selected.isEmpty)
        #expect(single.modelTable.numberOfRows == 1)
        single.toggle("x")
        single.confirm()
        #expect(chosen?.0 == second.id)
        #expect(chosen?.1 == ["x"])

        let none = AIProviderModelPickerController(providers: [], allowsMultiple: true, strings: strings,
                                                   heading: "Add API Models") { _, _ in }
        _ = none.view
        #expect(none.modelTable.numberOfRows == 0)
        #expect(none.addProviderButton.isHidden)
        #expect(!none.confirmButton.isEnabled)
        #expect(!none.searchField.isEnabled)

        // Empty-state picker with an add-service callback offers a direct jump into connection setup.
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.controller.select(.agents)
        let emptyWithAdd = AIProviderModelPickerController(
            providers: [],
            allowsMultiple: false,
            strings: strings,
            heading: "Choose Title Model",
            onAddProvider: { [weak controller = fixture.controller] in controller?.addConnection() },
            done: { _, _ in }
        )
        _ = emptyWithAdd.view
        #expect(!emptyWithAdd.addProviderButton.isHidden)
        emptyWithAdd.addProvider()
        let created = try #require(fixture.settings.aiProviders.first)
        #expect(fixture.controller.isShowing("ai-provider:" + created.id.uuidString))
    }

    @Test func theTitleModelRowExplainsWhatWillHappen() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let strings = SettingsStrings(language: .english)
        let controller = fixture.controller
        #expect(controller.aiTitleModelSummary() == strings.aiTitleModelUnset)

        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) { $0.mergeModels(["alpha"]) }
        fixture.settings.aiTitleRoute = AITitleRoute(provider: provider.id, model: "alpha")
        #expect(controller.aiTitleModelSummary() == "Work proxy · alpha")

        fixture.settings.updateAIProvider(provider.id) { $0.enabled = false }
        #expect(controller.aiTitleModelSummary().hasPrefix("Work proxy · alpha: "))

        // A route can outlive its connection in a hand-edited file; the row says so.
        fixture.settings.aiProviders = []
        #expect(controller.aiTitleModelSummary().hasPrefix("alpha: "))

        controller.select(.agents)
        let alwaysUseAI = try find(SettingsSwitch.self, "settings.ai.title.always-use-ai", in: controller.view)
        #expect(alwaysUseAI.isEnabled)
        alwaysUseAI.state = .on
        alwaysUseAI.change?(true)
        #expect(fixture.settings.agentSessionTitleAlwaysUseAI)
        fixture.settings.agentSessionTitleMode = .native
        controller.select(.agents)
        let disabledAlwaysUseAI = try find(SettingsSwitch.self, "settings.ai.title.always-use-ai", in: controller.view)
        #expect(!disabledAlwaysUseAI.isEnabled)
        #expect(disabledAlwaysUseAI.state == .on)

        let clear = try find(NSButton.self, "settings.ai.title.clear-model", in: controller.view)
        #expect(clear.isEnabled)
        clear.performClick(nil)
        #expect(fixture.settings.aiTitleRoute == nil)
    }

    @Test func commitRoutesShowTheConnectionNameAndItsState() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let provider = try #require(fixture.settings.addAIProvider(name: "Work proxy"))
        fixture.settings.updateAIProvider(provider.id) { $0.mergeModels(["alpha"]); $0.enabled = false }
        fixture.settings.gitCommitAIRoutes = [GitCommitAIRoute(agent: .claude, model: "sonnet"),
                                              GitCommitAIRoute(provider: provider.id, model: "alpha")]
        fixture.controller.select(.agents)
        let table = try find(NSTableView.self, "git.commit-ai.routes", in: fixture.controller.view)
        #expect(table.numberOfRows == 2)
        let agentCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(agentCell.accessibilityLabel() == "Claude Code · sonnet")
        let apiCell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(apiCell.accessibilityLabel() == "Work proxy · alpha")
        let apiLabels = descendants(apiCell).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(apiLabels.contains("Work proxy (off)"))
        #expect(apiLabels.contains("alpha"))
    }
}
