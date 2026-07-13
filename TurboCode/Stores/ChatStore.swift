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

    // First-message layout state — true on launch and new chat,
    // becomes false after the first message is sent
    public var isFirstMessage: Bool = true

    // Pending user approval for a destructive tool operation
    public var pendingApproval: ApprovalRequest? = nil

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
    /// Returns `nil` for the Apple on-device model (which doesn't support it).
    public var reasoningLevel: ContextOptions.ReasoningLevel? {
        guard activeBackend != .foundationApple else { return nil }
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
    /// Configuration for the remote Llama server (OpenAI-compatible endpoint).
    private let llamaModelName: String
    private let llamaBaseURL: URL
    private let llamaTemperature: Double

    public init() {
        self.llamaModelName = "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf"
        self.llamaBaseURL = URL(string: "http://127.0.0.1:8080/v1")!
        self.llamaTemperature = 0.6

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
            workspaceTools += [ReadFileTool(), GrepTool(), FileSystemTool(workspaceRoot: workspaceRoot)]
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
                delegateInstructions: baseInstructions
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

            For EVERYTHING else — reading files, writing or editing files, generating code, git operations, grep/searching, complex analysis, or any multi-step task — you MUST use `call_powerful_model` to delegate to the powerful coding model. The powerful model has all the tools it needs (read_file, grep, file_system for write/delete/copy/move).

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
            If the powerful model's response contains "ACTION REQUIRED", do NOT synthesise or rephrase it. Pass it through verbatim to the user and ask them to confirm or reject.
            """
            effectiveInstructions = text
        } else {
            tools = workspaceTools
            effectiveInstructions = baseInstructions
        }

        // ── Build the session via DynamicProfile ──
        let activeModel: any LanguageModel = activeBackend == .foundationApple
            ? SystemLanguageModel.default
            : ChatCompletionsLanguageModel(name: llamaModelName, url: llamaBaseURL)

        if isOrchestrating {
            // Orchestrator profile: Apple + lifecycle callbacks for delegation detection
            session = LanguageModelSession(
                profile: TurboCodeDynamicProfile(
                    instructions: effectiveInstructions,
                    tools: tools,
                    model: activeModel,
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
                    reasoningLevel: reasoningLevel
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
        rightPanelMode = .changes
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isFirstMessage = false

        blocks.append(ChatBlock(kind: .user, text: text))

        let placeholderId = UUID().uuidString
        blocks.append(ChatBlock(id: placeholderId, kind: .assistant, text: "", model: composerModel))

        busy = true
        runtimeStatus = .ready
        error = nil

        do {
            let stream = session.streamResponse(to: text)
            var accumulatedText = ""
            // Delegation detection is handled by TurboCodeDynamicProfile's
            // onToolCall / onToolOutput lifecycle callbacks — no scanning needed.

            for try await snapshot in stream {
                // Fast path: update liveAssistant for quick UI feedback
                if !snapshot.content.isEmpty {
                    accumulatedText = snapshot.content
                    liveAssistant = accumulatedText
                }

                // Process transcript entries for reasoning and ACTION REQUIRED
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
                        if text.contains("ACTION REQUIRED") {
                            pendingApproval = ApprovalRequest(
                                summary: text.replacingOccurrences(of: "\u{26A0}\u{FE0F} ACTION REQUIRED: ", with: "")
                            )
                        }
                    }
                }
            }

            // Stream ended: finalize the assistant block.
            // Reset delegation state once streaming is done.
            isDelegating = false
            let finalText = accumulatedText.isEmpty ? liveReasoning : accumulatedText
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                blocks[i] = ChatBlock(
                    id: placeholderId,
                    kind: .assistant,
                    text: finalText,
                    model: composerModel
                )
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
        } catch {
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

        busy = false
    }

    public func interrupt() {
        busy = false
    }

    /// Approve a pending destructive operation — executes directly via FileManager,
    /// then informs the model that the action was completed.
    public func approveAction() {
        guard let request = pendingApproval else { return }
        pendingApproval = nil

        let summary = request.summary

        // Extract the path from single quotes in the summary
        let path: String? = {
            guard let start = summary.firstIndex(of: "'"),
                  let end = summary[start...].dropFirst().firstIndex(of: "'") else { return nil }
            return String(summary[summary.index(after: start)..<end])
        }()

        guard let filePath = path else {
            Task { await sendMessage("[User approved: \(summary)]") }
            return
        }

        do {
            if summary.contains("deletion") || summary.contains("Confirm deletion") {
                try FileManager.default.removeItem(atPath: filePath)
                Task { await sendMessage("[User approved and completed: deleted '\(filePath)']") }
            } else if summary.contains("overwrite") || summary.contains("already exists") {
                // Overwrite requires content — not available here, tell model to retry
                Task { await sendMessage("[User approved: overwrite '\(filePath)'. Please retry the write operation.]") }
            } else {
                Task { await sendMessage("[User approved: \(summary)]") }
            }
        } catch {
            Task { await sendMessage("[Action failed: \(error.localizedDescription)]") }
        }
    }

    /// Reject a pending destructive operation.
    public func rejectAction() {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        Task {
            await sendMessage("[User rejected: \(request.summary). Do NOT perform this action.]")
        }
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

// MARK: - Pending Approval

public struct ApprovalRequest: Sendable {
    public let summary: String
}
