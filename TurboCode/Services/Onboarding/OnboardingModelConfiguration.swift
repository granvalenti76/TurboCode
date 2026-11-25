import Foundation

/// Turns the server chosen in the first-launch sheet into the `llama` entry of
/// `models.json`. Pure logic, so the mapping is testable without a server.
nonisolated enum OnboardingModelConfiguration {
    /// Context choices offered for servers that cannot report their own.
    static let contextWindowChoices: [Int] = [8_192, 16_384, 32_768, 65_536, 131_072]
    static let defaultContextWindow = 32_768

    /// The local entry keeps the id `llama` because composer profiles, Tools
    /// columns and persisted sessions refer to the local backend by that id.
    static let localModelID = "llama"

    /// A readable default name from a model identifier: llama-server often
    /// reports a file path, so keep the last component and drop `.gguf`.
    static func displayName(forModelID modelID: String) -> String {
        var name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Local model" : trimmed
    }

    /// What each server kind means for the persisted vision override.
    /// llama-server stays unset so the runtime keeps asking `/props` and
    /// follows a model reload; mlx_vlm has no `/props`, so its answer is
    /// written down; other servers cannot be asked and default to no images.
    static func supportsVision(for kind: LocalModelServerKind) -> Bool? {
        switch kind {
        case .llamaServer: nil
        case .mlxVLM: true
        case .openAICompatible: false
        }
    }

    /// Points the local entry at a server chosen in Settings.
    ///
    /// Only the connection fields change: address, model, context window and
    /// vision. The display name, temperature, reasoning contract and every
    /// other model are kept, because they may have been tuned by hand. The
    /// display name follows the model only when the model itself changes, so
    /// the sidebar never shows the name of a model that is no longer loaded.
    /// Without a local entry one is appended with the onboarding defaults.
    static func applyingLocalServer(
        baseURL: String,
        kind: LocalModelServerKind,
        modelID: String,
        contextWindow: Int,
        to models: [RemoteModelConfig]
    ) -> [RemoteModelConfig] {
        var models = models
        guard let index = models.firstIndex(where: { $0.id == localModelID }) else {
            models.append(RemoteModelConfig(
                id: localModelID,
                name: displayName(forModelID: modelID),
                url: baseURL,
                modelName: modelID,
                temperature: 0.6,
                supportsVision: supportsVision(for: kind),
                contextWindowTokens: contextWindow
            ))
            return models
        }
        var entry = models[index]
        if entry.modelName != modelID {
            entry.name = displayName(forModelID: modelID)
        }
        entry.url = baseURL
        entry.modelName = modelID
        entry.contextWindowTokens = contextWindow
        entry.supportsVision = supportsVision(for: kind)
        // Named effort levels come from llama-server's `/props`. Any other
        // server cannot declare them, and levels stored for an earlier
        // llama-server would be sent to a template that ignores them, so
        // reasoning returns to the server's own default. Token budgets are
        // left alone: they are a deliberate choice, not a detected value.
        if kind != .llamaServer, entry.reasoningConfiguration.mode == .requestEffortLevel {
            entry.reasoningConfiguration.mode = .serverManaged
            entry.reasoningConfiguration.serverEffortLevels = nil
        }
        entry.enabled = true
        models[index] = entry
        return models
    }

    /// Builds the persisted entry.
    ///
    /// - For llama-server the context comes from `/props` and vision stays
    ///   unset, so the runtime keeps asking the server and follows a model
    ///   reload without another onboarding.
    /// - For mlx_vlm the user's context choice is stored (its reported limit
    ///   is the model maximum, not what fits in memory) and vision is written
    ///   as `true`, because the runtime probe only understands `/props`.
    /// - For other servers the user's context choice is stored and vision is
    ///   written as `false`, as CONFIGURATION.md advises for servers without
    ///   `/props`, so image drops do not wait on a probe that cannot answer.
    static func localModel(
        server: DiscoveredModelServer,
        modelID: String,
        displayName: String,
        chosenContextWindow: Int?
    ) -> RemoteModelConfig {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let context: Int
        switch server.kind {
        case .llamaServer:
            context = server.contextWindowTokens ?? chosenContextWindow ?? defaultContextWindow
        case .mlxVLM, .openAICompatible:
            context = chosenContextWindow ?? defaultContextWindow
        }
        return RemoteModelConfig(
            id: localModelID,
            name: name.isEmpty ? Self.displayName(forModelID: modelID) : name,
            url: server.baseURL,
            modelName: modelID,
            temperature: 0.6,
            supportsVision: supportsVision(for: server.kind),
            contextWindowTokens: context
        )
    }
}
