import AppKit
import Foundation
import Observation

/// Observable Codex configuration and connection-state facade.
///
/// The facade opens authentication UI and persists user preferences. Concrete
/// client, thread, approval, handoff, and turn state belong exclusively to
/// `CodexExecutionEngine`, so SwiftUI lifetime cannot own provider execution.
@MainActor
@Observable
final class CodexRuntimeStore {
    var connectionState: CodexConnectionState = .idle
    var model: CodexModelDescriptor?
    var models: [CodexModelDescriptor] = []
    var loginURL: URL?
    var reasoningEffort: CodexReasoningEffort

    var reasoningOptions: [CodexReasoningOption] {
        model?.supportedReasoningEfforts
            ?? CodexReasoningEffort.allCases.map {
                CodexReasoningOption(reasoningEffort: $0, description: "")
            }
    }

    /// The direct-Codex preference remains stable while a coordinator route
    /// temporarily exposes its own selected model through `model`.
    var preferredModel: CodexModelDescriptor? {
        models.first { $0.id == preferredModelID }
    }

    /// Immutable preference snapshot captured when a backend adapter is built.
    /// Execution code never reaches back into this observable facade mid-turn.
    var preferredExecutionModelID: String { preferredModelID }

    /// Editing the built-in profile changes its next-turn preference without
    /// activating Codex or overwriting the model of an active custom profile.
    func configureDefaultModel(id: String, updateActiveModel: Bool) {
        guard let selected = models.first(where: { $0.id == id }) else { return }
        preferredModelID = selected.id
        preferences.set(selected.id, forKey: "codexModelID")
        preferences.set(selected.displayName, forKey: "codexModelDisplayName")
        if !selected.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == reasoningEffort }) {
            reasoningEffort = selected.defaultReasoningEffort
            preferences.set(reasoningEffort.rawValue, forKey: "codexReasoningEffort")
        }
        if updateActiveModel { model = selected }
    }

    var displayName: String {
        model?.displayName
            ?? preferences.string(forKey: "codexModelDisplayName")
            ?? "Luna"
    }

    var canSend: Bool {
        if case .ready = connectionState { return true }
        return false
    }

    let executionEngine: CodexExecutionEngine
    private var preferredModelID: String
    private let preferences: UserDefaults

    init(
        executionEngine: CodexExecutionEngine = CodexExecutionEngine(),
        preferences: UserDefaults = .standard
    ) {
        self.executionEngine = executionEngine
        self.preferences = preferences
        reasoningEffort = preferences.string(forKey: "codexReasoningEffort")
            .flatMap(CodexReasoningEffort.init(rawValue:)) ?? .medium
        preferredModelID = preferences.string(forKey: "codexModelID")
            ?? CodexAppServerClient.lunaModelID
    }

    func select(modelID: String? = nil) async throws {
        if let modelID {
            preferredModelID = modelID
            preferences.set(modelID, forKey: "codexModelID")
        }
        connectionState = .connecting
        let snapshot = try await executionEngine.prepareCodex(
            selectedModelID: preferredModelID
        )
        applyExecutionSnapshot(snapshot, persistsPreference: true)
    }

    func markSignedOut() {
        connectionState = .signedOut
    }

    func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    func signIn() async throws {
        connectionState = .authenticating
        let login = try await executionEngine.startChatGPTLogin()
        loginURL = login.authorizationURL
        guard NSWorkspace.shared.open(login.authorizationURL) else {
            throw CodexAppServerError.loginFailed(
                "The authorization page could not be opened."
            )
        }
        try await executionEngine.waitForChatGPTLogin(id: login.id)
        connectionState = .connecting
        let snapshot = try await executionEngine.prepareCodex(
            selectedModelID: preferredModelID
        )
        applyExecutionSnapshot(snapshot, persistsPreference: true)
        loginURL = nil
    }

    @discardableResult
    func reopenLoginPage() -> Bool {
        guard let loginURL else { return false }
        return NSWorkspace.shared.open(loginURL)
    }

    func setReasoningEffort(_ effort: CodexReasoningEffort) {
        guard reasoningOptions.contains(where: {
            $0.reasoningEffort == effort
        }) else { return }
        reasoningEffort = effort
        preferences.set(
            effort.rawValue,
            forKey: "codexReasoningEffort"
        )
    }

    /// Captures only turns not already known by the process-local Codex thread.
    func captureImportedContext(
        turboThreadID: String,
        blocks: [ChatBlock]
    ) async {
        await executionEngine.captureImportedContext(
            turboThreadID: turboThreadID,
            blocks: blocks
        )
    }

    /// Restored Codex identifiers are process-local, so the visible persisted
    /// timeline initializes the next fresh App Server thread.
    func restoreImportedContext(
        turboThreadID: String,
        blocks: [ChatBlock]
    ) async {
        await executionEngine.restoreImportedContext(
            turboThreadID: turboThreadID,
            blocks: blocks
        )
    }

    func prepareHandoff(
        turboThreadID: String,
        blocks: [ChatBlock],
        workspaceRoot: String
    ) async -> CodexHandoff {
        await executionEngine.prepareHandoff(
            turboThreadID: turboThreadID,
            blocks: blocks,
            workspaceRoot: workspaceRoot,
            modelID: model?.model ?? preferredModelID
        )
    }

    func completeHandoff(
        turboThreadID: String,
        boundaryBlockID: String?
    ) async {
        await executionEngine.completeHandoff(
            turboThreadID: turboThreadID,
            boundaryBlockID: boundaryBlockID
        )
    }

    /// App Server tool declarations are immutable for a thread. Changing from
    /// direct Codex to a coordinator route (or back) must therefore start a new
    /// server thread while the caller preserves the visible conversation.
    func resetThread(turboThreadID: String) async {
        await executionEngine.resetThread(turboThreadID: turboThreadID)
    }

    func resolveApproval(id: String, approved: Bool) async throws -> Bool {
        try await executionEngine.resolveApproval(id: id, approved: approved)
    }

    func interrupt() async {
        await executionEngine.interrupt()
    }

    func applyExecutionSnapshot(
        _ snapshot: CodexRuntimeSnapshot,
        persistsPreference: Bool
    ) {
        models = snapshot.models
        model = snapshot.selectedModel
        if persistsPreference {
            preferredModelID = snapshot.selectedModel.id
            preferences.set(
                snapshot.selectedModel.id,
                forKey: "codexModelID"
            )
            preferences.set(
                snapshot.selectedModel.displayName,
                forKey: "codexModelDisplayName"
            )
        }
        if persistsPreference,
           !snapshot.selectedModel.supportedReasoningEfforts.contains(where: {
               $0.reasoningEffort == reasoningEffort
           }) {
            reasoningEffort = snapshot.selectedModel.defaultReasoningEffort
            preferences.set(
                reasoningEffort.rawValue,
                forKey: "codexReasoningEffort"
            )
        }
        connectionState = .ready(planType: snapshot.planType)
    }

}
