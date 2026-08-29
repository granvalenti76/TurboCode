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

/// Projects a successful write into the native conversation timeline. This
/// adapter deliberately exposes no ordinary send API, so publication cannot
/// accidentally create an LLM turn.
@MainActor
final class EditorialPublicationReceiptAdapter: EditorialPublicationReceiptPresenting {
    private let messageSender: MessageSendCoordinator

    init(messageSender: MessageSendCoordinator) {
        self.messageSender = messageSender
    }

    func present(_ publication: EditorialPublicationBlock) async {
        await messageSender.presentEditorialPublication(publication)
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
    private let draftLibrary: EditorialDraftLibraryService
    private let receiptPresenter: EditorialPublicationReceiptAdapter

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
        self.draftLibrary = EditorialDraftLibraryService()
        self.receiptPresenter = EditorialPublicationReceiptAdapter(
            messageSender: messageSender
        )
    }

    func dependencies(for workspaceRoot: String) -> EditorialDeskDependencies {
        EditorialDeskDependencies(
            modelClient: modelClientFactory.makeClient(workspaceRoot: workspaceRoot),
            sourceService: sourceService,
            publicationService: publicationService,
            draftLibrary: draftLibrary,
            receiptPresenter: receiptPresenter
        )
    }
}
