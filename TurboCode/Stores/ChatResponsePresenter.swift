import Foundation

/// MainActor projection boundary for one response.
///
/// Provider and runtime ownership stay outside this type. It only translates
/// already-admitted response state into timeline and review presentation.
@MainActor
final class ChatResponsePresenter {
    private let timeline: ChatTimelineStore
    private let reviewCoordinator: ReviewCoordinator?

    init(
        timeline: ChatTimelineStore,
        reviewCoordinator: ReviewCoordinator?
    ) {
        self.timeline = timeline
        self.reviewCoordinator = reviewCoordinator
    }

    var workspaceListings: [WorkspaceListingBlock] {
        timeline.workspaceListingPresentations
    }

    func beginResponse(
        displayText: String?,
        placeholderID: String,
        model: String
    ) {
        timeline.beginResponse(
            displayText: displayText,
            placeholderID: placeholderID,
            model: model
        )
    }

    func publishAssistant(_ text: String) {
        timeline.liveAssistant = text
    }

    func publishReasoning(_ text: String) {
        timeline.liveReasoning = text
    }

    func finalizeResponse(
        placeholderID: String,
        assistantBlock: ChatBlock?,
        reasoningBlock: ChatBlock?
    ) {
        timeline.finalizeResponse(
            placeholderID: placeholderID,
            assistantBlock: assistantBlock,
            reasoningBlock: reasoningBlock
        )
    }

    func replaceResponse(placeholderID: String, block: ChatBlock) {
        timeline.replaceBlock(id: placeholderID, with: block)
    }

    func finishResponse(placeholderID: String) {
        timeline.finishResponse(placeholderID: placeholderID)
    }

    func resetLiveResponse() {
        timeline.liveReasoning = ""
        timeline.liveAssistant = ""
    }

    func clearEditGroup(_ editGroupID: String) {
        timeline.clearEditGroup(editGroupID)
    }

    func present(
        _ receipt: ToolReceipt,
        toolCallID: String,
        editGroupID: String?
    ) {
        switch receipt {
        case .workspaceListing(let listing):
            timeline.presentWorkspaceListing(listing)
        case .pluginWidget(let widget):
            timeline.presentPluginWidget(widget, toolCallID: toolCallID)
        case .diffPatch(let artifact):
            reviewCoordinator?.presentDiffPatch(
                artifact,
                editGroupID: editGroupID
            )
        case .gitStatus(let status):
            reviewCoordinator?.presentGitStatus(status)
        case .gitCommit(let commit):
            reviewCoordinator?.presentGitCommit(commit)
            reviewCoordinator?.repositoryChanged()
        case .repositoryChanged:
            reviewCoordinator?.repositoryChanged()
        }
    }
}
