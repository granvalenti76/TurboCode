import Foundation

/// Builds the isolated model client from a snapshot of application routing.
/// The factory is an assembly concern, not part of ChatStore's public facade.
@MainActor
final class EditorialDeskModelClientFactory {
    private let runtime: LLMRuntime
    private let modelRuntime: ModelRuntimeStore
    private let codexRuntime: CodexRuntimeStore

    init(
        runtime: LLMRuntime,
        modelRuntime: ModelRuntimeStore,
        codexRuntime: CodexRuntimeStore
    ) {
        self.runtime = runtime
        self.modelRuntime = modelRuntime
        self.codexRuntime = codexRuntime
    }

    func makeClient(workspaceRoot: String) -> any EditorialModelClient {
        let configuration = modelRuntime.makeSessionConfiguration(
            workspaceRoot: workspaceRoot
        )
        return TurboCodeEditorialModelClient(
            runtime: runtime,
            configuration: configuration,
            modelName: modelRuntime.composerModel,
            codexConfiguration: configuration.backend == .codex
                ? EditorialCodexConfiguration(
                    turboThreadID: "editorial-desk-\(UUID().uuidString)",
                    modelID: codexRuntime.preferredExecutionModelID,
                    reasoningEffort: codexRuntime.reasoningEffort,
                    agentTuning: configuration.agentTuning,
                    availableSkills: configuration.availableSkills
                )
                : nil
        )
    }
}

/// Encodes canonical editorial context on its own actor. Sendable request
/// values cross into this boundary; no ViewModel or observable store does.
actor EditorialCanonicalPromptEncoder {
    func makePrompt(
        for request: EditorialCanonicalPublishRequest
    ) -> String {
        EditorialPromptBuilder.makeCanonicalPublishPrompt(
            draft: request.draft,
            fileName: request.fileName,
            sources: request.sources,
            metadata: request.metadata
        )
    }
}

/// Temporary bridge from the new feature port to the existing message sender.
/// Keeping the bridge narrow lets the eventual chat extraction change its
/// implementation without reintroducing ChatStore into the desk.
@MainActor
final class EditorialCanonicalHandoffAdapter: EditorialCanonicalHandoff {
    private let messageSender: MessageSendCoordinator
    private let promptEncoder: EditorialCanonicalPromptEncoder

    init(
        messageSender: MessageSendCoordinator,
        promptEncoder: EditorialCanonicalPromptEncoder = EditorialCanonicalPromptEncoder()
    ) {
        self.messageSender = messageSender
        self.promptEncoder = promptEncoder
    }

    func publish(
        _ request: EditorialCanonicalPublishRequest
    ) async -> EditorialCanonicalHandoffOutcome {
        let prompt = await promptEncoder.makePrompt(for: request)
        guard let promptText = await messageSender.preparePrompt(for: prompt) else {
            return .unavailable("The canonical session is not ready for this draft.")
        }

        let accepted = await messageSender.send(
            displayText: "Published editorial draft: \(request.fileName)",
            promptText: promptText,
            visibleInTimeline: true
        )
        return accepted
            ? .accepted
            : .unavailable("The canonical session is currently busy.")
    }
}

/// Application assembly for the Editorial Desk. ChatStore may own this
/// temporary bridge while the broader composition root is extracted, but the
/// sheet receives only EditorialDeskDependencies.
@MainActor
final class EditorialDeskAssembly {
    private let modelClientFactory: EditorialDeskModelClientFactory
    private let sourceService: EditorialSourceService
    private let publicationService: EditorialPublicationService
    private let canonicalHandoff: EditorialCanonicalHandoffAdapter

    init(
        runtime: LLMRuntime,
        modelRuntime: ModelRuntimeStore,
        codexRuntime: CodexRuntimeStore,
        messageSender: MessageSendCoordinator
    ) {
        self.modelClientFactory = EditorialDeskModelClientFactory(
            runtime: runtime,
            modelRuntime: modelRuntime,
            codexRuntime: codexRuntime
        )
        self.sourceService = EditorialSourceService()
        self.publicationService = EditorialPublicationService()
        self.canonicalHandoff = EditorialCanonicalHandoffAdapter(
            messageSender: messageSender
        )
    }

    func dependencies(for workspaceRoot: String) -> EditorialDeskDependencies {
        EditorialDeskDependencies(
            modelClient: modelClientFactory.makeClient(workspaceRoot: workspaceRoot),
            sourceService: sourceService,
            publicationService: publicationService,
            canonicalHandoff: canonicalHandoff
        )
    }
}
