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

    // Skill activations for standalone mode — lets the model activate only
    // the tools it needs for the current task.
    public let skillActivations = SkillActivations()

    /// Maps the persisted ReasoningEffort to FoundationModels' ReasoningLevel.
    /// Returns `nil` for Apple models (on-device and PCC) which don't support it.
    public var reasoningLevel: ContextOptions.ReasoningLevel? {
        guard activeBackend != .foundationApple, activeBackend != .foundationServe else { return nil }
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

    // MARK: - Onboarding

    /// Ensures `~/.turbocode/` exists. Called once at app launch.
    public func ensureOnboarding() async {
        guard !TurboCodeConfig.shared.isOnboarded else { return }
        do {
            try TurboCodeConfig.shared.performOnboarding()
        } catch {
            print("[TurboCode] Onboarding failed: \(error.localizedDescription)")
        }
    }
    /// Configuration for the remote Llama server (OpenAI-compatible endpoint).
    private let llamaModelName: String
    private let llamaBaseURL: URL
    private let llamaTemperature: Double
    /// Configuration for fm serve (Apple Foundation Models local server).
    private let fmServeBaseURL: URL

    public init() {
        self.llamaModelName = "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf"
        self.llamaBaseURL = URL(string: "http://127.0.0.1:8080/v1")!
        self.llamaTemperature = 0.6
        self.fmServeBaseURL = URL(string: "http://127.0.0.1:1976/v1")!

        // Restore orchestrator mode from UserDefaults
        let saved = UserDefaults.standard.string(forKey: "orchestratorMode")
            ?? OrchestratorMode.standalone.rawValue
        let mode = OrchestratorMode(rawValue: saved) ?? .standalone

        // Initialise ALL stored properties BEFORE any didSet observers fire.
        // We set orchestratorMode last so that session is already valid.
        self.activeBackend = mode == .orchestrator ? .foundationApple : .llamaServer
        let initialModel: any LanguageModel = mode == .orchestrator
            ? SystemLanguageModel.default
            : ChatCompletionsLanguageModel(name: llamaModelName, url: llamaBaseURL)
        self.session = LanguageModelSession(model: initialModel)
        self.composerModel = mode == .orchestrator
            ? "Apple \u{00B7} Orchestrator"
            : ModelBackend.llamaServer.rawValue

        // Now safe — didSet fires and calls rebuildSession() as needed.
        self.orchestratorMode = mode
    }

    /// Switch inference backend and rebuild the session,
    /// preserving the full conversation transcript.
    /// In orchestrator mode the backend is always Apple on-device;
    /// calling this method has no effect.
    public func switchBackend(to backend: ModelBackend) {
        guard orchestratorMode == .standalone else { return }
        activeBackend = backend
        composerModel = backend.rawValue
        rebuildSession()
    }

    /// Build the instructions text from current workspace.
    private var baseInstructions: String {
        var text = """
        You are TurboCode, an AI coding assistant developed by the TurboCode team.
        You are NOT Apple's built-in assistant. Never refer to yourself as an Apple
        model or any Apple product. Your name is TurboCode.
        """
        text += "\nAlways use Markdown formatting in your responses: **bold**, `code`, ```code blocks```, tables, etc."
        if !workspaceRoot.isEmpty {
            text += "\nThe current workspace is at: \(workspaceRoot)"
            text += "\nActivate the appropriate skill below to access file and code tools."
            text += "\nAll file operations are restricted to the workspace directory."
            text += "\nNEVER access files outside the workspace."
            text += "\nUse read_file with startLine and endLine to inspect only the relevant numbered source range and preserve context."
            text += "\nUse bash for Git queries, builds, tests, and precise inspection. Bash starts in the workspace and its writes are sandboxed to the workspace."
            text += "\nUse diff_patch for source and text changes in Git workspaces. For existing files, read the relevant range immediately before editing and use structured edits with exact oldText/newText; do not handcraft hunks. Use a raw patch primarily to create new files."
            text += "\nIf a tool output contains TURBOCODE_APPROVAL_REQUIRED, stop and wait for the user. Never print that technical approval block in your response."
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
                BashTool(workspaceRoot: workspaceRoot),
                DiffPatchTool(workspaceRoot: workspaceRoot)
            ]
        }

        // ── Profile tools ──
        let tools: [any Tool]
        let effectiveInstructions: String

        if isOrchestrating {
            let powerfulTool = CallPowerfulModelTool(
                modelName: llamaModelName,
                baseURL: llamaBaseURL,
                temperature: llamaTemperature,
                delegateTools: workspaceTools,
                delegateInstructions: baseInstructions,
                onToolStart: { [weak self] call in
                    await MainActor.run { self?.beginToolActivity(call) }
                },
                onToolEnd: { [weak self] call in
                    await MainActor.run { self?.endToolActivity(call) }
                }
            )
            var t: [any Tool] = [powerfulTool]
            if !workspaceRoot.isEmpty {
                t.append(FileSystemTool(workspaceRoot: workspaceRoot))
            }
            tools = t

            var text = baseInstructions
            text += """


            === ORCHESTRATOR MODE ===
            You are TurboCode Orchestrator. You are NOT an Apple model — you are part of the TurboCode app. Your name is TurboCode, and you delegate complex tasks to the powerful coding model via `call_powerful_model`. You have the `file_system` tool to list directories, get file info, and find files — use it for navigation and discovery.

            For EVERYTHING else — reading files, writing or editing files, generating code, git operations, grep/searching, complex analysis, or any multi-step task — you MUST use `call_powerful_model` to delegate to the powerful coding model. The powerful model has all the tools it needs (read_file, grep, bash, file_system, and diff_patch).

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
        case .foundationServe:
            activeModel = ChatCompletionsLanguageModel(name: "pcc", url: fmServeBaseURL)
        case .llamaServer:
            activeModel = ChatCompletionsLanguageModel(name: llamaModelName, url: llamaBaseURL)
        }

        if isOrchestrating {
            // Orchestrator profile: Apple + lifecycle callbacks for delegation detection
            session = LanguageModelSession(
                profile: TurboCodeDynamicProfile(
                    instructions: effectiveInstructions,
                    tools: tools,
                    model: activeModel,
                    onToolStart: { [weak self] call in
                        await MainActor.run { self?.beginToolActivity(call) }
                    },
                    onToolEnd: { [weak self] call in
                        await MainActor.run { self?.endToolActivity(call) }
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
                    workspaceRoot: workspaceRoot,
                    model: activeModel,
                    reasoningLevel: reasoningLevel,
                    onToolStart: { [weak self] call in
                        await MainActor.run { self?.beginToolActivity(call) }
                    },
                    onToolEnd: { [weak self] call in
                        await MainActor.run { self?.endToolActivity(call) }
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
            modelBackend: activeBackend.rawValue,
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
        rebuildSession(keepingHistory: false)
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
        await sendMessage(text, visibleInTimeline: true)
    }

    private func sendMessage(_ text: String, visibleInTimeline: Bool) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !busy else { return }

        ensureActiveThread()
        busy = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSendMessage(text, visibleInTimeline: visibleInTimeline)
        }
        responseTask = task
        await task.value
        responseTask = nil
        busy = false
    }

    private func performSendMessage(_ text: String, visibleInTimeline: Bool) async {

        isFirstMessage = false
        // Generate the title concurrently with the response, but retain the
        // task so persistence can wait for the final title.
        let titleTask: Task<Void, Never>? = visibleInTimeline ? Task { [weak self] in
            guard let self else { return }
            await self.generateTitle(from: text)
        } : nil

        if visibleInTimeline {
            blocks.append(ChatBlock(kind: .user, text: text))
        }

        let placeholderId = UUID().uuidString
        blocks.append(ChatBlock(id: placeholderId, kind: .assistant, text: "", model: composerModel))

        runtimeStatus = .ready
        error = nil
        var accumulatedText = ""

        do {
            let stream = session.streamResponse(to: text)
            // Delegation detection is handled by TurboCodeDynamicProfile's
            // onToolCall / onToolOutput lifecycle callbacks — no scanning needed.

            for try await snapshot in stream {
                try Task.checkCancellation()

                // Fast path: update liveAssistant for quick UI feedback
                if !snapshot.content.isEmpty {
                    accumulatedText = snapshot.content
                    liveAssistant = userVisibleAssistantText(accumulatedText)
                }

                // Process transcript entries for reasoning and tool approvals.
                for entry in snapshot.transcriptEntries {
                    if case .reasoning(let reasoning) = entry {
                        for segment in reasoning.segments {
                            if case .text(let t) = segment {
                                liveReasoning = t.content
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

    private func beginToolActivity(_ call: Transcript.ToolCall) {
        guard call.toolName != "diff_patch" else { return }
        toolActivities.removeAll { $0.id == call.id }
        toolActivities.append(ToolActivity(id: call.id, summary: toolSummary(for: call)))
    }

    private func endToolActivity(_ call: Transcript.ToolCall) {
        toolActivities.removeAll { $0.id == call.id }
    }

    public func beginDiffPatchBlock(
        id: String,
        patch: String,
        files: [DiffPatchFileChange],
        status: DiffPatchStatus
    ) {
        guard !blocks.contains(where: { $0.id == id }) else { return }
        let payload = DiffPatchBlock(
            workspaceRoot: workspaceRoot,
            patch: patch,
            files: files,
            status: status,
            errorMessage: nil
        )
        let block = ChatBlock(id: id, kind: .diffPatch, text: "", diffPatch: payload)
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
        guard let index = blocks.firstIndex(where: { $0.id == id }),
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
            do {
                try await diffPatchService.apply(
                    patch: payload.patch,
                    workspaceRoot: payload.workspaceRoot,
                    reverse: true
                )
                updateDiffPatchBlock(id: id, status: .undone)
            } catch {
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
