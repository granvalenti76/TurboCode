import Foundation
import FoundationModels
import FoundationModelsUtilities
import SwiftUI

/// Backwards-compatible view API for the decomposed chat domains.
///
/// These properties intentionally contain no behavior: each forwards to the
/// bounded store that owns the state. Views can migrate incrementally without
/// forcing ChatStore to regain ownership of those responsibilities.
@MainActor
extension ChatStore {
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

    public var blocks: [ChatBlock] {
        get { timelineStore.blocks }
        set { timelineStore.blocks = newValue }
    }

    public var liveReasoning: String {
        get { timelineStore.liveReasoning }
        set { timelineStore.liveReasoning = newValue }
    }

    public var liveAssistant: String {
        get { timelineStore.liveAssistant }
        set { timelineStore.liveAssistant = newValue }
    }

    public var toolActivities: [ToolActivity] {
        get { toolInteractionStore.activities }
        set { toolInteractionStore.activities = newValue }
    }

    public var activeToolActivity: ToolActivity? {
        toolInteractionStore.activeActivity
    }

    /// Activity is conversation-local and intentionally excluded from session
    /// persistence until a later release defines a durable task ledger.
    var currentAgentActivity: AgentActivity? {
        agentActivityStore.current
    }

    public var isFirstMessage: Bool {
        get { timelineStore.isFirstMessage }
        set { timelineStore.isFirstMessage = newValue }
    }

    public var pendingApproval: ApprovalRequest? {
        get { toolInteractionStore.pendingApproval }
        set { toolInteractionStore.pendingApproval = newValue }
    }

    public var composerModel: String {
        get { modelRuntimeStore.composerModel }
        set { modelRuntimeStore.composerModel = newValue }
    }

    public var route: AppRoute {
        get { workbenchStore.route }
        set { workbenchStore.route = newValue }
    }

    public var isCustomProfilesPresented: Bool {
        get { workbenchStore.isCustomProfilesPresented }
        set { workbenchStore.isCustomProfilesPresented = newValue }
    }

    public var settingsSection: SettingsSection {
        get { workbenchStore.settingsSection }
        set { workbenchStore.settingsSection = newValue }
    }

    public var leftSidebarCollapsed: Bool {
        get { workbenchStore.leftSidebarCollapsed }
        set { workbenchStore.leftSidebarCollapsed = newValue }
    }

    public var leftSidebarWidth: CGFloat {
        get { workbenchStore.leftSidebarWidth }
        set { workbenchStore.leftSidebarWidth = newValue }
    }

    public var rightPanelMode: RightPanelMode? {
        get { workbenchStore.rightPanelMode }
        set { workbenchStore.rightPanelMode = newValue }
    }

    public var rightPanelVisible: Bool {
        workbenchStore.rightPanelVisible
    }

    public var rightSidebarWidth: CGFloat {
        get { workbenchStore.rightSidebarWidth }
        set { workbenchStore.rightSidebarWidth = newValue }
    }

    public var inspectedGitCommit: GitCommitBlock? {
        get { workbenchStore.inspectedGitCommit }
        set { workbenchStore.inspectedGitCommit = newValue }
    }

    public var inspectedWorkspaceListingID: String? {
        get { workbenchStore.inspectedWorkspaceListingID }
        set { workbenchStore.inspectedWorkspaceListingID = newValue }
    }

    public var inspectedWorkspaceListing: WorkspaceListingBlock? {
        guard let inspectedWorkspaceListingID else { return nil }
        return timelineStore.block(id: inspectedWorkspaceListingID)?
            .workspaceListing
    }

    public var workspaceRoot: String {
        get { workspaceStore.root }
        set { workspaceStore.root = newValue }
    }

    public var workspaceLabel: String {
        workspaceStore.label
    }

    public var recentWorkspaces: [String] {
        get { workspaceStore.recentWorkspaces }
        set { workspaceStore.recentWorkspaces = newValue }
    }

    public var selectedProject: String? {
        get { workspaceStore.selectedProject }
        set { workspaceStore.selectedProject = newValue }
    }

    public var activeBackend: ModelBackend {
        get { modelRuntimeStore.activeBackend }
        set { modelRuntimeStore.activeBackend = newValue }
    }

    public var agentTuning: AgentTuningConfig {
        modelRuntimeStore.agentTuning
    }

    public var remoteModels: [RemoteModelConfig] {
        modelRuntimeStore.remoteModels
    }

    public var activeRemoteModelID: String {
        modelRuntimeStore.activeRemoteModelID
    }

    var dynamicProfiles: [UserDynamicProfile] {
        modelRuntimeStore.dynamicProfiles
    }

    var activeDynamicProfileID: UUID? {
        modelRuntimeStore.activeDynamicProfileID
    }

    var activeDynamicProfile: UserDynamicProfile? {
        modelRuntimeStore.activeDynamicProfile
    }

    var activeBaseModelID: ProfileBaseModelID {
        modelRuntimeStore.activeBaseModelID
    }

    public var activeRemoteModel: RemoteModelConfig? {
        modelRuntimeStore.activeRemoteModel
    }

    public var enabledRemoteModels: [RemoteModelConfig] {
        modelRuntimeStore.enabledRemoteModels
    }

    public var activeModelSupportsReasoning: Bool {
        modelRuntimeStore.activeModelSupportsReasoning
    }

    var codexConnectionState: CodexConnectionState {
        get { codexRuntimeStore.connectionState }
        set { codexRuntimeStore.connectionState = newValue }
    }

    var codexModel: CodexModelDescriptor? {
        codexRuntimeStore.model
    }

    var codexModels: [CodexModelDescriptor] {
        codexRuntimeStore.models
    }

    var codexLoginURL: URL? {
        codexRuntimeStore.loginURL
    }

    var codexReasoningEffort: CodexReasoningEffort {
        codexRuntimeStore.reasoningEffort
    }

    var codexReasoningOptions: [CodexReasoningOption] {
        codexRuntimeStore.reasoningOptions
    }

    var codexDisplayName: String {
        codexRuntimeStore.displayName
    }

    var activeProfileCanSend: Bool {
        activeBackend != .codex || codexRuntimeStore.canSend
    }

    public var skillActivations: SkillActivations {
        modelRuntimeStore.skillActivations
    }

    var availableSkills: [TurboCodeSkillDefinition] {
        modelRuntimeStore.availableSkills
    }

    public var reasoningLevel: ContextOptions.ReasoningLevel? {
        modelRuntimeStore.reasoningLevel
    }

    public var isDelegating: Bool {
        responseCoordinator.isDelegating
    }

    var diffSections: [FileDiffSection] {
        workspaceStore.diffSections
    }

    var isLoadingDiffs: Bool {
        workspaceStore.isLoadingDiffs
    }

    var diffLoadError: String? {
        workspaceStore.diffLoadError
    }

    var isGitRepository: Bool {
        workspaceStore.isGitRepository
    }

    var currentBranch: String {
        workspaceStore.currentBranch
    }

    var availableBranches: [String] {
        workspaceStore.availableBranches
    }

    public func reloadDiffs() async {
        await workspaceStore.reloadDiffs()
    }

    public func refreshGitBranches() async {
        await workspaceStore.refreshGitBranches()
    }

    public func refreshGitAfterToolMutation() async {
        await workspaceStore.refreshGitAfterToolMutation()
    }

    public func switchToBranch(_ branch: String) async {
        await workspaceStore.switchToBranch(branch)
    }

    public var sortedThreads: [Conversation] {
        conversationStore.sortedThreads(selectedProject: selectedProject)
    }
}
