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
    public var inspectedGitCommit: GitCommitBlock?

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
    private(set) var dynamicProfiles: [UserDynamicProfile] = []
    private(set) var activeDynamicProfileID: UUID?

    var activeDynamicProfile: UserDynamicProfile? {
        activeDynamicProfileID.flatMap { id in dynamicProfiles.first(where: { $0.id == id }) }
    }

    var activeBaseModelID: ProfileBaseModelID {
        if activeBackend == .foundationApple { return .onDevice }
        return ProfileBaseModelID(rawValue: activeRemoteModelID) ?? .llama
    }

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
    /// The Apple on-device model doesn't support reasoning. Remote models are
    /// resolved from their declared capabilities and validated again by the
    /// session factory before the profile is built.
    public var reasoningLevel: ContextOptions.ReasoningLevel? {
        guard activeBackend != .foundationApple else { return nil }
        return reasoningLevel(for: activeRemoteModel)
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
                activeDynamicProfileID = nil
                UserDefaults.standard.removeObject(forKey: "activeDynamicProfileID")
                composerModel = "Apple · Orchestrator"
                rebuildSession(discardingCapabilityContext: true)
            } else {
                // Switching back to standalone: rebuild without the tool;
                // keep whatever backend was active (Apple stays Apple, Llama stays Llama).
                composerModel = activeBackend.rawValue
                rebuildSession(discardingCapabilityContext: true)
            }
        }
    }

    // Diff inspector state (persiste oltre il ciclo di vita della view)
    var diffSections: [FileDiffSection] = []
    var isLoadingDiffs = false
    var diffLoadError: String?
    private var diffLoadID: UUID?

    // Git branch state
    var isGitRepository = false
    var currentBranch: String = ""
    var availableBranches: [String] = []

    private let gitService = GitDiffService()
    private let diffPatchService = DiffPatchService()
    private let conversationRepository: any ConversationRepository

    public func reloadDiffs() async {
        guard !workspaceRoot.isEmpty else {
            diffLoadID = nil
            diffSections = []
            diffLoadError = nil
            isLoadingDiffs = false
            return
        }

        let requestedWorkspace = workspaceRoot
        let loadID = UUID()
        diffLoadID = loadID
        isLoadingDiffs = true
        diffLoadError = nil
        diffSections = []
        defer {
            if diffLoadID == loadID {
                isLoadingDiffs = false
            }
        }

        let url = URL(fileURLWithPath: requestedWorkspace)
        let sections = await FileDiffSection.fromGit(at: url, service: gitService)

        guard !Task.isCancelled,
              workspaceRoot == requestedWorkspace,
              diffLoadID == loadID else { return }

        if let sections {
            diffSections = sections
            diffLoadError = nil
        } else {
            diffSections = []
            diffLoadError = "Not a git repository or git unavailable"
        }
    }

    public func refreshGitBranches() async {
        guard !workspaceRoot.isEmpty else {
            isGitRepository = false
            currentBranch = ""
            availableBranches = []
            return
        }

        let requestedWorkspace = workspaceRoot
        let url = URL(fileURLWithPath: requestedWorkspace)
        let isRepository = await gitService.isGitRepository(at: url)
        guard workspaceRoot == requestedWorkspace, !Task.isCancelled else { return }
        guard isRepository else {
            isGitRepository = false
            currentBranch = ""
            availableBranches = []
            return
        }
        let branch = await gitService.currentBranch(at: url)
        let branches = await gitService.allBranches(at: url)

        guard workspaceRoot == requestedWorkspace, !Task.isCancelled else { return }

        isGitRepository = true
        currentBranch = branch ?? ""
        availableBranches = branches
    }

    public func refreshGitAfterToolMutation() async {
        await refreshGitBranches()
        await reloadDiffs()
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
    private var activeProductGuidePresentation: ProductGuideBlock?
    private var activeCompletedRootWrite: String?
    private var activeAssistantPlaceholderID: String?
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
        do {
            try ProductDocumentationStore.live.installBundledDocumentation()
        } catch {
            print("[TurboCode] Documentation installation failed: \(error.localizedDescription)")
        }
    }
    public convenience init() {
        self.init(conversationRepository: DiskConversationRepository())
    }

    init(conversationRepository: any ConversationRepository) {
        self.conversationRepository = conversationRepository
        let loadedProfiles = (try? DynamicProfileStore.live.load()) ?? []
        let savedProfileID = UserDefaults.standard.string(forKey: "activeDynamicProfileID")
            .flatMap(UUID.init(uuidString:))
        let savedProfile = loadedProfiles.first(where: { $0.id == savedProfileID })
        // Restore orchestrator mode from UserDefaults
        let saved = UserDefaults.standard.string(forKey: "orchestratorMode")
            ?? OrchestratorMode.standalone.rawValue
        let mode = OrchestratorMode(rawValue: saved) ?? .standalone
        let selectedID = savedProfile?.baseModelID.remoteModelID
            ?? UserDefaults.standard.string(forKey: "activeRemoteModelID")
            ?? "llama"
        let initialRemote = RemoteModelConfig.defaults.first(where: {
            $0.id == selectedID && Self.hasCredential(for: $0)
        })
            ?? RemoteModelConfig.fallbackLlama
        let restoredProfile = savedProfile.flatMap { profile -> UserDynamicProfile? in
            if profile.baseModelID == .onDevice { return profile }
            return profile.baseModelID.remoteModelID == initialRemote.id ? profile : nil
        }
        self.activeRemoteModelID = initialRemote.id
        self.dynamicProfiles = loadedProfiles
        self.activeDynamicProfileID = mode == .standalone ? restoredProfile?.id : nil

        // Initialise ALL stored properties BEFORE any didSet observers fire.
        // We set orchestratorMode last so that session is already valid.
        self.activeBackend = mode == .orchestrator || restoredProfile?.baseModelID == .onDevice
            ? .foundationApple
            : Self.backend(for: initialRemote.role)
        let initialModel: any LanguageModel = mode == .orchestrator || restoredProfile?.baseModelID == .onDevice
            ? SystemLanguageModel.default
            : ProviderLanguageModel(
                configuration: initialRemote,
                apiKey: initialRemote.credential.flatMap(CredentialStore.value(for:))
            )
        self.session = LanguageModelSession(model: initialModel)
        self.composerModel = mode == .orchestrator
            ? "Apple \u{00B7} Orchestrator"
            : (restoredProfile?.name ?? initialRemote.name)
        if savedProfile != nil, restoredProfile == nil {
            UserDefaults.standard.removeObject(forKey: "activeDynamicProfileID")
        }

        // Now safe — didSet fires and calls rebuildSession() as needed.
        self.orchestratorMode = mode
    }

    /// Switch inference backend and rebuild the session, preserving user and
    /// assistant turns while removing model-specific transport entries.
    /// In orchestrator mode the backend is always Apple on-device;
    /// calling this method has no effect.
    public func switchBackend(to backend: ModelBackend) {
        guard !busy, orchestratorMode == .standalone else { return }
        clearDynamicProfileSelection()
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
        rebuildSession(discardingCapabilityContext: true)
    }

    public func switchRemoteModel(to id: String) {
        guard !busy, orchestratorMode == .standalone,
              let model = remoteModels.first(where: { $0.id == id && $0.enabled }),
              isConfigured(model) else { return }
        clearDynamicProfileSelection()
        selectRemoteModel(model)
        rebuildSession(discardingCapabilityContext: true)
    }

    func selectBuiltInProfile(_ id: ProfileBaseModelID) {
        guard !busy, orchestratorMode == .standalone else { return }
        clearDynamicProfileSelection()
        guard applyBaseModel(id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    func selectDynamicProfile(_ id: UUID) {
        guard !busy, orchestratorMode == .standalone,
              let profile = dynamicProfiles.first(where: { $0.id == id }),
              applyBaseModel(profile.baseModelID) else { return }
        activeDynamicProfileID = profile.id
        UserDefaults.standard.set(profile.id.uuidString, forKey: "activeDynamicProfileID")
        composerModel = profile.name
        rebuildSession(discardingCapabilityContext: true)
    }

    func reloadDynamicProfiles(selecting id: UUID? = nil) {
        do {
            dynamicProfiles = try DynamicProfileStore.live.load()
            let requestedID = id ?? activeDynamicProfileID
            if let requestedID, dynamicProfiles.contains(where: { $0.id == requestedID }) {
                if id != nil || activeDynamicProfileID == requestedID {
                    selectDynamicProfile(requestedID)
                }
            } else if activeDynamicProfileID != nil {
                clearDynamicProfileSelection()
                composerModel = activeBaseModelID.displayName
                rebuildSession(discardingCapabilityContext: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
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
        if let activeDynamicProfile {
            composerModel = activeDynamicProfile.name
        }
        rebuildSession(discardingCapabilityContext: true)
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

    private func applyBaseModel(_ id: ProfileBaseModelID) -> Bool {
        if id == .onDevice {
            activeBackend = .foundationApple
            composerModel = id.displayName
            return true
        }
        guard let remoteID = id.remoteModelID,
              let model = remoteModels.first(where: { $0.id == remoteID && $0.enabled }),
              isConfigured(model) else { return false }
        selectRemoteModel(model)
        return true
    }

    private func clearDynamicProfileSelection() {
        activeDynamicProfileID = nil
        UserDefaults.standard.removeObject(forKey: "activeDynamicProfileID")
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
        remoteModels.first(where: {
            $0.id == agentTuning.orchestrator.delegateModelID
                && $0.enabled
                && isConfigured($0)
        })
            ?? remoteModels.first(where: { $0.enabled && $0.role == .local && isConfigured($0) })
            ?? activeRemoteModel.flatMap { $0.enabled && isConfigured($0) ? $0 : nil }
            ?? remoteModels.first(where: { $0.enabled && isConfigured($0) })
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
        if let activeDynamicProfileID {
            return "profile:\(activeDynamicProfileID.uuidString)"
        }
        return activeBackend == .foundationApple ? activeBackend.rawValue : activeRemoteModelID
    }

    /// Rebuild the session preserving conversation history. Capability changes
    /// keep visible turns but discard stale tool, reasoning, and skill state.
    /// Pass `keepingHistory: false` to start a fresh session (new thread).
    private func rebuildSession(
        keepingHistory: Bool = true,
        discardingCapabilityContext: Bool = false,
        restoringHistory: [Transcript.Entry]? = nil
    ) {
        let history = restoringHistory ?? SessionRebuildHistory.prepare(
            session.transcript,
            keepingHistory: keepingHistory,
            discardingCapabilityContext: discardingCapabilityContext
        )
        if discardingCapabilityContext {
            for name in skillActivations.activeSkillNames {
                skillActivations.deactivate(name)
            }
        }
        let delegateModel = delegateRemoteModel
        let sessionSkills = DynamicProfileRuntimeSelection.skills(
            from: availableSkills,
            profile: activeDynamicProfile
        )
        session = ModelSessionFactory.makeSession(
            configuration: ModelSessionConfiguration(
                backend: activeBackend,
                activeRemoteModel: activeRemoteModel,
                delegateRemoteModel: delegateModel,
                orchestratorMode: orchestratorMode,
                workspaceRoot: workspaceRoot,
                agentTuning: agentTuning,
                availableSkills: sessionSkills,
                activeDynamicProfile: activeDynamicProfile,
                skillActivations: skillActivations,
                reasoningLevel: reasoningLevel,
                delegateReasoningLevel: reasoningLevel(for: delegateModel),
                activeTemperature: temperature(for: activeRemoteModel),
                delegateTemperature: temperature(for: delegateModel),
                dropsCompletedToolCalls: shouldDropCompletedToolCalls
            ),
            history: history,
            events: ModelSessionEvents(
                toolStarted: { [weak self] call, backend in
                    await self?.beginToolActivity(call, backend: backend)
                },
                toolFinished: { [weak self] call, output, backend in
                    await self?.endToolActivity(call, output: output, backend: backend)
                },
                delegationChanged: { [weak self] isDelegating in
                    await MainActor.run { self?.isDelegating = isDelegating }
                }
            )
        )
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
        let snapshot = ConversationSnapshot(
            conversation: thread,
            modelBackend: persistedModelIdentifier,
            blocks: blocks,
            transcript: session.transcript
        )
        do {
            try conversationRepository.save(snapshot)
        } catch {
            print("[TurboCode] Failed to persist session: \(error.localizedDescription)")
        }
    }

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        guard let all = try? conversationRepository.list(),
              !all.isEmpty else { return }
        let existingIDs = Set(threads.map(\.id))
        for snapshot in all where !existingIDs.contains(snapshot.conversation.id) {
            threads.append(snapshot.conversation)
        }
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        guard let snapshot = try? conversationRepository.load(id: id),
              let _ = threads.firstIndex(where: { $0.id == id }) else { return }
        activeThreadId = id
        blocks = snapshot.blocks
        liveReasoning = ""; liveAssistant = ""
        isFirstMessage = blocks.isEmpty
        if let wp = snapshot.conversation.workspace, workspaceRoot != wp {
            workspaceRoot = wp
        }
        restoreModelSelection(snapshot.modelBackend)
        let restoredHistory = snapshot.transcript.map {
            SessionRebuildHistory.prepare(
                $0,
                keepingHistory: true,
                discardingCapabilityContext: false
            )
        } ?? SessionRebuildHistory.fromVisibleBlocks(snapshot.blocks)
        rebuildSession(keepingHistory: false, restoringHistory: restoredHistory)
    }

    private func restoreModelSelection(_ identifier: String) {
        guard orchestratorMode == .standalone else { return }
        if identifier.hasPrefix("profile:"),
           let id = UUID(uuidString: String(identifier.dropFirst("profile:".count))),
           dynamicProfiles.contains(where: { $0.id == id }) {
            selectDynamicProfile(id)
            return
        }
        clearDynamicProfileSelection()
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
        if let storedSessions = try? conversationRepository.list() {
            sessionIDs.formUnion(
                storedSessions
                    .filter { $0.conversation.workspace == path }
                    .map(\.conversation.id)
            )
        }

        var deletionErrors: [String] = []
        for id in sessionIDs {
            do {
                try conversationRepository.delete(id: id)
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
            isGitRepository = false
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
        isGitRepository = false
        currentBranch = ""
        availableBranches = []

        // Save to recent workspaces
        var recent = recentWorkspaces
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recentWorkspaces = Array(recent.prefix(10))
        selectedProject = URL(fileURLWithPath: path).lastPathComponent

        rebuildSession(discardingCapabilityContext: true)
        // The inspector is opt-in: changing workspace must not open it.
        rightPanelMode = nil
        diffSections = []
        Task { await reloadDiffs() }
        Task { await refreshGitBranches() }
    }

    /// Clear the workspace selection.
    public func clearWorkspace() {
        workspaceRoot = ""
        diffLoadID = nil
        diffSections = []
        diffLoadError = nil
        isLoadingDiffs = false
        isGitRepository = false
        currentBranch = ""
        availableBranches = []
        rebuildSession(discardingCapabilityContext: true)
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
        rebuildSession(discardingCapabilityContext: true)
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
        rebuildSession(discardingCapabilityContext: true)
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
        activeAssistantPlaceholderID = placeholderId

        runtimeStatus = .ready
        error = nil
        var accumulatedText = ""
        activeProductGuidePresentation = nil
        activeCompletedRootWrite = nil

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
                    if activeBackend == .foundationApple,
                       OnDeviceStreamingGuard.isPathological(snapshot.content) {
                        throw OnDeviceStreamingGuard.Failure.repetitiveOutput
                    }
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
            let productGuidePresentation = activeProductGuidePresentation
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.remove(at: i)
                } else {
                    blocks[i] = ChatBlock(
                        id: placeholderId,
                        kind: productGuidePresentation == nil ? .assistant : .productGuide,
                        text: finalText,
                        model: composerModel,
                        productGuide: productGuidePresentation
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
        } catch OnDeviceStreamingGuard.Failure.repetitiveOutput {
            diagnosticsOutcome = .failed
            let stoppedText = activeCompletedRootWrite.map { "Created `\($0)`." }
                ?? "Response stopped because the on-device model began repeating output. Please retry."
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                blocks[i] = ChatBlock(
                    id: placeholderId,
                    kind: .assistant,
                    text: stoppedText,
                    model: composerModel
                )
            }
            liveReasoning = ""
            liveAssistant = ""
            isDelegating = false
            toolActivities.removeAll()
            self.error = nil
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
        if activeAssistantPlaceholderID == placeholderId {
            activeAssistantPlaceholderID = nil
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
            let resolution = await ToolApprovalRegistry.shared.approve(id: request.id)
            if resolution.requiresModelFollowUp {
                await sendInternalMessageWhenIdle("""
                [User approved tool action]
                Operation: \(request.operation)
                Path: \(request.path)
                Result:
                \(resolution.result)
                """)
            }
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
            let resolution = await ToolApprovalRegistry.shared.reject(id: request.id)
            if resolution.requiresModelFollowUp {
                await sendInternalMessageWhenIdle("[User rejected tool action: \(request.summary). Do NOT perform this action.]")
            }
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

    public func dismissApproval(id: String) {
        if pendingApproval?.id == id {
            advanceApprovalQueue()
        } else {
            queuedApprovals.removeAll(where: { $0.id == id })
        }
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
        if call.toolName == "turbocode_guide" {
            let text = output.segments.compactMap { segment -> String? in
                if case .text(let value) = segment { return value.content }
                return nil
            }.joined()
            activeProductGuidePresentation = ProductGuideBlock(toolOutput: text)
        }
        if call.toolName == "write_ondevice" {
            let text = output.segments.compactMap { segment -> String? in
                if case .text(let value) = segment { return value.content }
                return nil
            }.joined()
            if text.hasPrefix("WRITE_COMPLETE: ") {
                activeCompletedRootWrite = String(text.dropFirst("WRITE_COMPLETE: ".count))
            }
        }
        if let presentation = ToolPresentationRouter.presentation(for: call, output: output) {
            presentToolPresentation(presentation)
        }
        toolActivities.removeAll { $0.id == call.id }
    }

    private func presentToolPresentation(_ presentation: ToolPresentation) {
        let block: ChatBlock
        switch presentation {
        case .workspaceListing(let listing):
            block = ChatBlock(
                id: "workspace-listing-\(listing.toolCallID)",
                kind: .workspaceListing,
                text: listing.path,
                workspaceListing: listing
            )
        }
        guard !blocks.contains(where: { $0.id == block.id }) else { return }
        if let placeholderID = activeAssistantPlaceholderID,
           let index = blocks.firstIndex(where: { $0.id == placeholderID }) {
            blocks.insert(block, at: index)
        } else {
            blocks.append(block)
        }
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

    public func presentGitCommit(_ receipt: GitCommitBlock) {
        let block = ChatBlock(kind: .gitCommit, text: "", gitCommit: receipt)
        if let placeholderIndex = blocks.lastIndex(where: { $0.kind == .assistant && $0.text.isEmpty }) {
            blocks.insert(block, at: placeholderIndex)
        } else {
            blocks.append(block)
        }
    }

    public func reviewGitCommit(_ id: String) {
        guard let receipt = blocks.first(where: { $0.id == id })?.gitCommit else { return }
        inspectedGitCommit = receipt
        rightPanelMode = .commit
    }

    public func undoGitCommit(_ id: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              var receipt = blocks[index].gitCommit,
              receipt.status == .committed else { return }

        receipt.status = .undoing
        receipt.errorMessage = nil
        blocks[index].gitCommit = receipt

        Task {
            if let failure = await gitService.undoCommit(
                expectedHash: receipt.hash,
                at: URL(fileURLWithPath: receipt.workspaceRoot)
            ) {
                receipt.status = .failed
                receipt.errorMessage = failure
            } else {
                receipt.status = .undone
                receipt.errorMessage = nil
            }
            if let currentIndex = blocks.firstIndex(where: { $0.id == id }) {
                blocks[currentIndex].gitCommit = receipt
            }
            if inspectedGitCommit?.hash == receipt.hash {
                inspectedGitCommit = receipt
            }
            await refreshGitAfterToolMutation()
            if let threadID = activeThreadId {
                await persistSession(for: threadID)
            }
        }
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
        case "remove_file":
            return "Preparing file removal"
        case "git":
            let operation = try? call.arguments.value(String.self, forProperty: "operation")
            return operation.map { "Git \($0)" } ?? "Working with Git"
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
        case "turbocode_guide":
            return "Consulting TurboCode Guide"
        case "list_workspace":
            let path = try? call.arguments.value(String.self, forProperty: "path")
            return path == "." ? "Browsing workspace" : "Browsing \(path ?? "workspace")"
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

/// Stops a known Foundation Models degeneration before hundreds of empty
/// Markdown fences are rendered and persisted. It deliberately requires both
/// substantial output and extremely low information density.
nonisolated enum OnDeviceStreamingGuard {
    enum Failure: Error {
        case repetitiveOutput
    }

    static func isPathological(_ text: String) -> Bool {
        guard text.count >= 160 else { return false }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fenceCount = lines.lazy.filter { $0.hasPrefix("```") }.count
        guard fenceCount >= 12 else { return false }

        let content = lines.filter { !$0.hasPrefix("```") }.joined()
        return content.count * 5 < text.count
    }
}

/// Prepares conversation history for a newly constructed model session. The
/// destination profile always supplies fresh instructions and tool definitions.
nonisolated enum SessionRebuildHistory {
    static func prepare(
        _ transcript: Transcript,
        keepingHistory: Bool,
        discardingCapabilityContext: Bool
    ) -> [Transcript.Entry] {
        guard keepingHistory else { return [] }
        return transcript.filter { entry in
            switch entry {
            case .instructions:
                return false
            case .toolCalls, .toolOutput, .reasoning:
                return !discardingCapabilityContext
            case .prompt, .response:
                return true
            @unknown default:
                return true
            }
        }
    }

    /// Best-effort migration for sessions saved before semantic transcripts
    /// were persisted. Presentation-only blocks are intentionally ignored.
    static func fromVisibleBlocks(_ blocks: [ChatBlock]) -> [Transcript.Entry] {
        blocks.compactMap { block in
            let segment = Transcript.Segment.text(
                Transcript.TextSegment(content: block.text)
            )
            switch block.kind {
            case .user:
                return .prompt(Transcript.Prompt(segments: [segment]))
            case .assistant, .productGuide:
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .response(Transcript.Response(assetIDs: [], segments: [segment]))
            case .reasoning, .tool, .approval, .review, .compaction,
                    .diffPatch, .gitCommit, .workspaceListing:
                return nil
            }
        }
    }
}

/// Resolves disk skills at the same capability boundary as dynamic tools.
nonisolated enum DynamicProfileRuntimeSelection {
    static func skills(
        from available: [TurboCodeSkillDefinition],
        profile: UserDynamicProfile?
    ) -> [TurboCodeSkillDefinition] {
        guard let profile else { return available }
        let allowed = Set(profile.skillIDs)
        return available.filter { allowed.contains($0.name) }
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
        case "removeFile": return "Delete \(item)"
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
