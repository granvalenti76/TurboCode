import Foundation
import Observation
import SwiftUI

/// The immutable receipt currently being shown in the native edit-review sheet.
/// Keeping this presentation state above the lazy chat timeline prevents a
/// timeline refresh from losing the sheet trigger or its action target.
struct DiffPatchReviewPresentation: Identifiable {
    let id: String
    let patch: DiffPatchBlock
}

/// Distinguishes document creation from the two workspace-file entry points.
/// Ordinary Markdown must never pass through the authentic-draft loader.
nonisolated enum EditorialDeskOpening: Equatable, Sendable {
    case newDraft
    case existingDraft(relativePath: String)
    case importedMarkdown(relativePath: String)
}

/// Stable shell-owned request for the removable Editorial Desk sheet.
struct EditorialDeskPresentation: Identifiable, Equatable {
    let id: UUID
    let opening: EditorialDeskOpening

    init(id: UUID = UUID(), opening: EditorialDeskOpening = .newDraft) {
        self.id = id
        self.opening = opening
    }

    var draftRelativePath: String? {
        guard case .existingDraft(let relativePath) = opening else { return nil }
        return relativePath
    }
}

/// Stable request for the active conversation's document-modal transcript.
/// Binding it to a thread ID prevents an asynchronous sheet load from showing
/// data that belongs to a conversation replaced underneath it.
struct TranscriptSheetPresentation: Identifiable, Equatable {
    let id: String
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
    var terminalPresented = false
    var inspectedGitCommit: GitCommitBlock?
    var inspectedWorkspaceListingID: String?
    var inspectedDiffPatchReview: DiffPatchReviewPresentation?
    var editorialDeskPresentation: EditorialDeskPresentation?
    var transcriptSheetPresentation: TranscriptSheetPresentation?

    var rightPanelVisible: Bool { rightPanelMode != nil }

    func setRoute(_ route: AppRoute) {
        if route == .skills {
            // Profiles are a modal over the current destination, not a route.
            isCustomProfilesPresented = true
            return
        }
        isCustomProfilesPresented = false
        self.route = route
        if route != .chat {
            rightPanelMode = nil
            // The terminal utility area accompanies the chat canvas. Terminate
            // its process instead of leaving an invisible shell behind.
            terminalPresented = false
        }
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

    func toggleTerminal() {
        terminalPresented.toggle()
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

    func presentEditorialDesk(draftRelativePath: String? = nil) {
        editorialDeskPresentation = EditorialDeskPresentation(
            opening: draftRelativePath.map(EditorialDeskOpening.existingDraft)
                ?? .newDraft
        )
    }

    func presentEditorialDesk(importingMarkdown relativePath: String) {
        editorialDeskPresentation = EditorialDeskPresentation(
            opening: .importedMarkdown(relativePath: relativePath)
        )
    }

    func dismissEditorialDesk() {
        editorialDeskPresentation = nil
    }

    func presentTranscript(threadID: String) {
        transcriptSheetPresentation = TranscriptSheetPresentation(id: threadID)
    }

    func dismissTranscript() {
        transcriptSheetPresentation = nil
    }
}
