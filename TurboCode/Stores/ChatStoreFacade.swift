import Foundation
import FoundationModels
import SwiftUI

/// Backwards-compatible view API for the decomposed chat domains.
///
/// These properties intentionally contain no behavior: each forwards to the
/// bounded store that owns the state. Views can migrate incrementally without
/// forcing ChatStore to regain ownership of those responsibilities. Domain
/// transitions remain command-only so a view cannot change one projection
/// without rebuilding the related session, timeline, or runtime state.
@MainActor
extension ChatStore {
    public var threads: [Conversation] {
        conversationStore.threads
    }

    public var activeThreadId: String? {
        conversationStore.activeThreadID
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
        timelineStore.blocks
    }

    public var liveReasoning: String {
        timelineStore.liveReasoning
    }

    public var liveAssistant: String {
        timelineStore.liveAssistant
    }

    public var toolActivities: [ToolActivity] {
        toolInteractionStore.activities
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
        timelineStore.isFirstMessage
    }

    public var pendingApproval: ApprovalRequest? {
        toolInteractionStore.pendingApproval
    }

    public var composerModel: String {
        modelRuntimeStore.composerModel
    }

    public var route: AppRoute {
        workbenchStore.route
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
        workbenchStore.rightPanelMode
    }

    public var rightPanelVisible: Bool {
        workbenchStore.rightPanelVisible
    }

    public var rightSidebarWidth: CGFloat {
        get { workbenchStore.rightSidebarWidth }
        set { workbenchStore.rightSidebarWidth = newValue }
    }

    public var terminalPresented: Bool {
        get { workbenchStore.terminalPresented }
        set { workbenchStore.terminalPresented = newValue }
    }

    public var inspectedGitCommit: GitCommitBlock? {
        workbenchStore.inspectedGitCommit
    }

    public var inspectedWorkspaceListingID: String? {
        workbenchStore.inspectedWorkspaceListingID
    }

    public var inspectedWorkspaceListing: WorkspaceListingBlock? {
        guard let inspectedWorkspaceListingID else { return nil }
        return timelineStore.block(id: inspectedWorkspaceListingID)?
            .workspaceListing
    }

    public var workspaceRoot: String {
        workspaceStore.root
    }

    public var workspaceLabel: String {
        workspaceStore.label
    }

    public var recentWorkspaces: [String] {
        workspaceStore.recentWorkspaces
    }

    public var selectedProject: String? {
        get { workspaceStore.selectedProject }
        set { workspaceStore.selectedProject = newValue }
    }

    public var activeBackend: ModelBackend {
        modelRuntimeStore.activeBackend
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
        codexRuntimeStore.connectionState
    }

    var codexModel: CodexModelDescriptor? {
        codexRuntimeStore.model
    }

    /// Exposes the direct-Codex default separately from a coordinator model
    /// temporarily presented by the active runtime.
    var codexPreferredModel: CodexModelDescriptor? {
        codexRuntimeStore.preferredModel
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

    var reviewComments: [ReviewComment] {
        reviewDraftStore.comments
    }

    var outdatedReviewCommentCount: Int {
        reviewDraftStore.outdatedCount
    }

    var canSendReviewComments: Bool {
        reviewDraftStore.canSend && !busy && activeProfileCanSend
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

    @discardableResult
    func upsertReviewComment(
        id: UUID?,
        anchor: ReviewLineAnchor,
        body: String
    ) -> ReviewComment? {
        reviewDraftStore.upsert(id: id, anchor: anchor, body: body)
    }

    func removeReviewComment(_ id: UUID) {
        reviewDraftStore.remove(id)
    }

    func discardReviewComments() {
        reviewDraftStore.discardAll()
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
