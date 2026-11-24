import Foundation

/// Edits to the API connections that must keep the model choices and the stored
/// keys consistent with the connection list.
@MainActor
extension OhMyGhosttySettings {
    /// The API connections as they are now, for work that leaves the main actor.
    func aiProviderDirectory(credentials: AICredentialStore = .shared) -> AIProviderDirectory {
        AIProviderDirectory(providers: aiProviders, credentials: credentials)
    }

    func aiProvider(_ id: UUID) -> AIProvider? {
        aiProviders.first { $0.id == id }
    }

    /// Applies `change` to one connection and saves the list when it differs.
    func updateAIProvider(_ id: UUID, _ change: (inout AIProvider) -> Void) {
        guard let index = aiProviders.firstIndex(where: { $0.id == id }) else { return }
        var provider = aiProviders[index]
        change(&provider)
        provider.id = id
        guard provider != aiProviders[index] else { return }
        aiProviders[index] = provider
    }

    /// Adds an empty connection, or returns nil when the list is full.
    func addAIProvider(name: String) -> AIProvider? {
        guard aiProviders.count < AIProvider.maxProviders else { return nil }
        let provider = AIProvider(name: name)
        aiProviders.append(provider)
        return provider
    }

    /// Removes a connection together with every model choice that used it and its
    /// stored key. Throws when the key file could not be updated; the connection is
    /// gone either way.
    func removeAIProvider(_ id: UUID, credentials: AICredentialStore = .shared) throws {
        dropAIRoutes { $0 == id }
        aiProviders.removeAll { $0.id == id }
        try credentials.removeAPIKey(for: id)
    }

    /// Removes one model of a connection and the model choices that pointed at it.
    func removeAIProviderModel(_ model: String, from id: UUID) {
        if aiTitleRoute?.provider == id, aiTitleRoute?.model == model { aiTitleRoute = nil }
        if gitCommitAIRoutes.contains(where: { $0.provider == id && $0.model == model }) {
            gitCommitAIRoutes.removeAll { $0.provider == id && $0.model == model }
        }
        updateAIProvider(id) { provider in provider.models.removeAll { $0.id == model } }
    }

    private func dropAIRoutes(where matches: (UUID) -> Bool) {
        if let route = aiTitleRoute, matches(route.provider) { aiTitleRoute = nil }
        if gitCommitAIRoutes.contains(where: { $0.provider.map(matches) ?? false }) {
            gitCommitAIRoutes.removeAll { $0.provider.map(matches) ?? false }
        }
    }
}
