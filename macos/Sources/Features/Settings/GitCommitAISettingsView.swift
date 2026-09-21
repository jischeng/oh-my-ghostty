import SwiftUI

struct GitCommitAISettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @State private var showingAdd = false
    @State private var showingPrompt = false

    var body: some View {
        OMGSettingsSection(GitL10n.text("AI Commit Messages")) {
            Text(GitL10n.text("Try models from top to bottom. Drag rows to change priority. The first successful response is used."))
                .font(.caption).foregroundStyle(.secondary)
            if settings.gitCommitAIRoutes.isEmpty {
                Text(GitL10n.text("No models configured.")).foregroundStyle(.secondary)
            }
            ForEach(settings.gitCommitAIRoutes) { route in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    Text(route.title).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button { move(route.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(settings.gitCommitAIRoutes.first?.id == route.id)
                        .help(GitL10n.text("Move up"))
                    Button { move(route.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(settings.gitCommitAIRoutes.last?.id == route.id)
                        .help(GitL10n.text("Move down"))
                    Button { settings.gitCommitAIRoutes.removeAll { $0.id == route.id } } label: {
                        Image(systemName: "minus.circle")
                    }.help(GitL10n.text("Remove model"))
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .draggable(route.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first, let id = UUID(uuidString: value),
                          let source = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == id }),
                          let target = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == route.id }) else { return false }
                    settings.gitCommitAIRoutes.move(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
                    return true
                }
            }
            HStack {
                Button { showingAdd = true } label: {
                    Label(GitL10n.text("Add models…"), systemImage: "plus")
                }
                Spacer()
                Button { showingPrompt = true } label: {
                    Label(GitL10n.text("Commit style…"), systemImage: "slider.horizontal.3")
                }
            }.controlSize(.small).buttonStyle(.borderless)
        }
        .sheet(isPresented: $showingPrompt) {
            GitCommitPromptEditor(prompt: settings.gitCommitAIPrompt) { settings.gitCommitAIPrompt = $0 }
                .omgThemedSurface(palette: OMGThemeBackground.palette())
        }
        .sheet(isPresented: $showingAdd) {
            GitCommitAIAddModels { agent, models in
                settings.gitCommitAIRoutes = GitCommitAIRoute.adding(agent: agent, models: models, to: settings.gitCommitAIRoutes)
            }
            .omgThemedSurface(palette: OMGThemeBackground.palette())
        }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let index = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == id }),
              settings.gitCommitAIRoutes.indices.contains(index + delta) else { return }
        settings.gitCommitAIRoutes.swapAt(index, index + delta)
    }
}

private struct GitCommitPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var prompt: String
    let save: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(GitL10n.text("Custom commit prompt")).font(.headline)
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .frame(height: 250)
                .accessibilityLabel(GitL10n.text("Custom commit prompt"))
            Text(GitL10n.text("Specify language, format and commit style. Applied to all models, including fallbacks. Leave empty to follow recent commits."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(GitL10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(GitL10n.text("Save")) { save(prompt); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 540)
    }
}

private struct GitCommitAIAddModels: View {
    let add: (GitCommitAgent, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agent: GitCommitAgent = .claude
    @State private var query = ""
    @State private var showingHelp = false
    @State private var models: [String] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var loadingID: UUID?
    @State private var error: String?
    @State private var reloadID = UUID()

    private var chosenModels: [String] {
        models.filter { selected.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GitL10n.text("Add Agent Models…")).font(.headline)
            Picker("Agent", selection: $agent) {
                ForEach(GitCommitAgent.allCases) { Text($0.title).tag($0) }
            }
            if agent.canDiscoverModels {
                HStack {
                    Text(GitL10n.text("Available models"))
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button(GitL10n.text("Reload")) { reloadID = UUID() }.disabled(loading)
                }
                TextField(GitL10n.text("Search models…"), text: $query).textFieldStyle(.roundedBorder)
                List(models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { model in
                    Toggle(model, isOn: Binding(get: { selected.contains(model) }, set: {
                        if $0 { selected.insert(model) } else { selected.remove(model) }
                    }))
                }.frame(height: 260)
                    .scrollContentBackground(.hidden)
            }
            DisclosureGroup(GitL10n.text("About AI generation"), isExpanded: $showingHelp) {
                Text(GitL10n.text("Models run through local ACP, including for SSH repositories. Selected services receive the changes. Sessions expire after 30 days."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(GitL10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(GitL10n.text("Add")) { add(agent, chosenModels); dismiss() }
                    .disabled(GitCommitAIRoute.adding(agent: agent, models: chosenModels, to: []).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480)
        .onChange(of: agent) { _ in
            selected = []; models = []; query = ""; error = nil; reloadID = UUID()
        }
        .task(id: reloadID) {
            let requestedAgent = agent
            let requestID = reloadID
            loadingID = requestID
            error = nil
            loading = true
            defer { if loadingID == requestID { loading = false } }
            do {
                let result = try await GitCommitAIService.models(agent: requestedAgent)
                guard !Task.isCancelled, agent == requestedAgent else { return }
                models = result
                if result.isEmpty { error = GitL10n.text("No models found. Check the local ACP adapter and login.") }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
