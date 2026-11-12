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

    /// Builds the persisted entry.
    ///
    /// - For llama-server the context comes from `/props` and vision stays
    ///   unset, so the runtime keeps asking the server and follows a model
    ///   reload without another onboarding.
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
        case .openAICompatible:
            context = chosenContextWindow ?? defaultContextWindow
        }
        return RemoteModelConfig(
            id: localModelID,
            name: name.isEmpty ? Self.displayName(forModelID: modelID) : name,
            url: server.baseURL,
            modelName: modelID,
            temperature: 0.6,
            supportsVision: server.kind == .llamaServer ? nil : false,
            contextWindowTokens: context
        )
    }
}
