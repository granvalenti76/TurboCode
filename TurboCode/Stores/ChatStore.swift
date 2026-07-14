import Foundation
import Observation
import SwiftUI
import FoundationModels
import FoundationModelsUtilities

// MARK: - Model Backend

/// The active inference backend.
public enum ModelBackend: String, CaseIterable, Sendable {
    case llamaServer = "Llama-server"
    case foundationApple = "Foundation Apple"
    case foundationServe = "Apple PCC"
    case premium = "Premium"
}

// MARK: - Central ChatStore

@MainActor
@Observable
public final class ChatStore {
    /// Shared instance used by App Intents (runs in-process on macOS).
    public static var shared: ChatStore!

    // MARK: - Properties
    // Threads
    public var threads: [Conversation] = []
    public var activeThreadId: String?
    public var threadSearch: String = ""
    public var showArchivedThreads: Bool = false

    // Timeline
    public var blocks: [ChatBlock] = []
    public var liveReasoning: String = ""
    public var liveAssistant: String = ""
    public var toolActivities: [ToolActivity] = []
    public var activeToolActivity: ToolActivity? { toolActivities.last }

    // First-message layout state — true on launch and new chat,
    // becomes false after the first message is sent
    public var isFirstMessage: Bool = true

    // Pending user approval for a destructive tool operation
    public var pendingApproval: ApprovalRequest? = nil
    private var queuedApprovals: [ApprovalRequest] = []

    // Composer
    public var composerModel: String = "auto"
    public var composerProviderId: String = ""
    public var composerMode: ConversationMode = .agent
    public var composerInput: String = ""
    public var composerAttachments: Int = 0

    // Runtime
    public var runtimeStatus: RuntimeStatus = .ready
    public var runtimeConnection: RuntimeConnectionState = .ready
    public var busy: Bool = false
    public var error: String?
#if DEBUG
    public var benchmarkRunning: Bool = false
    public var benchmarkStatus: String?
#endif

    // Navigation
    public var route: AppRoute = .chat
    public var settingsSection: SettingsSection = .general

    // Sidebar
    public var leftSidebarCollapsed: Bool = false
    public var leftSidebarWidth: CGFloat = 304

    // Right panel
    public var rightPanelMode: RightPanelMode?
    public var rightPanelVisible: Bool { rightPanelMode != nil }
    public var rightSidebarWidth: CGFloat = 360

    // Terminal
    public var terminalOpen: Bool = false
    public var terminalHeight: CGFloat = 360

    // Workspace
    public var workspaceRoot: String = ""
    public var workspaceLabel: String { workspaceRoot.isEmpty ? "No workspace" : URL(fileURLWithPath: workspaceRoot).lastPathComponent }

