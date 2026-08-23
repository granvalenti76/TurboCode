import Observation

/// Owns the in-memory timeline aggregate shown by the chat canvas.
///
/// This store has no provider, persistence, workspace, or navigation
/// dependencies. ChatStore decides what a response means; this type only
/// applies deterministic block transitions and preserves presentation order.
@MainActor
@Observable
final class ChatTimelineStore {
    var blocks: [ChatBlock] = []
    var liveReasoning = ""
    var liveAssistant = ""
    var isFirstMessage = true

    /// Latest runtime context projected for presentation decisions. This is a
    /// read-only copy; turn ownership and lifecycle transitions remain in
    /// AgentRuntime rather than in the timeline aggregate.
    private(set) var runtimeSnapshot: RuntimeSnapshot?

    private(set) var activeAssistantPlaceholderID: String?
    private(set) var workspaceListingPresentations: [WorkspaceListingBlock] = []

    private var editTransactionGroups: [String: String] = [:]

    /// Resets the complete visible turn state for a new or deleted conversation.
    func reset() {
        blocks = []
        liveReasoning = ""
        liveAssistant = ""
        isFirstMessage = true
        activeAssistantPlaceholderID = nil
        workspaceListingPresentations = []
        editTransactionGroups = [:]
    }

    /// Restores persisted blocks while discarding transient streaming state.
    func restore(_ restoredBlocks: [ChatBlock]) {
        reset()
        blocks = restoredBlocks
        isFirstMessage = restoredBlocks.isEmpty
    }

    /// Applies a provider-neutral runtime snapshot without importing or
    /// retaining a provider session, task, or lifecycle reducer.
    func applyRuntimeSnapshot(_ snapshot: RuntimeSnapshot) {
        // Shared composition and compatibility coordinators may observe the
        // same runtime edge. Equality suppression keeps that harmless overlap
        // from invalidating the transcript view twice.
        guard runtimeSnapshot != snapshot else { return }
        runtimeSnapshot = snapshot
    }

    /// Starts one visible response and records the exact placeholder used to
    /// order tool receipts ahead of the eventual assistant answer.
    func beginResponse(
        displayText: String?,
        placeholderID: String,
        model: String
    ) {
        isFirstMessage = false
        if let displayText {
            blocks.append(ChatBlock(kind: .user, text: displayText))
        }
        blocks.append(
            ChatBlock(
                id: placeholderID,
                kind: .assistant,
                text: "",
                model: model
            )
        )
        activeAssistantPlaceholderID = placeholderID
        liveReasoning = ""
        liveAssistant = ""
        workspaceListingPresentations = []
    }

    /// Replaces or removes a response placeholder, then optionally inserts a
    /// reasoning block immediately before the finalized assistant block.
    func finalizeResponse(
        placeholderID: String,
        assistantBlock: ChatBlock?,
        reasoningBlock: ChatBlock? = nil
    ) {
        guard let index = blocks.firstIndex(where: { $0.id == placeholderID }) else { return }
        guard let assistantBlock else {
            blocks.remove(at: index)
            return
        }

        blocks[index] = assistantBlock
        if let reasoningBlock {
            blocks.insert(reasoningBlock, at: index)
        }
    }

