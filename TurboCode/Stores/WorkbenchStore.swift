import Observation
import SwiftUI

/// The immutable receipt currently being shown in the native edit-review sheet.
/// Keeping this presentation state above the lazy chat timeline prevents a
/// timeline refresh from losing the sheet trigger or its action target.
struct DiffPatchReviewPresentation: Identifiable {
    let id: String
    let patch: DiffPatchBlock
}

/// Owns workbench navigation and panel presentation state.
///
/// Keeping shell state separate prevents model and conversation orchestration
/// from accumulating view-specific transitions.
@MainActor
@Observable
final class WorkbenchStore {
    var route: AppRoute = .chat
    var isCustomProfilesPresented = false
    private(set) var requestedProfileCreationRole: ProfileExecutionRole?
    var settingsSection: SettingsSection = .general
    var leftSidebarCollapsed = false
    var leftSidebarWidth: CGFloat = 304
    var rightPanelMode: RightPanelMode?
    var rightSidebarWidth: CGFloat = 360
    var inspectedGitCommit: GitCommitBlock?
    var inspectedWorkspaceListingID: String?
    var inspectedDiffPatchReview: DiffPatchReviewPresentation?

    var rightPanelVisible: Bool { rightPanelMode != nil }

    func setRoute(_ route: AppRoute) {
        if route == .skills {
            // Profiles are a modal over the current destination, not a route.
            isCustomProfilesPresented = true
            return
        }
        isCustomProfilesPresented = false
        self.route = route
        if route != .chat { rightPanelMode = nil }
    }

    /// Opens profile management with a specific creation intent. The request is
    /// consumed once by the modal so ordinary later openings stay neutral.
    func requestProfileCreation(role: ProfileExecutionRole) {
        requestedProfileCreationRole = role
        isCustomProfilesPresented = true
    }

    func consumeProfileCreationRequest() -> ProfileExecutionRole? {
        defer { requestedProfileCreationRole = nil }
        return requestedProfileCreationRole
    }

    func toggleRightPanel(_ mode: RightPanelMode) {
        rightPanelMode = rightPanelMode == mode ? nil : mode
    }

    func toggleLeftSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            leftSidebarCollapsed.toggle()
        }
    }

    /// Dismisses only the transient listing inspector; persistent inspectors
    /// remain open when the user clicks back into the canvas.
    func dismissWorkspaceListingInspector() {
        guard rightPanelMode == .workspaceListing else { return }
        inspectedWorkspaceListingID = nil
        rightPanelMode = nil
    }

    /// Closes a native review that belongs to the conversation being replaced.
    /// The receipt itself remains persisted in the old conversation.
    func dismissDiffPatchReview() {
        inspectedDiffPatchReview = nil
    }
}