    // Recent workspace paths (persisted in UserDefaults, used by sidebar Projects)
    public var recentWorkspaces: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "recentWorkspaces") }
    }

    // Selected project in sidebar (filters threads)
    public var selectedProject: String? = nil

    // Backend
    public var activeBackend: ModelBackend = .llamaServer
    public private(set) var agentTuning: AgentTuningConfig = .default
    public private(set) var remoteModels: [RemoteModelConfig] = RemoteModelConfig.defaults
    public private(set) var activeRemoteModelID: String = "llama"

    public var activeRemoteModel: RemoteModelConfig? {
        remoteModels.first(where: { $0.id == activeRemoteModelID })
    }

    public var enabledRemoteModels: [RemoteModelConfig] {
        remoteModels.filter(\.enabled)
    }

    public var activeModelSupportsReasoning: Bool {
        activeBackend != .foundationApple && (activeRemoteModel?.supportsReasoning ?? false)
    }

    // Shared activation state for the current session profile.
    public let skillActivations = SkillActivations()
    private(set) var availableSkills: [TurboCodeSkillDefinition] = []

    /// Maps the persisted ReasoningEffort to FoundationModels' ReasoningLevel.
    /// Returns `nil` for Apple models (on-device and PCC) which don't support it.
    public var reasoningLevel: ContextOptions.ReasoningLevel? {
        reasoningLevel(for: activeRemoteModel)
    }

    private func reasoningLevel(for model: RemoteModelConfig?) -> ContextOptions.ReasoningLevel? {
        guard let model, model.supportsReasoning else { return nil }
        let raw = UserDefaults.standard.string(forKey: "reasoningEffort") ?? ReasoningEffort.medium.rawValue
        switch ReasoningEffort(rawValue: raw) ?? .medium {
        case .low:    return .light
        case .medium: return .moderate
        case .high:   return .deep
        }
    }

    // Delegation state — true when the orchestrator has called call_powerful_model
    // and is waiting for a response from the powerful model.
    public var isDelegating: Bool = false

    // Orchestrator mode
    public var orchestratorMode: OrchestratorMode {
        didSet {
            UserDefaults.standard.set(orchestratorMode.rawValue, forKey: "orchestratorMode")
            if orchestratorMode == .orchestrator {
                // Switching to orchestrator: force Apple as the active model
                // and rebuild so CallPowerfulModelTool is registered.
                activeBackend = .foundationApple
                composerModel = "Apple · Orchestrator"
                rebuildSession()
            } else {
                // Switching back to standalone: rebuild without the tool;
                // keep whatever backend was active (Apple stays Apple, Llama stays Llama).
                composerModel = activeBackend.rawValue
                rebuildSession()
            }
        }
    }

    // Diff inspector state (persiste oltre il ciclo di vita della view)
    var diffSections: [FileDiffSection] = []
    var isLoadingDiffs = false
    var diffLoadError: String?

    // Git branch state
    var currentBranch: String = ""
    var availableBranches: [String] = []

    private let gitService = GitDiffService()
    private let diffPatchService = DiffPatchService()

    public func reloadDiffs() async {
        guard !workspaceRoot.isEmpty else {
            diffSections = []
            diffLoadError = nil
            isLoadingDiffs = false
            return
        }

        isLoadingDiffs = true
        diffLoadError = nil
        diffSections = []

        let url = URL(fileURLWithPath: workspaceRoot)
        let sections = await FileDiffSection.fromGit(at: url, service: gitService)

        guard !Task.isCancelled else { return }

        if let sections {
            diffSections = sections
            diffLoadError = nil
        } else {
            diffSections = []
            diffLoadError = "Not a git repository or git unavailable"
        }
        isLoadingDiffs = false
    }

    public func refreshGitBranches() async {
        guard !workspaceRoot.isEmpty else {
            currentBranch = ""
            availableBranches = []
            return
        }

        let url = URL(fileURLWithPath: workspaceRoot)
        let branch = await gitService.currentBranch(at: url)
        let branches = await gitService.allBranches(at: url)

        guard !Task.isCancelled else { return }

        currentBranch = branch ?? ""
        availableBranches = branches
    }

    /// Switch to a different git branch. Refreshes state afterwards.
    public func switchToBranch(_ branch: String) async {
        guard !workspaceRoot.isEmpty else { return }
        let url = URL(fileURLWithPath: workspaceRoot)
        let success = await gitService.checkout(branch: branch, at: url)
        if success {
            currentBranch = branch
            await refreshGitBranches()
        }
    }

    // Session — recreated when backend or workspace changes
    private var session: LanguageModelSession

    // The currently running response task. Keeping the handle makes the Stop
    // button cancel the actual model stream rather than only changing the UI.
    private var responseTask: Task<Void, Never>?
    private var activeDiagnosticsRunID: String?
    private var activeEditGroupID: String?
    private var editTransactionGroups: [String: String] = [:]

    // MARK: - Onboarding

    /// Ensures the current `~/.turbocode/` layout exists and applies additive migrations.
    public func ensureOnboarding() async {
        do {
            try TurboCodeConfig.shared.performOnboarding()
            agentTuning = try TurboCodeConfig.shared.loadAgentTuning()
            availableSkills = configuredSkills()
            reloadRemoteModels()
        } catch {
            print("[TurboCode] Onboarding failed: \(error.localizedDescription)")
        }
    }
    public init() {
        // Restore orchestrator mode from UserDefaults
        let saved = UserDefaults.standard.string(forKey: "orchestratorMode")
            ?? OrchestratorMode.standalone.rawValue
        let mode = OrchestratorMode(rawValue: saved) ?? .standalone
        let selectedID = UserDefaults.standard.string(forKey: "activeRemoteModelID") ?? "llama"
        let initialRemote = RemoteModelConfig.defaults.first(where: {
            $0.id == selectedID && Self.hasCredential(for: $0)
        })
            ?? RemoteModelConfig.fallbackLlama
        self.activeRemoteModelID = initialRemote.id

        // Initialise ALL stored properties BEFORE any didSet observers fire.
        // We set orchestratorMode last so that session is already valid.
        self.activeBackend = mode == .orchestrator
            ? .foundationApple
            : Self.backend(for: initialRemote.role)
        let initialModel: any LanguageModel = mode == .orchestrator
            ? SystemLanguageModel.default
            : ProviderLanguageModel(
                configuration: initialRemote,
                apiKey: initialRemote.credential.flatMap(CredentialStore.value(for:))
            )
        self.session = LanguageModelSession(model: initialModel)
        self.composerModel = mode == .orchestrator
            ? "Apple \u{00B7} Orchestrator"
            : initialRemote.name

        // Now safe — didSet fires and calls rebuildSession() as needed.
        self.orchestratorMode = mode
    }

    /// Switch inference backend and rebuild the session,
    /// preserving the full conversation transcript.
    /// In orchestrator mode the backend is always Apple on-device;
    /// calling this method has no effect.
    public func switchBackend(to backend: ModelBackend) {
        guard orchestratorMode == .standalone else { return }
        if backend == .foundationApple {
            activeBackend = .foundationApple
            composerModel = backend.rawValue
        } else if let model = remoteModels.first(where: {
            $0.enabled && isConfigured($0) && Self.backend(for: $0.role) == backend
        }) {
            selectRemoteModel(model)
        } else {
            return
        }
        rebuildSession()
    }

    public func switchRemoteModel(to id: String) {
        guard orchestratorMode == .standalone,
              let model = remoteModels.first(where: { $0.id == id && $0.enabled }),
              isConfigured(model) else { return }
        selectRemoteModel(model)
        rebuildSession()
    }

    public func reloadRemoteModels() {
        guard let loaded = try? TurboCodeConfig.shared.loadRemoteModels(), !loaded.isEmpty else { return }
        remoteModels = loaded
        let selected = loaded.first(where: {
            $0.id == activeRemoteModelID && $0.enabled && isConfigured($0)
        }) ?? loaded.first(where: {
            $0.enabled && $0.role == .local && isConfigured($0)
        }) ?? loaded.first(where: {
            $0.enabled && isConfigured($0)
        })
        if let selected {
            activeRemoteModelID = selected.id
            if orchestratorMode == .standalone, activeBackend != .foundationApple {
                selectRemoteModel(selected)
            }
        }
        rebuildSession()
    }

    public func isConfigured(_ model: RemoteModelConfig) -> Bool {
        Self.hasCredential(for: model)
    }

    private static func hasCredential(for model: RemoteModelConfig) -> Bool {
        guard let credential = model.credential else { return true }
        return !(CredentialStore.value(for: credential) ?? "").isEmpty
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        UserDefaults.standard.set(effort.rawValue, forKey: "reasoningEffort")
        rebuildSession()
    }

    private func selectRemoteModel(_ model: RemoteModelConfig) {
        activeRemoteModelID = model.id
        UserDefaults.standard.set(model.id, forKey: "activeRemoteModelID")
        activeBackend = Self.backend(for: model.role)
        composerModel = model.name
    }

    private static func backend(for role: RemoteModelRole) -> ModelBackend {
        switch role {
        case .local: .llamaServer
        case .pcc: .foundationServe
        case .premium: .premium
        }
    }

    private func languageModel(for model: RemoteModelConfig) -> ProviderLanguageModel {
        ProviderLanguageModel(
            configuration: model,
            apiKey: model.credential.flatMap(CredentialStore.value(for:))
        )
    }

    private var delegateRemoteModel: RemoteModelConfig {
        remoteModels.first(where: { $0.enabled && $0.role == .local })
            ?? activeRemoteModel
            ?? RemoteModelConfig.fallbackLlama
    }

    private func temperature(for model: RemoteModelConfig?) -> Double? {
        guard let model else { return nil }
        if model.reasoningTransport == .deepseekThinking,
           reasoningLevel(for: model) != nil {
            return nil
        }
        return model.temperature
    }

    private var shouldDropCompletedToolCalls: Bool {
        guard activeBackend != .foundationApple else { return true }
        return activeRemoteModel?.reasoningTransport != .deepseekThinking
    }

    private var persistedModelIdentifier: String {
        activeBackend == .foundationApple ? activeBackend.rawValue : activeRemoteModelID
    }

    /// Build the instructions text from current workspace.
    private var baseInstructions: String {
        var text = """
        You are TurboCode, an AI coding assistant developed by the TurboCode team.
        You are NOT Apple's built-in assistant. Never refer to yourself as an Apple
        model or any Apple product. Your name is TurboCode.
        """
        text += "\nAlways use Markdown formatting in your responses: **bold**, `code`, ```code blocks```, tables, etc."
        switch agentTuning.agent.responseStyle {
        case .concise:
            text += "\nKeep responses concise and lead with the result. Include only details needed to act or verify."
        case .balanced:
            text += "\nKeep responses focused, with enough implementation and verification detail to be useful."
        case .detailed:
            text += "\nExplain decisions and verification in detail while avoiding repetition."
        }
        if agentTuning.agent.verifiesChanges {
            text += "\nAfter changing source code, run the most focused available build or test that verifies the change."
        }
        if !availableSkills.isEmpty {
            let catalog = availableSkills
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            text += """

            TurboCode discovers reusable skills automatically from ~/.turbocode/SKILLS/**/SKILL.md.
            Available skills:
            \(catalog)
            Use load_skill when a matching description applies; do not ask permission or announce loading.
            """
        }
        text += "\nTreat /skill <name> and /<skill-name> as explicit requests to activate that skill before handling the remaining prompt. Treat /skills as a request to list the currently advertised skills with concise descriptions."
        if !workspaceRoot.isEmpty {
            text += "\nThe current workspace is at: \(workspaceRoot)"
            text += "\nActivate the appropriate skill below to access file and code tools."
            text += "\nAll file operations are restricted to the workspace directory."
            text += "\nNEVER access files outside the workspace."
            text += "\nUse read_file with startLine and endLine to inspect only the relevant numbered source range and preserve context."
            text += "\nUse bash for Git queries, builds, tests, and precise inspection. Bash can read the workspace but cannot write to it."
            text += "\nUse edit_file for every source or text-file creation and modification. Read the relevant range immediately before editing, copy its Revision, and request one contiguous change per call. Never generate unified diff hunks."
            text += "\nWhen writing articles, biographies, documentation, or other long-form prose, preserve readable paragraphs with a blank line between them. The tool content must contain real newline characters; never collapse the whole document into one long line."
            text += "\nFile and directory deletion is the only operation that requires approval. If a tool output contains TURBOCODE_APPROVAL_REQUIRED, stop and wait for the user. Never print that technical approval block in your response."
        }
        return text
    }

    /// Rebuild the session preserving conversation history.
    /// Pass `keepingHistory: false` to start a fresh session (new thread).
    private func rebuildSession(keepingHistory: Bool = true) {
        let history = keepingHistory ? Array(session.transcript) : []

        let isOrchestrating = orchestratorMode == .orchestrator

        // ── Workspace tools for the delegate model ──
        var workspaceTools: [any Tool] = []
        if !workspaceRoot.isEmpty {
            workspaceTools += [
                ReadFileTool(workspaceRoot: workspaceRoot),
                GrepTool(workspaceRoot: workspaceRoot),
                FileSystemTool(workspaceRoot: workspaceRoot),
                BashTool(
                    workspaceRoot: workspaceRoot,
                    executionPolicy: agentTuning.execution
                ),
                EditFileTool(workspaceRoot: workspaceRoot)
            ]
        }
        if !availableSkills.isEmpty {
            workspaceTools.append(LoadSkillTool(skills: availableSkills))
        }

        // ── Profile tools ──
        let tools: [any Tool]
        let effectiveInstructions: String

        if isOrchestrating {
            let delegateModel = delegateRemoteModel
            let delegateBackend = Self.backend(for: delegateModel.role)
            let powerfulTool = CallPowerfulModelTool(
                model: languageModel(for: delegateModel),
                temperature: temperature(for: delegateModel),
                reasoningLevel: reasoningLevel(for: delegateModel),
                delegateTools: workspaceTools,
                delegateInstructions: baseInstructions,
                onToolStart: { [weak self] call in
                    await self?.beginToolActivity(call, backend: delegateBackend)
                },
                onToolEnd: { [weak self] call, output in
                    await self?.endToolActivity(call, output: output, backend: delegateBackend)
                }
            )
            var t: [any Tool] = [powerfulTool]
            if !workspaceRoot.isEmpty {
                t.append(FileSystemTool(workspaceRoot: workspaceRoot))
            }
            if !availableSkills.isEmpty {
                t.append(LoadSkillTool(skills: availableSkills))
            }
            tools = t

            var text = baseInstructions
            text += """


            === ORCHESTRATOR MODE ===
            You are TurboCode Orchestrator. You are NOT an Apple model — you are part of the TurboCode app. Your name is TurboCode, and you delegate complex tasks to the powerful coding model via `call_powerful_model`. You have the `file_system` tool to list directories, get file info, and find files — use it for navigation and discovery.

            For EVERYTHING else — reading files, writing or editing files, generating code, git operations, grep/searching, complex analysis, or any multi-step task — you MUST use `call_powerful_model` to delegate to the powerful coding model. The powerful model has all the tools it needs (read_file, grep, bash, file_system, and edit_file).

            CRITICAL — Never trust your own knowledge:
            - If you need to answer with file contents, always delegate reading to `call_powerful_model`.
            - If you need to modify code, always delegate to `call_powerful_model`.
            - Never rely on your training data for what a file contains or what code looks like in this project.
            - Always use the tools — `file_system` for listing, `call_powerful_model` for actual file work.

            Your role is:
            1. Understand what the user wants.
            2. For file listing/info: use `file_system` directly.
            3. For everything else: first output a brief acknowledgment to the user, then call `call_powerful_model` with a complete, self-contained task description that includes all relevant context (file paths, code snippets, error messages, requirements). Include full paths so the powerful model can navigate the workspace at: \(workspaceRoot).
            4. Synthesise the powerful model's response into a clear, well-formatted answer for the user.

            === APPROVAL REQUESTS ===
            If the powerful model's response contains "TURBOCODE_APPROVAL_REQUIRED", stop and wait for the user. The app presents the approval UI; never expose the technical approval block in your response.
            """
            effectiveInstructions = text
        } else {
            tools = workspaceTools
            effectiveInstructions = baseInstructions
        }

        // ── Build the session via DynamicProfile ──
        let activeModel: any LanguageModel
        switch activeBackend {
        case .foundationApple:
            activeModel = SystemLanguageModel.default
        case .foundationServe, .llamaServer, .premium:
            activeModel = languageModel(for: activeRemoteModel ?? RemoteModelConfig.fallbackLlama)
        }
        let sessionBackend = activeBackend

        if isOrchestrating {
            // Orchestrator profile: Apple + lifecycle callbacks for delegation detection
            session = LanguageModelSession(
                profile: TurboCodeDynamicProfile(
                    instructions: effectiveInstructions,
                    tools: tools,
                    model: activeModel,
                    onToolStart: { [weak self] call in
                        await self?.beginToolActivity(call, backend: .foundationApple)
                    },
                    onToolEnd: { [weak self] call, output in
                        await self?.endToolActivity(call, output: output, backend: .foundationApple)
                    },
                    onDelegationStart: { [weak self] in
                        await MainActor.run { self?.isDelegating = true }
                    },
                    onDelegationEnd: { [weak self] in
                        await MainActor.run { self?.isDelegating = false }
                    },
                    reasoningLevel: reasoningLevel
                ),
                history: history
            )
        } else {
            // Standalone: profile with Skills and reasoning level.
            session = LanguageModelSession(
                profile: StandaloneProfile(
                    instructions: effectiveInstructions,
                    activations: skillActivations,
                    diskSkills: availableSkills,
                    workspaceRoot: workspaceRoot,
                    model: activeModel,
                    temperature: temperature(for: activeRemoteModel),
                    reasoningLevel: reasoningLevel,
                    dropsCompletedToolCalls: shouldDropCompletedToolCalls,
                    executionPolicy: agentTuning.execution,
                    onToolStart: { [weak self] call in
                        await self?.beginToolActivity(call, backend: sessionBackend)
                    },
                    onToolEnd: { [weak self] call, output in
                        await self?.endToolActivity(call, output: output, backend: sessionBackend)
                    }
                ),
                history: history
            )
        }
    }

    // MARK: - Actions

    public func selectThread(_ id: String) async {
        activeThreadId = id
    }

    public func createThread(title: String = "New Chat", mode: ConversationMode = .agent) async {
        let thread = Conversation(
            title: title,
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: mode
        )
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
        blocks = []
        liveReasoning = ""
        liveAssistant = ""
        isFirstMessage = true
        rebuildSession(keepingHistory: false)
    }

    /// Makes every message entry point safe to use without requiring the user
    /// to press New Chat first. If an older buggy flow already produced blocks
    /// without a thread, attach them to the new metadata instead of discarding
    /// the visible conversation.
    private func ensureActiveThread() {
        guard let activeThreadId,
              threads.contains(where: { $0.id == activeThreadId }) else {
            let hasOrphanedBlocks = !blocks.isEmpty
            let thread = Conversation(
                title: "New Chat",
                workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
                mode: composerMode
            )
            threads.insert(thread, at: 0)
            self.activeThreadId = thread.id

            if !hasOrphanedBlocks {
                liveReasoning = ""
                liveAssistant = ""
                isFirstMessage = true
                rebuildSession(keepingHistory: false)
            }
            return
        }
    }

    /// Generates a concise title from the first user prompt using the
    /// Apple on-device model, then updates the active thread's title.
    public func generateTitle(from prompt: String) async {
        guard let idx = threads.firstIndex(where: { $0.id == activeThreadId }),
              threads[idx].title == "New Chat" else { return }

        let titlePrompt = """
        Generate a very short title (max 6 words) for a conversation that starts with this message.
        Respond with ONLY the title, no quotes, no punctuation.

        Message: \(prompt)
        """

        do {
            let model = SystemLanguageModel.default
            let titleSession = LanguageModelSession(model: model)
            var generated = ""
            for try await snapshot in titleSession.streamResponse(to: titlePrompt) {
                if !snapshot.content.isEmpty {
                    generated = snapshot.content
                }
            }
            let clean = generated
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            if !clean.isEmpty {
                threads[idx].title = String(clean.prefix(60))
                threads[idx].updatedAt = .now
            }
        } catch {
            // Silently fall back to "New Chat"
        }
    }

    // MARK: - Session Persistence

    /// Saves the active thread and its blocks to `~/.turbocode/sessions/<id>.json`.
    public func persistSession(for threadId: String) async {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
        let stored = StoredSession(
            id: thread.id,
            title: thread.title,
            projectName: thread.workspace
                .flatMap { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "_general",
            workspacePath: thread.workspace,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            modelBackend: persistedModelIdentifier,
            blocks: blocks.map {
                StoredBlock(id: $0.id, kind: $0.kind.rawValue, text: $0.text,
                    createdAt: $0.createdAt, model: $0.model, providerId: $0.providerId,
                    diffPatch: $0.diffPatch)
            }
        )
        do {
            try TurboCodeConfig.shared.saveSession(stored)
        } catch {
            print("[TurboCode] Failed to persist session: \(error.localizedDescription)")
        }
    }

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        guard let all = try? TurboCodeConfig.shared.listSessions(),
              !all.isEmpty else { return }
        let existingIDs = Set(threads.map(\.id))
        for stored in all where !existingIDs.contains(stored.id) {
            threads.append(Conversation(
                id: stored.id,
                title: stored.title,
                createdAt: stored.createdAt,
                updatedAt: stored.updatedAt,
                workspace: stored.workspacePath,
                mode: .agent
            ))
        }
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        guard let stored = try? TurboCodeConfig.shared.loadSession(id: id),
              let _ = threads.firstIndex(where: { $0.id == id }) else { return }
        activeThreadId = id
        blocks = stored.blocks.map {
            ChatBlock(id: $0.id, kind: ChatBlockKind(rawValue: $0.kind) ?? .assistant,
                text: $0.text, createdAt: $0.createdAt, model: $0.model,
                providerId: $0.providerId, diffPatch: $0.diffPatch)
        }
        liveReasoning = ""; liveAssistant = ""
        isFirstMessage = blocks.isEmpty
        if let wp = stored.workspacePath, workspaceRoot != wp {
            workspaceRoot = wp
        }
        restoreModelSelection(stored.modelBackend)
        rebuildSession(keepingHistory: false)
    }

    private func restoreModelSelection(_ identifier: String) {
        guard orchestratorMode == .standalone else { return }
        if identifier == ModelBackend.foundationApple.rawValue {
            activeBackend = .foundationApple
            composerModel = ModelBackend.foundationApple.rawValue
            return
        }

        let legacyRole: RemoteModelRole? = switch identifier {
        case ModelBackend.llamaServer.rawValue: .local
        case ModelBackend.foundationServe.rawValue: .pcc
        default: nil
        }
        let model = remoteModels.first(where: {
            $0.enabled && ($0.id == identifier || $0.role == legacyRole)
        })
        if let model, isConfigured(model) {
            selectRemoteModel(model)
        }
    }

    public func renameThread(id: String, title: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].title = title
        threads[i].updatedAt = .now
    }

    public func pinThread(id: String, pinned: Bool) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isPinned = pinned
        threads[i].updatedAt = .now
    }

    public func archiveThread(id: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isArchived = true
        threads[i].updatedAt = .now
    }

    public func deleteThread(id: String) async {
        threads.removeAll { $0.id == id }
        if activeThreadId == id { activeThreadId = threads.first?.id }
    }

    /// Removes a workspace from TurboCode and deletes only its persisted chats.
    /// The workspace directory and all project files are left untouched.
    public func removeWorkspace(_ path: String) async {
        var sessionIDs = Set(
            threads
                .filter { $0.workspace == path }
                .map(\.id)
        )
        if let storedSessions = try? TurboCodeConfig.shared.listSessions() {
            sessionIDs.formUnion(
                storedSessions
                    .filter { $0.workspacePath == path }
                    .map(\.id)
            )
        }

        var deletionErrors: [String] = []
        for id in sessionIDs {
            do {
                try TurboCodeConfig.shared.deleteSession(id: id)
            } catch {
                deletionErrors.append(error.localizedDescription)
            }
        }

        let removedActiveThread = activeThreadId.map(sessionIDs.contains) ?? false
        threads.removeAll { $0.workspace == path }
        recentWorkspaces = recentWorkspaces.filter { $0 != path }

        if removedActiveThread {
            activeThreadId = nil
            blocks = []
            liveReasoning = ""
            liveAssistant = ""
            isFirstMessage = true
        }

        if workspaceRoot == path {
            responseTask?.cancel()
            workspaceRoot = ""
            selectedProject = nil
            currentBranch = ""
            availableBranches = []
            diffSections = []
            isLoadingDiffs = false
            rightPanelMode = nil
            rebuildSession(keepingHistory: false)
        }

        if !deletionErrors.isEmpty {
            error = "Some workspace chats could not be removed: \(deletionErrors.joined(separator: "; "))"
        }
    }

    public func restoreThread(id: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isArchived = false
        threads[i].updatedAt = .now
    }

    /// Open a folder picker and set workspaceRoot.
    public func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a workspace folder for the AI agent"
        if !workspaceRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workspaceRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setWorkspace(url.path)
    }

    /// Switch to a previously opened workspace by path.
    public func switchToWorkspace(_ path: String) {
        setWorkspace(path)
    }

    /// Internal: configure workspace, rebuild session, refresh git state.
    private func setWorkspace(_ path: String) {
        workspaceRoot = path

        // Save to recent workspaces
        var recent = recentWorkspaces
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recentWorkspaces = Array(recent.prefix(10))
        selectedProject = URL(fileURLWithPath: path).lastPathComponent

        rebuildSession()
        // The inspector is opt-in: changing workspace must not open it.
        rightPanelMode = nil
        diffSections = []
        isLoadingDiffs = true
        Task { await reloadDiffs() }
        Task { await refreshGitBranches() }
    }

    /// Clear the workspace selection.
    public func clearWorkspace() {
        workspaceRoot = ""
        currentBranch = ""
        availableBranches = []
        rebuildSession()
        rightPanelMode = nil
    }

    public func sendMessage(_ text: String) async {
        refreshSkillsIfNeeded()
        guard let promptText = resolvedPrompt(for: text) else { return }
        await sendMessage(text, promptText: promptText, visibleInTimeline: true)
    }

    func isIncompleteSkillCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/skill"
    }

    public func reloadSkills() {
        refreshSkillsIfNeeded(forceRebuild: true)
    }

    func applyAgentTuning(_ value: AgentTuningConfig) {
        guard let validated = try? value.validated() else { return }
        agentTuning = validated
        availableSkills = configuredSkills()
        rebuildSession()
    }

    private func configuredSkills() -> [TurboCodeSkillDefinition] {
        let discovered = TurboCodeConfig.shared.loadSkills()
        guard !agentTuning.skills.discoversUserSkills else { return discovered }
        let builtInNames: Set<String> = ["turbocode", "skill-creator"]
        return discovered.filter { builtInNames.contains($0.name) }
    }

    private func refreshSkillsIfNeeded(forceRebuild: Bool = false) {
        let discovered = configuredSkills()
        guard forceRebuild || discovered != availableSkills else { return }
        availableSkills = discovered
        rebuildSession()
    }

    private func resolvedPrompt(for displayText: String) -> String? {
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isIncompleteSkillCommand(trimmed) else { return nil }
        guard trimmed.hasPrefix("/") else { return displayText }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        let skillName: String
        let request: String

        if parts.first == "/skill" {
            guard parts.count >= 2 else { return nil }
            skillName = parts[1]
            request = parts.count == 3 ? parts[2] : ""
        } else {
            skillName = String((parts.first ?? "").dropFirst())
            request = parts.count >= 2 ? parts.dropFirst().joined(separator: " ") : ""
        }

        guard let skill = availableSkills.first(where: { $0.name == skillName }) else {
            return displayText
        }
        let userRequest = request.isEmpty
            ? "Apply this skill and respond appropriately to the selected command."
            : request
        return """
        The user explicitly selected the TurboCode skill '\(skill.name)'. Its instructions follow.

        <skill name="\(skill.name)">
        \(skill.prompt)
        </skill>

        User request:
        \(userRequest)
        """
    }

    private func sendMessage(
        _ text: String,
        promptText: String? = nil,
        visibleInTimeline: Bool
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !busy else { return }

        let effectivePrompt = promptText ?? text
        ensureActiveThread()
        busy = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSendMessage(
                displayText: text,
                promptText: effectivePrompt,
                visibleInTimeline: visibleInTimeline
            )
        }
        responseTask = task
        await task.value
        responseTask = nil
        busy = false
    }

    private func performSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async {

        let diagnosticsRunID = await AgentDiagnosticsRecorder.shared.startRun(
            backend: activeBackend,
            mode: orchestratorMode,
            profileVersion: AgentProfileVersion.value(for: activeBackend, mode: orchestratorMode),
            workspaceKind: diagnosticsWorkspaceKind,
            promptCharacters: promptText.count
        )
        activeDiagnosticsRunID = diagnosticsRunID
        let editGroupID = UUID().uuidString
        activeEditGroupID = editGroupID
        var diagnosticsOutcome: AgentRunOutcome = .success
        var diagnosticsError: Error?
        var didRecordFirstToken = false
        var diagnosticsGeneratedCharacters = 0

        isFirstMessage = false
        // Generate the title concurrently with the response, but retain the
        // task so persistence can wait for the final title.
        let titleTask: Task<Void, Never>? = visibleInTimeline ? Task { [weak self] in
            guard let self else { return }
            await self.generateTitle(from: displayText)
        } : nil

        if visibleInTimeline {
            blocks.append(ChatBlock(kind: .user, text: displayText))
        }

        let placeholderId = UUID().uuidString
        blocks.append(ChatBlock(id: placeholderId, kind: .assistant, text: "", model: composerModel))

        runtimeStatus = .ready
        error = nil
        var accumulatedText = ""

        do {
            let stream = session.streamResponse(to: promptText)
            // Delegation detection is handled by TurboCodeDynamicProfile's
            // onToolCall / onToolOutput lifecycle callbacks — no scanning needed.

            for try await snapshot in stream {
                try Task.checkCancellation()

                // Fast path: update liveAssistant for quick UI feedback
                if !snapshot.content.isEmpty {
                    if !didRecordFirstToken, let diagnosticsRunID {
                        didRecordFirstToken = true
                        await AgentDiagnosticsRecorder.shared.markFirstToken(runID: diagnosticsRunID)
                    }
                    accumulatedText = snapshot.content
                    diagnosticsGeneratedCharacters = max(
                        diagnosticsGeneratedCharacters,
                        snapshot.content.count
                    )
                    liveAssistant = userVisibleAssistantText(accumulatedText)
                }

                // Process transcript entries for reasoning and tool approvals.
                for entry in snapshot.transcriptEntries {
                    if case .reasoning(let reasoning) = entry {
                        for segment in reasoning.segments {
                            if case .text(let t) = segment {
                                if !didRecordFirstToken, !t.content.isEmpty, let diagnosticsRunID {
                                    didRecordFirstToken = true
                                    await AgentDiagnosticsRecorder.shared.markFirstToken(
                                        runID: diagnosticsRunID
                                    )
                                }
                                liveReasoning = t.content
                                diagnosticsGeneratedCharacters = max(
                                    diagnosticsGeneratedCharacters,
                                    t.content.count
                                )
                            }
                        }
                    }

                    if case .toolOutput(let output) = entry {
                        let text = output.segments.compactMap { segment -> String? in
                            if case .text(let t) = segment { return t.content }
                            return nil
                        }.joined()
                        if let request = ApprovalRequest(toolOutput: text) {
                            presentApproval(request)
                        }
                    }
                }
            }
            try Task.checkCancellation()

            // Stream ended: finalize the assistant block.
            // Reset delegation state once streaming is done.
            isDelegating = false
            toolActivities.removeAll()
            let finalText = accumulatedText.isEmpty
                ? liveReasoning
                : userVisibleAssistantText(accumulatedText)
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.remove(at: i)
                } else {
                    blocks[i] = ChatBlock(
                        id: placeholderId,
                        kind: .assistant,
                        text: finalText,
                        model: composerModel
                    )
                }
            }

            // Separate reasoning block if model output BOTH reasoning and content.
            if !liveReasoning.isEmpty && !accumulatedText.isEmpty {
                if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                    blocks.insert(
                        ChatBlock(kind: .reasoning, text: liveReasoning, model: composerModel),
                        at: i
                    )
                }
            }
            liveReasoning = ""
            liveAssistant = ""  // hide live streaming block

            if let i = threads.firstIndex(where: { $0.id == activeThreadId }) {
                threads[i].updatedAt = .now
            }
        } catch where error is CancellationError || Task.isCancelled {
            diagnosticsOutcome = .cancelled
            // Keep whatever the model had already produced and mark an empty
            // response clearly, without presenting cancellation as an error.
            let partialText = accumulatedText.isEmpty ? liveReasoning : accumulatedText
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                blocks[i] = ChatBlock(
                    id: placeholderId,
                    kind: .assistant,
                    text: partialText.isEmpty ? "Response interrupted." : partialText,
                    model: composerModel
                )
            }
            liveReasoning = ""
            liveAssistant = ""
            isDelegating = false
            toolActivities.removeAll()
            self.error = nil
        } catch {
            diagnosticsOutcome = .failed
            diagnosticsError = error
            toolActivities.removeAll()
            self.error = error.localizedDescription
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                blocks[i] = ChatBlock(
                    id: placeholderId,
                    kind: .assistant,
                    text: "Error: \(error.localizedDescription)",
                    model: composerModel
                )
            }
        }
        if let diagnosticsRunID {
            await AgentDiagnosticsRecorder.shared.finishRun(
                runID: diagnosticsRunID,
                outcome: diagnosticsOutcome,
                generatedCharacters: diagnosticsGeneratedCharacters,
                error: diagnosticsError
            )
            if activeDiagnosticsRunID == diagnosticsRunID {
                activeDiagnosticsRunID = nil
            }
        }
        if activeEditGroupID == editGroupID {
            activeEditGroupID = nil
        }
        editTransactionGroups = editTransactionGroups.filter { $0.value != editGroupID }
        // Persist after the title task finishes so the JSON never races with
        // the Apple on-device title generator and stores a stale "New Chat".
        if let titleTask {
            await titleTask.value
        }
        if let tid = activeThreadId {
            await persistSession(for: tid)
        }

    }

    public func interrupt() {
        responseTask?.cancel()
    }

