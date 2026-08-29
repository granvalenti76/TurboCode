import Foundation
import FoundationModels

/// Errors at the feature/provider boundary stay user-readable while provider
/// details remain behind the existing backend session contract.
nonisolated enum EditorialModelError: LocalizedError, Sendable {
    case unsupportedBackend(ModelBackend)
    case failed(String)
    case cancelled
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBackend(let backend):
            "Editorial Desk is not available for the \(backend.rawValue) backend yet."
        case .failed(let message):
            message
        case .cancelled:
            "The editorial operation was cancelled."
        case .invalidResponse(let message):
            message
        }
    }
}

/// Immutable Codex inputs for the editorial adapter. The engine remains the
/// only owner of App Server state; this value only selects its isolated route.
nonisolated struct EditorialCodexConfiguration: Sendable {
    let turboThreadID: String
    let modelID: String
    let reasoningEffort: CodexReasoningEffort
    let agentTuning: AgentTuningConfig
    let availableSkills: [TurboCodeSkillDefinition]
}

/// Executes one editorial operation through the application's existing LLM
/// gate, but with a fresh toolless session. This keeps the modal atomic: no
/// timeline block, conversation transcript, workspace tool, or file mutation
/// is involved in the operation.
actor TurboCodeEditorialModelClient: EditorialModelClient {
    private let runtime: LLMRuntime
    private let configuration: ModelSessionConfiguration
    private let modelName: String
    private let codexConfiguration: EditorialCodexConfiguration?
    private var activeTurnID: TurnID?
    private var nativeSession: LanguageModelSession?

    init(
        runtime: LLMRuntime,
        configuration: ModelSessionConfiguration,
        modelName: String,
        codexConfiguration: EditorialCodexConfiguration? = nil
    ) {
        self.runtime = runtime
        self.configuration = configuration
        self.modelName = modelName
        self.codexConfiguration = codexConfiguration
    }

    func perform(_ request: EditorialRequest) async throws -> EditorialResult {
        if configuration.backend == .codex {
            return try await performCodex(request)
        }

        let session: LanguageModelSession
        if let nativeSession {
            session = nativeSession
        } else {
            let created = ModelSessionFactory.makeEditorialSession(
                configuration: configuration
            )
            nativeSession = created
            session = created
        }
        let backendSession = NativeBackendSession(
            backend: configuration.backend,
            runner: NativeResponseRunner(),
            session: session,
            mode: configuration.orchestratorMode,
            workspaceKind: workspaceKind,
            serverURL: configuration.backend == .llamaServer
                ? configuration.activeRemoteModel?.url
                : nil
        )
        let turn = TurnRequest(
            prompt: EditorialPromptBuilder.makePrompt(for: request),
            backend: configuration.backend,
            modelName: modelName,
            workspaceRoot: configuration.workspaceRoot
        )
        activeTurnID = turn.id
        defer { activeTurnID = nil }
        let response = await runtime.execute(
            request: turn,
            using: backendSession,
            events: .none
        )

        return try decode(response)
    }

    private func performCodex(
        _ request: EditorialRequest
    ) async throws -> EditorialResult {
        guard let codexConfiguration else {
            throw EditorialModelError.unsupportedBackend(.codex)
        }
        let turn = TurnRequest(
            prompt: EditorialPromptBuilder.makePrompt(for: request),
            backend: .codex,
            modelName: modelName,
            workspaceRoot: configuration.workspaceRoot
        )
        activeTurnID = turn.id
        defer { activeTurnID = nil }
        let response = await runtime.executeCodex(
            request: turn,
            configuration: CodexLLMExecutionConfiguration(
                turboThreadID: codexConfiguration.turboThreadID,
                workspaceName: nil,
                agentTuning: codexConfiguration.agentTuning,
                availableSkills: codexConfiguration.availableSkills,
                pluginTools: [],
                modelID: codexConfiguration.modelID,
                reasoningEffort: codexConfiguration.reasoningEffort,
                delegationInvoker: nil,
                allowsTools: false,
                activityStarted: { _, _ in },
                activityEnded: { _ in },
                approvalRequested: { _ in }
            ),
            events: .none
        )
        return try decode(response)
    }

    private func decode(
        _ response: BackendSessionResult
    ) throws -> EditorialResult {
        switch response.outcome {
        case .succeeded:
            do {
                return try EditorialResult.decode(from: response.assistantText)
            } catch {
                throw EditorialModelError.invalidResponse(
                    "The editorial model returned an invalid structured response: \(error.localizedDescription)"
                )
            }
        case .cancelled:
            throw EditorialModelError.cancelled
        case .failed(let failure):
            throw EditorialModelError.failed(failure.message)
        }
    }

    func cancel() async {
        guard let activeTurnID else { return }
        await runtime.interrupt(turnID: activeTurnID)
    }

    private var workspaceKind: String {
        guard !configuration.workspaceRoot.isEmpty else { return "none" }
        let marker = URL(fileURLWithPath: configuration.workspaceRoot)
            .appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: marker.path) ? "git" : "nonGit"
    }
}
