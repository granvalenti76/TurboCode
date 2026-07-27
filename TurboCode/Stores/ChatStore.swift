import Foundation
import AppKit
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
    case codex = "Codex"
}

/// Captures a menu choice while the asynchronous Codex handoff completes.
/// Storing identifiers rather than closures keeps the transition isolated to
/// ChatStore's main actor.
private enum TurboCodeProfileSelection {
    case backend(ModelBackend)
    case remoteModel(String)
    case builtIn(ProfileBaseModelID)
    case dynamic(UUID)
}

// MARK: - Central ChatStore

@MainActor
@Observable
public final class ChatStore {
    /// Shared instance used by App Intents (runs in-process on macOS).
    public static var shared: ChatStore!

    // MARK: - Properties
    // Threads
    // Forwarding keeps existing sidebar and test call sites stable while
    // ConversationStore owns the observable catalog.
    public var threads: [Conversation] {
        get { conversationStore.threads }
        set { conversationStore.threads = newValue }
    }
    public var activeThreadId: String? {
        get { conversationStore.activeThreadID }
        set { conversationStore.activeThreadID = newValue }
    }
    public var threadSearch: String {
        get { conversationStore.search }
        set { conversationStore.search = newValue }
    }
    public var showArchivedThreads: Bool {
        get { conversationStore.showsArchivedThreads }
        set { conversationStore.showsArchivedThreads = newValue }
    }

    // Timeline
    public var blocks: [ChatBlock] = []
    public var liveReasoning: String = ""
    public var liveAssistant: String = ""
    // Forwarded during the refactor so timeline views keep their current API.
    public var toolActivities: [ToolActivity] {
        get { toolInteractionStore.activities }
        set { toolInteractionStore.activities = newValue }
    }
    public var activeToolActivity: ToolActivity? {
        toolInteractionStore.activeActivity
    }

    // First-message layout state — true on launch and new chat,
    // becomes false after the first message is sent
    public var isFirstMessage: Bool = true

    // Pending user approval for a destructive tool operation
    public var pendingApproval: ApprovalRequest? {
        get { toolInteractionStore.pendingApproval }
        set { toolInteractionStore.pendingApproval = newValue }
    }

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
    /// Custom Profiles is a document-modal presentation, not a replacement for
    /// the workbench destination underneath it.
    public var isCustomProfilesPresented: Bool = false
    public var settingsSection: SettingsSection = .general

    // Sidebar
    public var leftSidebarCollapsed: Bool = false
    public var leftSidebarWidth: CGFloat = 304

    // Right panel
    public var rightPanelMode: RightPanelMode?
    public var rightPanelVisible: Bool { rightPanelMode != nil }
    public var rightSidebarWidth: CGFloat = 360
    public var inspectedGitCommit: GitCommitBlock?
    public var inspectedWorkspaceListingID: String?
    public var inspectedWorkspaceListing: WorkspaceListingBlock? {
        guard let inspectedWorkspaceListingID else { return nil }
        return blocks.first(where: { $0.id == inspectedWorkspaceListingID })?.workspaceListing
    }

    // Terminal
    public var terminalOpen: Bool = false
    public var terminalHeight: CGFloat = 360

    // Workspace
    // Forwarding preserves the public view API while WorkspaceStore owns the
    // observable state and Git-derived values.
    public var workspaceRoot: String {
        get { workspaceStore.root }
        set { workspaceStore.root = newValue }
    }
    public var workspaceLabel: String { workspaceStore.label }

    public var recentWorkspaces: [String] {
        get { workspaceStore.recentWorkspaces }
        set { workspaceStore.recentWorkspaces = newValue }
    }