#if DEBUG
    public func runActiveEditingBenchmark() async {
        guard !benchmarkRunning, !busy else { return }
        benchmarkRunning = true
        benchmarkStatus = "Running \(activeBackend.rawValue) editing benchmark..."
        defer { benchmarkRunning = false }

        let model: any LanguageModel
        switch activeBackend {
        case .foundationApple:
            model = SystemLanguageModel.default
        case .foundationServe, .llamaServer, .premium:
            model = languageModel(for: activeRemoteModel ?? RemoteModelConfig.fallbackLlama)
        }
        let result = await AgentBenchmarkRunner.runSuite(
            backend: activeBackend,
            model: model,
            reasoningLevel: reasoningLevel
        )
        benchmarkStatus = result.summary
        print("[Benchmark] \(result.summary)")
    }

    public func printToolFailureSummary() async {
        let summary = await AgentDiagnosticsRecorder.shared.failureSummary()
        print("[Diagnostics] \(summary)")
    }
#endif

    private var diagnosticsWorkspaceKind: String {
        guard !workspaceRoot.isEmpty else { return "none" }
        let marker = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: marker.path) ? "git" : "nonGit"
    }

    /// Approve a pending tool operation, execute the exact registered action,
    /// then inform the model that the action completed.
    public func approveAction() {
        guard let request = pendingApproval else { return }
        advanceApprovalQueue()

        Task {
            let result = await ToolApprovalRegistry.shared.approve(id: request.id)
            await sendInternalMessageWhenIdle("""
            [User approved tool action]
            Operation: \(request.operation)
            Path: \(request.path)
            Result:
            \(result)
            """)
        }
    }

    /// Reject a pending tool operation.
    public func rejectAction() {
        guard let request = pendingApproval else { return }
        advanceApprovalQueue()
        if request.operation == "diffPatch" {
            updateDiffPatchBlock(id: request.id, status: .rejected)
        }
        Task {
            await ToolApprovalRegistry.shared.reject(id: request.id)
            await sendInternalMessageWhenIdle("[User rejected tool action: \(request.summary). Do NOT perform this action.]")
        }
    }

    /// Receives approval requests directly from ToolApprovalRegistry. Transcript
    /// parsing remains a compatibility fallback for external model adapters.
    public func presentApproval(_ request: ApprovalRequest) {
        guard pendingApproval?.id != request.id,
              !queuedApprovals.contains(where: { $0.id == request.id }) else { return }

        if pendingApproval == nil {
            pendingApproval = request
        } else {
            queuedApprovals.append(request)
        }
    }

    private func advanceApprovalQueue() {
        pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
    }

    private func sendInternalMessageWhenIdle(_ text: String) async {
        while busy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await sendMessage(text, visibleInTimeline: false)
    }

    private func beginToolActivity(_ call: Transcript.ToolCall, backend: ModelBackend) async {
        if let activeDiagnosticsRunID {
            await AgentDiagnosticsRecorder.shared.toolStarted(
                runID: activeDiagnosticsRunID,
                call: call,
                backend: backend
            )
        }
        guard call.toolName != "diff_patch",
              call.toolName != "apply_edits",
              call.toolName != "edit_file" else { return }
        toolActivities.removeAll { $0.id == call.id }
        toolActivities.append(ToolActivity(id: call.id, summary: toolSummary(for: call)))
    }

    private func endToolActivity(
        _ call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        backend: ModelBackend
    ) async {
        if let activeDiagnosticsRunID {
            await AgentDiagnosticsRecorder.shared.toolFinished(
                runID: activeDiagnosticsRunID,
                call: call,
                output: output,
                backend: backend
            )
        }
        toolActivities.removeAll { $0.id == call.id }
    }

    public func beginDiffPatchBlock(
        id: String,
        patch: String,
        files: [DiffPatchFileChange],
        status: DiffPatchStatus
    ) {
        let blockID = activeEditGroupID ?? id
        editTransactionGroups[id] = blockID

        if let index = blocks.firstIndex(where: { $0.id == blockID }),
           var payload = blocks[index].diffPatch {
            var patches = payload.patches ?? [payload.patch]
            patches.append(patch)
            payload.patches = patches
            payload.patch = patches.joined(separator: "\n")
            payload.files = mergedFileChanges(payload.files + files)
            payload.status = status
            payload.errorMessage = nil
            blocks[index].diffPatch = payload
            return
        }
        let payload = DiffPatchBlock(
            workspaceRoot: workspaceRoot,
            patch: patch,
            patches: [patch],
            files: files,
            status: status,
            errorMessage: nil
        )
        let block = ChatBlock(id: blockID, kind: .diffPatch, text: "", diffPatch: payload)
        if let placeholderIndex = blocks.lastIndex(where: { $0.kind == .assistant && $0.text.isEmpty }) {
            blocks.insert(block, at: placeholderIndex)
        } else {
            blocks.append(block)
        }
    }

    public func updateDiffPatchBlock(
        id: String,
        status: DiffPatchStatus,
        errorMessage: String? = nil
    ) {
        let blockID = editTransactionGroups[id] ?? id
        guard let index = blocks.firstIndex(where: { $0.id == blockID }),
              var payload = blocks[index].diffPatch else { return }
        payload.status = status
        payload.errorMessage = errorMessage
        blocks[index].diffPatch = payload

        if status == .applied || status == .undone {
            Task { await reloadDiffs() }
        }
    }

    public func reviewDiffPatch(_ id: String) {
        guard blocks.contains(where: { $0.id == id && $0.diffPatch != nil }) else { return }
        rightPanelMode = .changes
        Task { await reloadDiffs() }
    }

    public func undoDiffPatch(_ id: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              let payload = blocks[index].diffPatch,
              payload.status == .applied else { return }

        updateDiffPatchBlock(id: id, status: .undoing)
        Task {
            var revertedPatches: [String] = []
            do {
                for patch in (payload.patches ?? [payload.patch]).reversed() {
                    try await diffPatchService.apply(
                        patch: patch,
                        workspaceRoot: payload.workspaceRoot,
                        reverse: true
                    )
                    revertedPatches.append(patch)
                }
                updateDiffPatchBlock(id: id, status: .undone)
            } catch {
                for patch in revertedPatches.reversed() {
                    try? await diffPatchService.apply(
                        patch: patch,
                        workspaceRoot: payload.workspaceRoot
                    )
                }
                updateDiffPatchBlock(
                    id: id,
                    status: .applied,
                    errorMessage: "Undo failed: \(error.localizedDescription)"
                )
            }
            if let threadID = activeThreadId {
                await persistSession(for: threadID)
            }
        }
    }

    private func mergedFileChanges(
        _ changes: [DiffPatchFileChange]
    ) -> [DiffPatchFileChange] {
        var order: [String] = []
        var totals: [String: (additions: Int, deletions: Int)] = [:]
        for change in changes {
            if totals[change.path] == nil { order.append(change.path) }
            totals[change.path, default: (0, 0)].additions += change.additions
            totals[change.path, default: (0, 0)].deletions += change.deletions
        }
        return order.compactMap { path in
            guard let total = totals[path] else { return nil }
            return DiffPatchFileChange(
                path: path,
                additions: total.additions,
                deletions: total.deletions
            )
        }
    }

    private func toolSummary(for call: Transcript.ToolCall) -> String {
        let path = (try? call.arguments.value(String.self, forProperty: "filePath"))
            ?? (try? call.arguments.value(String.self, forProperty: "path"))
        let item = path.map { URL(fileURLWithPath: $0).lastPathComponent }

        switch call.toolName {
        case "read_file":
            return item.map { "Reading \($0)" } ?? "Reading file"
        case "grep":
            return item.map { "Searching in \($0)" } ?? "Searching workspace"
        case "bash":
            return "Running command"
        case "apply_edits", "edit_file":
            return "Preparing file changes"
        case "file_system":
            let operation = try? call.arguments.value(String.self, forProperty: "operation")
            switch operation {
            case "list": return item.map { "Listing \($0)" } ?? "Listing files"
            case "info": return item.map { "Inspecting \($0)" } ?? "Inspecting item"
            case "find": return item.map { "Finding files in \($0)" } ?? "Finding files"
            case "createDirectory": return item.map { "Creating \($0)" } ?? "Creating folder"
            case "write": return item.map { "Writing \($0)" } ?? "Writing file"
            case "append": return item.map { "Updating \($0)" } ?? "Updating file"
            case "copy": return item.map { "Copying \($0)" } ?? "Copying item"
            case "move": return item.map { "Moving \($0)" } ?? "Moving item"
            case "delete": return item.map { "Deleting \($0)" } ?? "Deleting item"
            default: return "Working with files"
            }
        case "call_powerful_model":
            return "Working with coding model"
        case "activate_skill", "toggle_skill", "load_skill":
            let skill = try? call.arguments.value(String.self, forProperty: "skill")
            return skill.map { "Loading \($0)" } ?? "Loading skill"
        default:
            return "Using \(call.toolName.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private func userVisibleAssistantText(_ text: String) -> String {
        let approvalKeys = Set(["approval_id", "operation", "path", "destination", "summary"])
        var isSkippingApproval = false
        var visibleLines: [String] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("TURBOCODE_APPROVAL_REQUIRED") {
                isSkippingApproval = true
                continue
            }

            if isSkippingApproval {
                let key = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                if trimmed.isEmpty || approvalKeys.contains(key) {
                    continue
                }
                isSkippingApproval = false
            }

            visibleLines.append(line)
        }

        return visibleLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setRoute(_ route: AppRoute) {
        self.route = route
        if route != .chat { rightPanelMode = nil }
    }

    public func toggleRightPanel(_ mode: RightPanelMode) {
        rightPanelMode = rightPanelMode == mode ? nil : mode
    }

    public func toggleTerminal() { terminalOpen.toggle() }

    public func toggleLeftSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) { leftSidebarCollapsed.toggle() }
    }

    // MARK: - Sorted Threads

    public var sortedThreads: [Conversation] {
        let q = threadSearch.lowercased().trimmingCharacters(in: .whitespaces)
        return threads
            .filter { t in showArchivedThreads ? true : !t.isArchived }
            .filter { t in
                if let project = selectedProject {
                    // Match by lastPathComponent of workspace
                    return t.workspace.flatMap { URL(fileURLWithPath: $0).lastPathComponent } == project
                }
                return true
            }
            .filter { t in q.isEmpty ? true : t.title.lowercased().contains(q) }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.updatedAt > b.updatedAt
            }
    }
}

