import SwiftUI

struct GitCommitAISettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @State private var showingAdd = false
    @State private var showingPrompt = false

    var body: some View {
        Section(GitL10n.text("AI Commit Messages")) {
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
            Button(GitL10n.text("Add Agent Models…")) { showingAdd = true }
            Button { showingPrompt = true } label: {
                Label(GitL10n.text("Edit commit prompt…"), systemImage: "square.and.pencil")
            }
        }
        .sheet(isPresented: $showingPrompt) {
            GitCommitPromptEditor(prompt: settings.gitCommitAIPrompt) { settings.gitCommitAIPrompt = $0 }
        }
        .sheet(isPresented: $showingAdd) {
            GitCommitAIAddModels { agent, models in
                settings.gitCommitAIRoutes = GitCommitAIRoute.adding(agent: agent, models: models, to: settings.gitCommitAIRoutes)
            }
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
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
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
    @State private var manualModels = ""
    @State private var models: [String] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var loadingID: UUID?
    @State private var error: String?
    @State private var reloadID = UUID()

    private var chosenModels: [String] {
        models.filter { selected.contains($0) } + manualModels.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
                List(models, id: \.self) { model in
                    Toggle(model, isOn: Binding(get: { selected.contains(model) }, set: {
                        if $0 { selected.insert(model) } else { selected.remove(model) }
                    }))
                }.frame(height: 180)
            }
            Text(GitL10n.text("Model IDs (one per line)"))
            TextEditor(text: $manualModels).font(.system(.body, design: .monospaced))
                .frame(height: 90).border(Color.secondary.opacity(0.3))
            Text(GitL10n.text("ACP adapters: pi-acp, claude-agent-acp, codex-acp; OpenCode uses opencode acp. Install and log in locally before loading models."))
                .font(.caption).foregroundStyle(.secondary)
            Text(GitL10n.text("Select models advertised by the ACP session. Previously saved CLI IDs may need to be added again."))
                .font(.caption).foregroundStyle(.secondary)
            Text(GitL10n.text("Uses your local CLI login. Staged changes and recent commit subjects may be sent to every configured model service on fallback, including changes read over SSH. Nothing is committed automatically."))
                .font(.caption).foregroundStyle(.secondary)
            Text(GitL10n.text("All agents connect over local ACP. Remote hosts do not need an agent. Sessions are stored outside repositories and expire after 30 days."))
                .font(.caption).foregroundStyle(.secondary)
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
            selected = []; models = []; manualModels = ""; error = nil; reloadID = UUID()
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
                if result.isEmpty { error = GitL10n.text("No models found. Enter model IDs manually or check CLI login.") }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
