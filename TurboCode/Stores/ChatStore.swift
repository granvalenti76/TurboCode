import Foundation
import Observation
import SwiftUI
import FoundationModels
import LlamaModelExecutor

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
    // Threads
    public var threads: [Thread] = []
    public var activeThreadId: String?
    public var threadSearch: String = ""
    public var showArchivedThreads: Bool = false

    // Timeline
    public var blocks: [ChatBlock] = []
    public var liveReasoning: String = ""
    public var liveAssistant: String = ""

    // Composer
    public var composerModel: String = "auto"
    public var composerProviderId: String = ""
    public var composerMode: ThreadMode = .agent
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

    // Backend
    public var activeBackend: ModelBackend = .llamaServer

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
    private var llamaModel: LlamaModel
    private var session: LanguageModelSession

    public init() {
        let config = LlamaConfiguration(
            modelName: "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
            temperature: 0.0,
            baseURL: LlamaConfiguration.defaultURL
        )
        let m = LlamaModel(configuration: config)
        self.llamaModel = m
        self.session = LanguageModelSession(model: m)
        self.composerModel = ModelBackend.llamaServer.rawValue
    }

    /// Switch inference backend and rebuild the session,
    /// preserving the full conversation transcript.
    public func switchBackend(to backend: ModelBackend) {
        activeBackend = backend
        composerModel = backend.rawValue
        rebuildSession()
    }

    /// Build the instructions text from current workspace.
    private var baseInstructions: String {
        var text = "You are TurboCode, an expert AI coding assistant."
        if !workspaceRoot.isEmpty {
            text += "\nThe current workspace is at: \(workspaceRoot)"
            text += "\nYou have access to the following tools: read_file, grep, file_system."
            text += "\nAll file operations are restricted to the workspace directory."
            text += "\nNEVER access files outside the workspace."
            text += "\nUse these tools when you need to interact with the workspace."
        }
        return text
    }

    /// Rebuild the session preserving conversation history.
    private func rebuildSession() {
        // Capture existing transcript so we don't lose context
        let history = Array(session.transcript)

        // Tools are loaded conditionally: file operations require a workspace
        var tools: [any Tool] = []
        if !workspaceRoot.isEmpty {
            tools += [ReadFileTool(), GrepTool(), FileSystemTool(workspaceRoot: workspaceRoot)]
        }

        switch activeBackend {
        case .llamaServer:
            session = LanguageModelSession(
                model: llamaModel,
                dynamicInstructions: SessionInstructions(
                    instructionsText: baseInstructions,
                    tools: tools
                ),
                history: history
            )
        case .foundationApple:
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                dynamicInstructions: SessionInstructions(
                    instructionsText: baseInstructions,
                    tools: tools
                ),
                history: history
            )
        }
    }

    // MARK: - Actions

    public func selectThread(_ id: String) async {
        activeThreadId = id
    }

    public func createThread(title: String = "New Chat", mode: ThreadMode = .agent) async {
        let thread = Thread(title: title, mode: mode)
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
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
        workspaceRoot = url.path
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

        blocks.append(ChatBlock(kind: .user, text: text))

        let placeholderId = UUID().uuidString
        blocks.append(ChatBlock(id: placeholderId, kind: .assistant, text: "", model: composerModel))

        busy = true
        runtimeStatus = .ready
        error = nil

        do {
            let stream = session.streamResponse(to: text)
            var accumulatedText = ""

            for try await snapshot in stream {
                // Fast path: update liveAssistant for quick UI feedback
                // (re-renders only the live block, not the entire List)
                if !snapshot.content.isEmpty {
                    accumulatedText = snapshot.content
                    liveAssistant = accumulatedText
                }

                // Reasoning from transcript — use = not += to avoid duplicates
                // (transcript already has accumulated text)
                for entry in snapshot.transcriptEntries {
                    if case .reasoning(let reasoning) = entry {
                        for segment in reasoning.segments {
                            if case .text(let t) = segment {
                                liveReasoning = t.content
                            }
                        }
                    }
                }
            }

            // Stream ended: finalize the assistant block.
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

    public var sortedThreads: [Thread] {
        let q = threadSearch.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = threads.filter { t in showArchivedThreads ? true : !t.isArchived }
            .filter { t in q.isEmpty ? true : t.title.lowercased().contains(q) }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }
}

// MARK: - DynamicInstructions for session setup

/// Wraps instructions text and tools into a single DynamicInstructions value,
/// so LanguageModelSession can be initialized with both history and tools.
private struct SessionInstructions: DynamicInstructions {
    let instructionsText: String
    let tools: [any Tool]

    var body: some DynamicInstructions {
        Instructions(instructionsText)
        tools
    }
}

// MARK: - Runtime status

public enum RuntimeStatus: String, Sendable, Hashable {
    case disconnected; case connecting; case ready; case error
}
public enum RuntimeConnectionState: String, Sendable, Hashable {
    case disconnected; case connecting; case ready
}