    func replaceBlock(id: String, with block: ChatBlock) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index] = block
    }

    /// Ends only the matching response so a stale asynchronous completion
    /// cannot clear a newer response's placeholder identity.
    func finishResponse(placeholderID: String) {
        guard activeAssistantPlaceholderID == placeholderID else { return }
        liveReasoning = ""
        liveAssistant = ""
        workspaceListingPresentations = []
        activeAssistantPlaceholderID = nil
    }

    func block(id: String) -> ChatBlock? {
        blocks.first { $0.id == id }
    }

    /// Inserts a listing once, before the active assistant placeholder, and
    /// retains its immutable payload for response-local echo filtering.
    func presentWorkspaceListing(_ listing: WorkspaceListingBlock) {
        let block = ChatBlock(
            id: "workspace-listing-\(listing.toolCallID)",
            kind: .workspaceListing,
            text: listing.path,
            workspaceListing: listing
        )
        guard !blocks.contains(where: { $0.id == block.id }) else { return }
        workspaceListingPresentations.append(listing)
        insertBeforeActivePlaceholderOrAppend(block)
    }

    /// Inserts a plugin-owned UI surface only when a tool explicitly returns
    /// one. The widget remains a value in the timeline; WebKit is created by
    /// the response view only while this block is rendered.
    func presentPluginWidget(_ widget: TypeScriptPluginWidgetReceipt, toolCallID: String) {
        let block = ChatBlock(
            id: "plugin-widget-\(toolCallID)",
            kind: .pluginWidget,
            text: widget.title,
            pluginWidget: widget
        )
        guard !blocks.contains(where: { $0.id == block.id }) else { return }
        insertBeforeActivePlaceholderOrAppend(block)
    }

    func beginDiffPatch(
        id: String,
        editGroupID: String?,
        workspaceRoot: String,
        patch: String,
        files: [DiffPatchFileChange],
        reviewFiles: [DiffReviewFileSnapshot],
        status: DiffPatchStatus
    ) {
        let blockID = editGroupID ?? id
        editTransactionGroups[id] = blockID

        if let index = blocks.firstIndex(where: { $0.id == blockID }),
           let payload = blocks[index].diffPatch {
            blocks[index].diffPatch = ReviewReceiptReducer.merging(
                payload,
                patch: patch,
                files: files,
                reviewFiles: reviewFiles,
                status: status
            )
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
        insertBeforeEmptyAssistantOrAppend(
            ChatBlock(id: blockID, kind: .diffPatch, text: "", diffPatch: payload)
        )
    }

    /// Returns whether derived workspace diffs should be reloaded.
    @discardableResult
    func updateDiffPatch(
        id: String,
        status: DiffPatchStatus,
        errorMessage: String?
    ) -> Bool {
        let blockID = editTransactionGroups[id] ?? id
        guard let index = blocks.firstIndex(where: { $0.id == blockID }),
              let payload = blocks[index].diffPatch else { return false }
        blocks[index].diffPatch = ReviewReceiptReducer.updating(
            payload,
            status: status,
            errorMessage: errorMessage
        )
        return status == .applied || status == .undone
    }

    func clearEditGroup(_ editGroupID: String) {
        editTransactionGroups = editTransactionGroups.filter {
            $0.value != editGroupID
        }
    }

    func presentGitCommit(_ receipt: GitCommitBlock) {
        insertBeforeEmptyAssistantOrAppend(
            ChatBlock(kind: .gitCommit, text: "", gitCommit: receipt)
        )
    }

    /// Places status snapshots ahead of the assistant prose generated from the
    /// same tool result, matching other native tool receipts in the timeline.
    func presentGitStatus(_ status: GitStatusBlock) {
        insertBeforeActivePlaceholderOrAppend(
            ChatBlock(kind: .gitStatus, text: "", gitStatus: status)
        )
    }

    func updateGitCommit(id: String, receipt: GitCommitBlock) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].gitCommit = receipt
    }

    /// Presents an intentional context boundary without hiding the durable
    /// conversation. The chat view renders this as a quiet HIG-style status
    /// card between the previous work and the next model turn.
    func presentCompaction(_ text: String) {
        insertBeforeActivePlaceholderOrAppend(
            ChatBlock(kind: .compaction, text: text)
        )
    }

    /// Inserts documentation opened by a local command as the same native
    /// guide card used for model-grounded `turbocode_guide` responses.
    func presentProductGuide(_ guide: ProductGuideBlock, markdown: String) {
        insertBeforeActivePlaceholderOrAppend(
            ChatBlock(kind: .productGuide, text: markdown, productGuide: guide)
        )
    }

    /// Records an application-owned task as an ordinary visible conversation
    /// turn. The worker remains independent, while its final prose is easy to
    /// read, copy, persist, and include in later context handoffs.
    func presentTaskTurn(command: String, response: String) {
        isFirstMessage = false
        blocks.append(ChatBlock(kind: .user, text: command))
        blocks.append(ChatBlock(kind: .assistant, text: response))
    }

    private func insertBeforeActivePlaceholderOrAppend(_ block: ChatBlock) {
        if let activeAssistantPlaceholderID,
           let index = blocks.firstIndex(where: { $0.id == activeAssistantPlaceholderID }) {
            blocks.insert(block, at: index)
        } else {
            blocks.append(block)
        }
    }

    private func insertBeforeEmptyAssistantOrAppend(_ block: ChatBlock) {
        if let index = blocks.lastIndex(where: {
            $0.kind == .assistant && $0.text.isEmpty
        }) {
            blocks.insert(block, at: index)
        } else {
            blocks.append(block)
        }
    }
}