    public var selectedProject: String? {
        get { workspaceStore.selectedProject }
        set { workspaceStore.selectedProject = newValue }
    }

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
        if activeBackend == .codex { return true }
        return activeBackend != .foundationApple
            && (activeRemoteModel?.supportsReasoning ?? false)
    }

    var codexConnectionState: CodexConnectionState = .idle
    var codexModel: CodexModelDescriptor?
    var codexModels: [CodexModelDescriptor] = []
    private var preferredCodexModelID: String =
        UserDefaults.standard.string(forKey: "codexModelID")
            ?? CodexAppServerClient.lunaModelID
    var codexLoginURL: URL?
    var codexReasoningEffort: CodexReasoningEffort =
        UserDefaults.standard.string(forKey: "codexReasoningEffort")
            .flatMap(CodexReasoningEffort.init(rawValue:))
        ?? .medium

    var codexReasoningOptions: [CodexReasoningOption] {
        codexModel?.supportedReasoningEfforts
            ?? CodexReasoningEffort.allCases.map {
                CodexReasoningOption(reasoningEffort: $0, description: "")
            }
    }

    var codexDisplayName: String {
        codexModel?.displayName
            ?? UserDefaults.standard.string(forKey: "codexModelDisplayName")
            ?? "Luna"
    }

    var activeProfileCanSend: Bool {
        guard activeBackend == .codex else { return true }
        if case .ready = codexConnectionState { return true }
        return false
    }

    // Shared activation state for the current session profile.
    public let skillActivations = SkillActivations()
    private(set) var availableSkills: [TurboCodeSkillDefinition] = []

    /// Maps the persisted ReasoningEffort to FoundationModels' ReasoningLevel.
    /// The Apple on-device model doesn't support reasoning. Remote models are
    /// resolved from their declared capabilities and validated again by the
    /// session factory before the profile is built.
    public var reasoningLevel: ContextOptions.ReasoningLevel? {
        guard activeBackend != .foundationApple,
              activeBackend != .codex else { return nil }
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

    // Workspace/Git state remains forwarded until views adopt WorkspaceStore.
    var diffSections: [FileDiffSection] { workspaceStore.diffSections }
    var isLoadingDiffs: Bool { workspaceStore.isLoadingDiffs }
    var diffLoadError: String? { workspaceStore.diffLoadError }
    var isGitRepository: Bool { workspaceStore.isGitRepository }
    var currentBranch: String { workspaceStore.currentBranch }
    var availableBranches: [String] { workspaceStore.availableBranches }

    private let workspaceStore: WorkspaceStore
    private let conversationStore: ConversationStore
    private let toolInteractionStore: ToolInteractionStore
    /// Retained temporarily for commit-receipt undo, which still coordinates
    /// timeline mutation and persistence inside ChatStore.
    private let gitService: any GitRepositoryServicing
    private let diffPatchService: any DiffPatchApplying

    public func reloadDiffs() async {
        await workspaceStore.reloadDiffs()
    }

    public func refreshGitBranches() async {
        await workspaceStore.refreshGitBranches()
    }

    public func refreshGitAfterToolMutation() async {
        await workspaceStore.refreshGitAfterToolMutation()
    }

    /// Switch to a different git branch. Refreshes state afterwards.
    public func switchToBranch(_ branch: String) async {
        await workspaceStore.switchToBranch(branch)
    }

    // Session — recreated when backend or workspace changes
    private var session: LanguageModelSession
    /// Codex owns a separate agent loop and authentication lifecycle. It is not
    /// adapted into LanguageModelSession, which remains the runtime for Llama,
    /// PCC, DeepSeek and the Apple on-device model.
    @ObservationIgnored private let codexClient = CodexAppServerClient()
    @ObservationIgnored private var codexThreadIDs: [String: String] = [:]
    /// App Server reports both cumulative traffic and the current context
    /// footprint. Handoff decisions use the latter to avoid double-counting
    /// the repeated input prefix across turns.
    @ObservationIgnored private var codexTokenUsageByThread: [
        String: CodexTokenUsage
    ] = [:]
    /// Context imported from TurboCode remains turn-scoped application data,
    /// so it never masquerades as a user-authored Codex message.
    @ObservationIgnored private var codexImportedContexts: [String: String] = [:]
    /// The boundary prevents a later return to Codex from re-importing the
    /// portion of the timeline that its own thread already knows.
    @ObservationIgnored private var codexHandoffBoundaryBlockIDs: [
        String: String
    ] = [:]
    /// Bridges Codex JSON-RPC approvals to the same review UI used by native
    /// TurboCode tools. Dynamic tools are registered with App Server separately
    /// and execute the concrete TurboCode implementations.
    @ObservationIgnored private var codexApprovals: [
        String: CodexApprovalRequest
    ] = [:]

    // The currently running response task. Keeping the handle makes the Stop
    // button cancel the actual model stream rather than only changing the UI.
    private var responseTask: Task<Void, Never>?
    private var activeDiagnosticsRunID: String?
    private var activeEditGroupID: String?
    private var activeProductGuidePresentation: ProductGuideBlock?
    private var activeCompletedRootWrite: String?
    private var activeAssistantPlaceholderID: String?
    /// Listings produced during the active turn are retained only long enough
    /// to remove a model-generated echo from the final assistant text.
    private var activeWorkspaceListingPresentations: [WorkspaceListingBlock] = []
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

    init(
        conversationRepository: any ConversationRepository,
        gitService: any GitRepositoryServicing = GitDiffService(),
        diffPatchService: any DiffPatchApplying = DiffPatchService()
    ) {
        self.conversationStore = ConversationStore(repository: conversationRepository)
        self.workspaceStore = WorkspaceStore(gitService: gitService)
        self.toolInteractionStore = ToolInteractionStore()
        self.gitService = gitService
        self.diffPatchService = diffPatchService
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
        if backend == .codex {
            Task { await selectCodexProfile() }
            return
        }
        if activeBackend == .codex {
            beginCodexHandoff(to: .backend(backend))
            return
        }
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
        if activeBackend == .codex {
            beginCodexHandoff(to: .remoteModel(id))
            return
        }
        clearDynamicProfileSelection()
        selectRemoteModel(model)
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Selects Codex immediately, then verifies ChatGPT authentication and
    /// Luna availability in the background. Connection failure is a runtime
    /// state, not a reason to silently revert the user's menu selection.
    func selectCodexProfile(modelID: String? = nil) async {
        guard !busy, orchestratorMode == .standalone else { return }
        if let modelID {
            preferredCodexModelID = modelID
            UserDefaults.standard.set(modelID, forKey: "codexModelID")
        }
        let isEnteringFromTurboCode = activeBackend != .codex
        if isEnteringFromTurboCode, let turboThreadID = activeThreadId {
            // Import only turns created since Codex last handed control back.
            // On the first switch the absent boundary intentionally selects
            // the entire useful visible conversation.
            let context = RuntimeContextHandoff.render(
                blocks: blocks,
                after: codexHandoffBoundaryBlockIDs[turboThreadID]
            )
            if !context.isEmpty {
                codexImportedContexts[turboThreadID] = context
            }
        }
        clearDynamicProfileSelection()
        activeBackend = .codex
        composerModel = "Codex · \(codexDisplayName)"
        codexConnectionState = .connecting
        error = nil

        do {
            try await connectCodexProfile()
        } catch CodexAppServerError.chatGPTLoginRequired {
            codexConnectionState = .signedOut
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
            codexConnectionState = .signedOut
            self.error = nil
        } catch {
            codexConnectionState = .failed(error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    /// Rechecks the App Server and Luna catalog without changing the selected
    /// profile. This is used by the visible Retry action after runtime errors.
    func retryCodexConnection() {
        guard activeBackend == .codex else { return }
        Task { await selectCodexProfile() }
    }

    /// Starts ChatGPT OAuth through App Server, opens the system default
    /// browser, and automatically finishes setup when the callback arrives.
    func signInToCodex() {
        guard activeBackend == .codex else { return }
        Task {
            codexConnectionState = .authenticating
            error = nil
            do {
                let login = try await codexClient.startChatGPTLogin()
                codexLoginURL = login.authorizationURL
                guard NSWorkspace.shared.open(login.authorizationURL) else {
                    throw CodexAppServerError.loginFailed(
                        "The authorization page could not be opened."
                    )
                }
                try await codexClient.waitForChatGPTLogin(id: login.id)
                codexConnectionState = .connecting
                try await connectCodexProfile()
                codexLoginURL = nil
            } catch {
                codexConnectionState = .failed(error.localizedDescription)
                self.error = error.localizedDescription
            }
        }
    }

    func reopenCodexLoginPage() {
        guard let codexLoginURL else { return }
        if !NSWorkspace.shared.open(codexLoginURL) {
            error = "The Codex authorization page could not be opened."
        }
    }

    private func connectCodexProfile() async throws {
        let snapshot = try await codexClient.prepareCodex(
            selectedModelID: preferredCodexModelID
        )
        codexModels = snapshot.models
        codexModel = snapshot.selectedModel
        preferredCodexModelID = snapshot.selectedModel.id
        UserDefaults.standard.set(
            snapshot.selectedModel.id,
            forKey: "codexModelID"
        )
        UserDefaults.standard.set(
            snapshot.selectedModel.displayName,
            forKey: "codexModelDisplayName"
        )
        composerModel = "Codex · \(snapshot.selectedModel.displayName)"
        if !snapshot.selectedModel.supportedReasoningEfforts.contains(where: {
            $0.reasoningEffort == codexReasoningEffort
        }) {
            codexReasoningEffort = snapshot.selectedModel.defaultReasoningEffort
            UserDefaults.standard.set(
                codexReasoningEffort.rawValue,
                forKey: "codexReasoningEffort"
            )
        }
        codexConnectionState = .ready(planType: snapshot.planType)
        error = nil
    }

    func selectBuiltInProfile(_ id: ProfileBaseModelID) {
        guard !busy, orchestratorMode == .standalone else { return }
        if activeBackend == .codex {
            beginCodexHandoff(to: .builtIn(id))
            return
        }
        clearDynamicProfileSelection()
        guard applyBaseModel(id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    func selectDynamicProfile(_ id: UUID) {
        guard !busy, orchestratorMode == .standalone,
              let profile = dynamicProfiles.first(where: { $0.id == id }) else {
            return
        }
        if activeBackend == .codex {
            beginCodexHandoff(to: .dynamic(id))
            return
        }
        guard applyBaseModel(profile.baseModelID) else { return }
        activeDynamicProfileID = profile.id
        UserDefaults.standard.set(profile.id.uuidString, forKey: "activeDynamicProfileID")
        composerModel = profile.name
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Freezes profile selection while Codex prepares any required compact
    /// context. The destination session is installed only after the handoff is
    /// ready, preventing a half-switched UI/runtime state.
    private func beginCodexHandoff(to selection: TurboCodeProfileSelection) {
        guard !busy, activeBackend == .codex else { return }
        busy = true
        Task {
            await completeCodexHandoff(to: selection)
            busy = false
        }
    }

    private func completeCodexHandoff(
        to selection: TurboCodeProfileSelection
    ) async {
        guard let turboThreadID = activeThreadId else {
            _ = applyTurboCodeSelection(selection)
            rebuildSession(discardingCapabilityContext: true)
            return
        }

        let usage = codexTokenUsageByThread[turboThreadID]
        let history: [Transcript.Entry]
        var didSummarize = false
        if RuntimeContextHandoff.shouldSummarizeCodexContext(
            lastTotalTokens: usage?.lastTotalTokens
        ), let summary = try? await requestCodexHandoffSummary(
            turboThreadID: turboThreadID
        ), !summary.isEmpty {
            history = RuntimeContextHandoff.transcript(fromSummary: summary)
            didSummarize = true
        } else if RuntimeContextHandoff.shouldSummarizeCodexContext(
            lastTotalTokens: usage?.lastTotalTokens
        ) {
            // A summary failure must not trap the user in Codex. Keep a bounded
            // recent slice as a deterministic, reviewable fallback.
            let fallback = RuntimeContextHandoff.render(
                blocks: blocks,
                maximumCharacters: 24_000
            )
            history = RuntimeContextHandoff.transcript(fromSummary: fallback)
        } else {
            history = RuntimeContextHandoff.transcript(from: blocks)
        }

        guard applyTurboCodeSelection(selection) else { return }
        if didSummarize {
            blocks.append(
                ChatBlock(
                    kind: .compaction,
                    text: "Codex context summarized for the selected TurboCode profile."
                )
            )
        }
        codexHandoffBoundaryBlockIDs[turboThreadID] = blocks.last?.id
        codexImportedContexts.removeValue(forKey: turboThreadID)
        rebuildSession(
            keepingHistory: false,
            discardingCapabilityContext: true,
            restoringHistory: history
        )
    }

    /// Applies a captured menu choice without rebuilding. This is separated
    /// from the public selectors so a Codex handoff can inject one precise
    /// transcript into the newly configured FoundationModels session.
    private func applyTurboCodeSelection(
        _ selection: TurboCodeProfileSelection
    ) -> Bool {
        clearDynamicProfileSelection()
        switch selection {
        case .backend(let backend):
            if backend == .foundationApple {
                activeBackend = .foundationApple
                composerModel = backend.rawValue
                return true
            }
            guard let model = remoteModels.first(where: {
                $0.enabled && isConfigured($0)
                    && Self.backend(for: $0.role) == backend
            }) else { return false }
            selectRemoteModel(model)
            return true
        case .remoteModel(let id):
            guard let model = remoteModels.first(where: {
                $0.id == id && $0.enabled && isConfigured($0)
            }) else { return false }
            selectRemoteModel(model)
            return true
        case .builtIn(let id):
            return applyBaseModel(id)
        case .dynamic(let id):
            guard let profile = dynamicProfiles.first(where: { $0.id == id }),
                  applyBaseModel(profile.baseModelID) else { return false }
            activeDynamicProfileID = profile.id
            UserDefaults.standard.set(
                profile.id.uuidString,
                forKey: "activeDynamicProfileID"
            )
            composerModel = profile.name
            return true
        }
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
            if orchestratorMode == .standalone,
               activeBackend != .foundationApple,
               activeBackend != .codex {
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

    func setCodexReasoningEffort(_ effort: CodexReasoningEffort) {
        guard codexReasoningOptions.contains(where: {
            $0.reasoningEffort == effort
        }) else { return }
        codexReasoningEffort = effort
        UserDefaults.standard.set(effort.rawValue, forKey: "codexReasoningEffort")
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
        if activeBackend == .codex {
            return ModelBackend.codex.rawValue
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
        if id != activeThreadId { dismissWorkspaceListingInspector() }
        activeThreadId = id
    }

    /// Opens a conversation as one navigation transition. Restoring first keeps
    /// SwiftUI from building the previous, potentially large timeline merely to
    /// replace it one run-loop later when leaving a utility destination.
    public func openThread(_ id: String) async {
        if blocks.isEmpty || activeThreadId != id {
            await restoreSession(id: id)
        } else {
            await selectThread(id)
        }
        setRoute(.chat)
    }

    public func createThread(title: String = "New Chat", mode: ConversationMode = .agent) async {
        dismissWorkspaceListingInspector()
        conversationStore.createThread(
            title: title,
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: mode
        )
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
        let hasOrphanedBlocks = !blocks.isEmpty
        let created = conversationStore.ensureActiveThread(
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: composerMode
        )
        guard created, !hasOrphanedBlocks else { return }

        liveReasoning = ""
        liveAssistant = ""
        isFirstMessage = true
        rebuildSession(keepingHistory: false)
    }

    /// Generates a concise title from the first user prompt using the Apple
    /// on-device model, then applies it to the thread that initiated the request.
    public func generateTitle(from prompt: String, for threadID: String? = nil) async {
        // Capture identity before inference: the active conversation can change
        // while the on-device model streams a title in the background.
        guard let threadID = threadID ?? activeThreadId,
              threads.contains(where: { $0.id == threadID && $0.title == "New Chat" }) else { return }

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
                applyGeneratedTitle(String(clean.prefix(60)), to: threadID)
            }
        } catch {
            // Silently fall back to "New Chat"
        }
    }

    /// Commits an asynchronously generated title by stable identity. Re-finding
    /// the value prevents array insertions or sorting changes from targeting a
    /// different conversation, and preserves a title the user renamed meanwhile.
    func applyGeneratedTitle(_ title: String, to threadID: String) {
        conversationStore.applyGeneratedTitle(title, to: threadID)
    }

    // MARK: - Session Persistence

    /// Saves the active thread and its blocks to `~/.turbocode/sessions/<id>.json`.
    public func persistSession(for threadId: String) async {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
        let snapshot = ConversationSnapshot(
            conversation: thread,
            modelBackend: persistedModelIdentifier,
            blocks: blocks,
            // Codex persists its own rollout. Saving an unrelated Foundation
            // Models transcript here would contaminate later restoration.
            transcript: activeBackend == .codex ? nil : session.transcript
        )
        do {
            try conversationStore.persist(snapshot)
        } catch {
            print("[TurboCode] Failed to persist session: \(error.localizedDescription)")
        }
    }

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        try? conversationStore.restoreCatalog()
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        guard let snapshot = try? conversationStore.snapshot(id: id),
              let _ = threads.firstIndex(where: { $0.id == id }) else { return }
        dismissWorkspaceListingInspector()
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
        if identifier == ModelBackend.codex.rawValue {
            activeBackend = .codex
            composerModel = "Codex · \(codexDisplayName)"
            if let turboThreadID = activeThreadId {
                // Codex thread identifiers are process-local. A restored
                // TurboCode session therefore initializes its fresh App Server
                // thread from the persisted visible timeline.
                let context = RuntimeContextHandoff.render(blocks: blocks)
                if !context.isEmpty {
                    codexImportedContexts[turboThreadID] = context
                }
            }
            Task { await selectCodexProfile() }
            return
        }
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
        conversationStore.renameThread(id: id, title: title)
    }

    public func pinThread(id: String, pinned: Bool) async {
        conversationStore.pinThread(id: id, pinned: pinned)
    }

    public func archiveThread(id: String) async {
        conversationStore.archiveThread(id: id)
    }

    public func deleteThread(id: String) async {
        let deletesActiveThread = activeThreadId == id
        if deletesActiveThread, let responseTask {
            // A cancelled response still performs its final persistence pass.
            // Wait for that pass before deleting, otherwise it can recreate the
            // session file immediately after the user removes the conversation.
            responseTask.cancel()
            await responseTask.value
        }

        let nextThreadID: String?
        do {
            nextThreadID = try conversationStore.deleteThread(id: id)
        } catch {
            // Keep the visible row when durable deletion fails; pretending the
            // operation succeeded would make it reappear on the next launch.
            self.error = "Could not delete the conversation: \(error.localizedDescription)"
            return
        }
        self.error = nil

        // Preserve the selection captured before awaiting an in-flight response:
        // the original transition always cleared that conversation's timeline.
        guard deletesActiveThread else { return }

        activeThreadId = nil
        blocks = []
        liveReasoning = ""
        liveAssistant = ""
        isFirstMessage = true

        if let nextThreadID {
            await restoreSession(id: nextThreadID)
            if activeThreadId == nil {
                // A never-persisted draft has no snapshot to restore but remains
                // a valid next selection with a fresh model session.
                activeThreadId = nextThreadID
                rebuildSession(keepingHistory: false)
            }
        } else {
            rebuildSession(keepingHistory: false)
        }
    }

    /// Removes a workspace from TurboCode and deletes only its persisted chats.
    /// The workspace directory and all project files are left untouched.
    public func removeWorkspace(_ path: String) async {
        let conversationRemoval = conversationStore.removeWorkspace(path)
        let removedActiveWorkspace = workspaceStore.removeWorkspace(path)

        if conversationRemoval.removedActiveThread {
            blocks = []
            liveReasoning = ""
            liveAssistant = ""
            isFirstMessage = true
        }

        if removedActiveWorkspace {
            responseTask?.cancel()
            rightPanelMode = nil
            rebuildSession(keepingHistory: false)
        }

        if !conversationRemoval.deletionErrors.isEmpty {
            let details = conversationRemoval.deletionErrors.joined(separator: "; ")
            error = "Some workspace chats could not be removed: \(details)"
        }
    }

    public func restoreThread(id: String) async {
        conversationStore.restoreThread(id: id)
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
        workspaceStore.selectWorkspace(path)

        rebuildSession(discardingCapabilityContext: true)
        // The inspector is opt-in: changing workspace must not open it.
        rightPanelMode = nil
        Task { await reloadDiffs() }
        Task { await refreshGitBranches() }
    }

    /// Clear the workspace selection.
    public func clearWorkspace() {
        workspaceStore.clearWorkspace()
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
              !busy,
              activeProfileCanSend else { return }

        let effectivePrompt = promptText ?? text
        ensureActiveThread()
        busy = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            if self.activeBackend == .codex {
                await self.performCodexSendMessage(
                    displayText: text,
                    promptText: effectivePrompt,
                    visibleInTimeline: visibleInTimeline
                )
            } else {
                await self.performSendMessage(
                    displayText: text,
                    promptText: effectivePrompt,
                    visibleInTimeline: visibleInTimeline
                )
            }
        }
        responseTask = task
        await task.value
        responseTask = nil
        busy = false
    }

    /// Runs one turn through Codex App Server while preserving TurboCode's
    /// timeline contract. Visual file-change mapping is intentionally a later
    /// adapter layer; this foundation handles text, reasoning and cancellation
    /// without pretending Codex is a FoundationModels provider.
    private func performCodexSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async {
        isFirstMessage = false
        let titleThreadID = activeThreadId
        let titleTask: Task<Void, Never>? = visibleInTimeline ? Task { [weak self] in
            guard let self else { return }
            await self.generateTitle(from: displayText, for: titleThreadID)
        } : nil

        if visibleInTimeline {
            blocks.append(ChatBlock(kind: .user, text: displayText))
        }

        let placeholderID = UUID().uuidString
        let modelName = composerModel
        blocks.append(
            ChatBlock(
                id: placeholderID,
                kind: .assistant,
                text: "",
                model: modelName
            )
        )
        activeAssistantPlaceholderID = placeholderID
        liveAssistant = ""
        liveReasoning = ""
        activeWorkspaceListingPresentations.removeAll()
        error = nil

        guard let turboThreadID = activeThreadId else {
            self.error = "TurboCode could not create the conversation."
            return
        }

        var assistantText = ""
        var reasoningText = ""
        do {
            let snapshot = try await codexClient.prepareCodex(
                selectedModelID: preferredCodexModelID
            )
            codexModels = snapshot.models
            codexModel = snapshot.selectedModel
            preferredCodexModelID = snapshot.selectedModel.id
            composerModel = "Codex · \(snapshot.selectedModel.displayName)"
            codexConnectionState = .ready(planType: snapshot.planType)

            let codexThreadID: String
            if let existing = codexThreadIDs[turboThreadID] {
                codexThreadID = existing
            } else {
                let dynamicTools = CodexTurboCodeToolBridge.specifications(
                    workspaceRoot: workspaceRoot,
                    agentTuning: agentTuning
                )
                codexThreadID = try await codexClient.startThread(
                    workspaceRoot: workspaceRoot,
                    modelID: snapshot.selectedModel.model,
                    dynamicTools: dynamicTools
                )
                codexThreadIDs[turboThreadID] = codexThreadID
            }

            let stream = try await codexClient.startTurn(
                threadID: codexThreadID,
                text: promptText,
                workspaceRoot: workspaceRoot,
                modelID: snapshot.selectedModel.model,
                effort: codexReasoningEffort,
                additionalApplicationContext: codexImportedContexts[turboThreadID]
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .agentDelta(let delta):
                    assistantText += delta
                    liveAssistant = assistantText
                case .reasoningDelta(let delta):
                    reasoningText += delta
                    liveReasoning = reasoningText
                case .diffUpdated:
                    // Supported edits are directed through apply_edits so the
                    // existing Review/Undo transaction remains authoritative.
                    break
                case .toolCallRequested(let call):
                    toolInteractionStore.beginActivity(
                        id: call.callID,
                        summary: CodexTurboCodeToolBridge.activitySummary(
                            for: call.tool
                        )
                    )
                    let result: CodexDynamicToolResult
                    do {
                        let execution = try await CodexTurboCodeToolBridge.execute(
                            call,
                            workspaceRoot: workspaceRoot,
                            workspaceName: workspaceRoot.isEmpty
                                ? nil
                                : workspaceLabel,
                            agentTuning: agentTuning
                        )
                        if let presentation = execution.presentation {
                            presentCodexToolPresentation(presentation)
                        }
                        result = execution.result
                    } catch {
                        result = .failure(error.localizedDescription)
                    }
                    toolInteractionStore.endActivity(id: call.callID)
                    try await codexClient.resolveToolCall(call, result: result)
                case .approvalRequested(let request):
                    codexApprovals[request.presentationID] = request
                    presentApproval(
                        ApprovalRequest(
                            id: request.presentationID,
                            operation: request.operation,
                            path: request.path,
                            summary: request.summary
                        )
                    )
                case .tokenUsageUpdated(let usage):
                    codexTokenUsageByThread[turboThreadID] = usage
                case .completed(let status, let errorMessage):
                    if status == "failed" {
                        throw CodexAppServerError.invalidResponse(
                            errorMessage ?? "Codex turn failed."
                        )
                    }
                }
            }
            try Task.checkCancellation()

            if let index = blocks.firstIndex(where: { $0.id == placeholderID }) {
                if assistantText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    blocks.remove(at: index)
                } else {
                    blocks[index] = ChatBlock(
                        id: placeholderID,
                        kind: .assistant,
                        text: assistantText,
                        model: modelName
                    )
                }
            }
            if !reasoningText.isEmpty, !assistantText.isEmpty,
               let index = blocks.firstIndex(where: { $0.id == placeholderID }) {
                blocks.insert(
                    ChatBlock(
                        kind: .reasoning,
                        text: reasoningText,
                        model: modelName
                    ),
                    at: index
                )
            }
            conversationStore.touchThread(id: turboThreadID)
        } catch where error is CancellationError || Task.isCancelled {
            await codexClient.interruptActiveTurn()
            if let index = blocks.firstIndex(where: { $0.id == placeholderID }) {
                blocks[index] = ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: assistantText.isEmpty
                        ? "Response interrupted."
                        : assistantText,
                    model: modelName
                )
            }
            self.error = nil
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
            codexConnectionState = .signedOut
            self.error = nil
            if let index = blocks.firstIndex(where: { $0.id == placeholderID }) {
                blocks[index] = ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: "Sign in with ChatGPT to continue with Codex.",
                    model: modelName
                )
            }
        } catch {
            codexConnectionState = .failed(error.localizedDescription)
            self.error = error.localizedDescription
            if let index = blocks.firstIndex(where: { $0.id == placeholderID }) {
                blocks[index] = ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: "Error: \(error.localizedDescription)",
                    model: modelName
                )
            }
        }

        liveAssistant = ""
        liveReasoning = ""
        toolInteractionStore.clearActivities()
        activeWorkspaceListingPresentations.removeAll()
        if activeAssistantPlaceholderID == placeholderID {
            activeAssistantPlaceholderID = nil
        }
        if let titleTask {
            await titleTask.value
        }
        await persistSession(for: turboThreadID)
    }

    /// Uses Codex itself to compact a large Codex-owned thread. This hidden
    /// maintenance turn cannot mutate the workspace: tool calls fail visibly
    /// to the model and approval requests are denied before it can continue.
    private func requestCodexHandoffSummary(
        turboThreadID: String
    ) async throws -> String {
        guard let codexThreadID = codexThreadIDs[turboThreadID] else {
            throw CodexAppServerError.invalidResponse(
                "missing Codex thread for context handoff"
            )
        }
        let prompt = """
        Prepare a compact technical handoff for another coding model. Do not \
        call tools and do not continue the task. Include: the user's objective, \
        decisions and constraints, files changed or inspected, completed \
        validations, current repository/runtime state, unresolved issues, and \
        the exact next useful action. Preserve concrete paths, identifiers, and \
        errors. Omit private reasoning and conversational filler.
        """
        let stream = try await codexClient.startTurn(
            threadID: codexThreadID,
            text: prompt,
            workspaceRoot: workspaceRoot,
            modelID: codexModel?.model ?? preferredCodexModelID,
            effort: .low
        )
        var summary = ""
        for try await event in stream {
            switch event {
            case .agentDelta(let delta):
                summary += delta
            case .toolCallRequested(let call):
                try await codexClient.resolveToolCall(
                    call,
                    result: .failure(
                        "Tools are disabled while preparing a runtime handoff."
                    )
                )
            case .approvalRequested(let request):
                try await codexClient.resolveApproval(request, approved: false)
            case .tokenUsageUpdated(let usage):
                codexTokenUsageByThread[turboThreadID] = usage
            case .completed(let status, let errorMessage):
                if status == "failed" {
                    throw CodexAppServerError.invalidResponse(
                        errorMessage ?? "Codex context summary failed."
                    )
                }
            case .reasoningDelta, .diffUpdated:
                break
            }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inserts a Codex-requested TurboCode receipt before the active assistant
    /// placeholder, matching the ordering used by FoundationModels tool calls.
    private func presentCodexToolPresentation(
        _ presentation: CodexToolPresentation
    ) {
        switch presentation {
        case .workspaceListing(let listing):
            activeWorkspaceListingPresentations.append(listing)
            presentToolPresentation(.workspaceListing(listing))
        }
    }

    private func performSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async {
        // Some provider profiles intentionally discard completed tool calls.
        // Reattach only a relevant recent listing so follow-ups such as
        // “read TODO.md” remain grounded while the visible user text stays clean.
        let modelPrompt = WorkspaceListingFollowUpContext.enriching(
            promptText,
            blocks: blocks
        )
        // Echo filtering is scoped to one response so historical listing names
        // can never affect unrelated assistant messages.
        activeWorkspaceListingPresentations = []

        // A run retains the backend it started with even if settings change
        // while the asynchronous response is finishing.
        let diagnosticsBackend = activeBackend
        let diagnosticsRunID = await AgentDiagnosticsRecorder.shared.startRun(
            backend: diagnosticsBackend,
            mode: orchestratorMode,
            profileVersion: AgentProfileVersion.value(for: activeBackend, mode: orchestratorMode),
            workspaceKind: diagnosticsWorkspaceKind,
            promptCharacters: modelPrompt.count
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
        // task so persistence can wait for the final title. Keep the initiating
        // thread ID stable even if the user navigates before generation finishes.
        let titleThreadID = activeThreadId
        let titleTask: Task<Void, Never>? = visibleInTimeline ? Task { [weak self] in
            guard let self else { return }
            await self.generateTitle(from: displayText, for: titleThreadID)
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
            let stream = session.streamResponse(to: modelPrompt)
            // Delegation detection is handled by TurboCodeDynamicProfile's
            // onToolCall / onToolOutput lifecycle callbacks — no scanning needed.

            for try await snapshot in stream {
                try Task.checkCancellation()

                if diagnosticsBackend == .foundationApple, let diagnosticsRunID {
                    // Snapshots expose the authoritative on-device token and
                    // prefix-cache counters; the recorder keeps only the latest.
                    await AgentDiagnosticsRecorder.shared.recordUsage(
                        runID: diagnosticsRunID,
                        usage: snapshot.usage
                    )
                }

                // Fast path: update liveAssistant for quick UI feedback
                if !snapshot.content.isEmpty {
                    if !didRecordFirstToken, let diagnosticsRunID {
                        didRecordFirstToken = true
                        await AgentDiagnosticsRecorder.shared.markFirstToken(runID: diagnosticsRunID)
                    }
                    accumulatedText = snapshot.content
                    if diagnosticsBackend == .foundationApple,
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
            toolInteractionStore.clearActivities()
            let rawFinalText = accumulatedText.isEmpty
                ? liveReasoning
                : userVisibleAssistantText(accumulatedText)
            let finalText = NativeToolEchoFilter.filtering(
                rawFinalText,
                workspaceListings: activeWorkspaceListingPresentations
            )
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

            if let activeThreadId {
                conversationStore.touchThread(id: activeThreadId)
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
            toolInteractionStore.clearActivities()
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
            toolInteractionStore.clearActivities()
            self.error = nil
        } catch {
            diagnosticsOutcome = .failed
            diagnosticsError = error
            toolInteractionStore.clearActivities()
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
            if diagnosticsBackend == .foundationApple {
                let model = SystemLanguageModel.default
                // Some beta execution contexts temporarily report zero while
                // assets are unavailable. The current macOS 27 model is 8K, so
                // retain a useful diagnostic limit until the runtime answers.
                let reportedContextSize = model.contextSize
                let contextSize = reportedContextSize > 0 ? reportedContextSize : 8_192
                let contextTokens = try? await model.tokenCount(for: session.transcript)
                await AgentDiagnosticsRecorder.shared.recordContext(
                    runID: diagnosticsRunID,
                    tokenCount: contextTokens,
                    contextSize: contextSize
                )
            }
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
        activeWorkspaceListingPresentations = []
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
        if activeBackend == .codex {
            Task { await codexClient.interruptActiveTurn() }
        }
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
        case .codex:
            benchmarkStatus = "Codex uses its own App Server evaluation path."
            return
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
        guard let request = toolInteractionStore.takePendingApproval() else { return }

        if let codexApproval = codexApprovals.removeValue(forKey: request.id) {
            Task {
                do {
                    try await codexClient.resolveApproval(
                        codexApproval,
                        approved: true
                    )
                } catch {
                    self.error = error.localizedDescription
                }
            }
            return
        }

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
        guard let request = toolInteractionStore.takePendingApproval() else { return }
        if let codexApproval = codexApprovals.removeValue(forKey: request.id) {
            Task {
                do {
                    try await codexClient.resolveApproval(
                        codexApproval,
                        approved: false
                    )
                } catch {
                    self.error = error.localizedDescription
                }
            }
            return
        }
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
        toolInteractionStore.enqueueApproval(request)
    }

    public func dismissApproval(id: String) {
        toolInteractionStore.dismissApproval(id: id)
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
        toolInteractionStore.beginActivity(
            id: call.id,
            summary: toolSummary(for: call)
        )
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
        if let presentation = ToolPresentationRouter.presentation(
            for: call,
            output: output,
            workspaceName: workspaceRoot.isEmpty ? nil : workspaceLabel
        ) {
            presentToolPresentation(presentation)
        }
        toolInteractionStore.endActivity(id: call.id)
    }

    private func presentToolPresentation(_ presentation: ToolPresentation) {
        let block: ChatBlock
        switch presentation {
        case .workspaceListing(let listing):
            activeWorkspaceListingPresentations.append(listing)
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
        reviewFiles: [DiffReviewFileSnapshot] = [],
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
            payload.reviewFiles = mergedReviewFiles(
                existing: payload.reviewFiles ?? [],
                incoming: reviewFiles
            )
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
            reviewFiles: reviewFiles.isEmpty ? nil : reviewFiles,
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

    /// Shows the immutable snapshot associated with one timeline receipt. The
    /// inspector never rereads the filesystem, preserving conversational history.
    public func reviewWorkspaceListing(_ id: String) {
        guard blocks.contains(where: { $0.id == id && $0.workspaceListing != nil }) else { return }
        inspectedWorkspaceListingID = id
        rightPanelMode = .workspaceListing
    }

    /// Dismisses only the transient workspace snapshot. Other inspectors are
    /// persistent workbench modes and must not close when the canvas is clicked.
    func dismissWorkspaceListingInspector() {
        guard rightPanelMode == .workspaceListing else { return }
        inspectedWorkspaceListingID = nil
        rightPanelMode = nil
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
                        reverse: true,
                        tolerateInaccurateEOF: false
                    )
                    revertedPatches.append(patch)
                }
                updateDiffPatchBlock(id: id, status: .undone)
            } catch {
                for patch in revertedPatches.reversed() {
                    try? await diffPatchService.apply(
                        patch: patch,
                        workspaceRoot: payload.workspaceRoot,
                        reverse: false,
                        tolerateInaccurateEOF: false
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

    /// Consecutive edit_file calls in one assistant turn share a receipt. The
    /// review must retain the first before-state and the final after-state.
    private func mergedReviewFiles(
        existing: [DiffReviewFileSnapshot],
        incoming: [DiffReviewFileSnapshot]
    ) -> [DiffReviewFileSnapshot] {
        var merged = existing
        for snapshot in incoming {
            if let index = merged.firstIndex(where: { $0.path == snapshot.path }) {
                merged[index] = DiffReviewFileSnapshot(
                    path: snapshot.path,
                    originalText: merged[index].originalText,
                    modifiedText: snapshot.modifiedText
                )
            } else {
                merged.append(snapshot)
            }
        }
        return merged
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
        if route == .skills {
            // Preserve the current destination behind the native sheet. Using
            // `.skills` as the visible route used to construct a stale Chat
            // timeline while presenting the modal, which could beachball.
            isCustomProfilesPresented = true
            return
        }
        isCustomProfilesPresented = false
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
        conversationStore.sortedThreads(selectedProject: selectedProject)
    }
}