// MARK: - DynamicInstructions for session setup

/// Wraps instructions text and tools into a single DynamicInstructions value.
// MARK: - Runtime status

public enum RuntimeStatus: String, Sendable, Hashable {
    case disconnected; case connecting; case ready; case error
}
public enum RuntimeConnectionState: String, Sendable, Hashable {
    case disconnected; case connecting; case ready
}

// MARK: - Tool Activity

public struct ToolActivity: Identifiable, Sendable, Hashable {
    public let id: String
    public let summary: String
}

// MARK: - Pending Approval

public struct ApprovalRequest: Sendable {
    public let id: String
    public let operation: String
    public let path: String
    public let destination: String?
    public let summary: String

    public var displaySummary: String {
        let item = URL(fileURLWithPath: path).lastPathComponent
        switch operation {
        case "createDirectory": return "Create \(item)"
        case "write": return "Write \(item)"
        case "append": return "Update \(item)"
        case "copy": return "Copy \(item)"
        case "move": return "Move \(item)"
        case "delete": return "Delete \(item)"
        default: return summary
        }
    }

    public init(
        id: String,
        operation: String,
        path: String,
        destination: String? = nil,
        summary: String
    ) {
        self.id = id
        self.operation = operation
        self.path = path
        self.destination = destination
        self.summary = summary
    }

    public init?(toolOutput: String) {
        guard toolOutput.contains("TURBOCODE_APPROVAL_REQUIRED") else { return nil }

        var values: [String: String] = [:]
        for line in toolOutput.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        guard let id = values["approval_id"],
              let operation = values["operation"],
              let path = values["path"],
              let summary = values["summary"] else { return nil }

        self.init(
            id: id,
            operation: operation,
            path: path,
            destination: values["destination"],
            summary: summary
        )
    }
}
