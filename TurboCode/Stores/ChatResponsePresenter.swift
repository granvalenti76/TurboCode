import Foundation

/// MainActor projection boundary for one response.
///
/// Provider and runtime ownership stay outside this type. It only translates
/// already-admitted response state into timeline and review presentation.
@MainActor
final class ChatResponsePresenter {
    private let timeline: ChatTimelineStore
    private let reviewCoordinator: ReviewCoordinator?
    private var segmentPlaceholders: [TurnID: String] = [:]
    private var assistantPrefixes: [TurnID: String] = [:]
    private var reasoningPrefixes: [TurnID: String] = [:]

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
        model: String,
        turnID: TurnID
    ) {
        timeline.beginResponse(
            displayText: displayText,
            placeholderID: placeholderID,
            model: model
        )
        segmentPlaceholders[turnID] = placeholderID
    }

    @discardableResult
    func beginSteeringSegment(
        turnID: TurnID,
        displayText: String,
        metadata: SteeringDeliveryMetadata,
        model: String
    ) -> Bool {
        let assistantPrefix = timeline.liveAssistant
        let reasoningPrefix = timeline.liveReasoning
        guard let placeholderID = timeline.beginSteeringSegment(
            displayText: displayText,
            metadata: metadata,
            model: model
        ) else { return false }
        segmentPlaceholders[turnID] = placeholderID
        assistantPrefixes[turnID] = assistantPrefix
        reasoningPrefixes[turnID] = reasoningPrefix
        return true
    }

    func presentSteeringDelivery(
        displayText: String,
        metadata: SteeringDeliveryMetadata
    ) {
        timeline.presentSteeringDelivery(
            displayText: displayText,
            metadata: metadata
        )
    }

    func placeholderID(for turnID: TurnID, fallback: String) -> String {
        segmentPlaceholders[turnID] ?? fallback
    }

    func publishAssistant(_ text: String, turnID: TurnID) {
        timeline.liveAssistant = segmented(
            text,
            prefix: assistantPrefixes[turnID]
        )
    }

    func publishReasoning(_ text: String, turnID: TurnID) {
        timeline.liveReasoning = segmented(
            text,
            prefix: reasoningPrefixes[turnID]
        )
    }

    func segmentedAssistantText(_ text: String, turnID: TurnID) -> String {
        segmented(text, prefix: assistantPrefixes[turnID])
    }

    func segmentedReasoningText(_ text: String, turnID: TurnID) -> String {
        segmented(text, prefix: reasoningPrefixes[turnID])
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
        let turnID = segmentPlaceholders.first { $0.value == placeholderID }?.key
        timeline.finishResponse(placeholderID: placeholderID)
        segmentPlaceholders = segmentPlaceholders.filter { $0.value != placeholderID }
        if let turnID {
            assistantPrefixes.removeValue(forKey: turnID)
            reasoningPrefixes.removeValue(forKey: turnID)
        }
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

    private func segmented(_ text: String, prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty, text.hasPrefix(prefix) else {
            return text
        }
        return String(text.dropFirst(prefix.count))
    }
}
