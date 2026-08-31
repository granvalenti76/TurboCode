import Foundation

/// Coordinates review receipts and their reversible repository effects.
///
/// This boundary owns diff/commit review behavior only. It has no knowledge of
/// model runtimes, response streaming, conversation catalogs, or composer state.
@MainActor
final class ReviewCoordinator {
    private let timeline: ChatTimelineStore
    private let workbench: WorkbenchStore
    private let workspace: WorkspaceStore
    private let gitService: any GitRepositoryServicing
    private let diffPatchService: any DiffPatchApplying

    init(
        timeline: ChatTimelineStore,
        workbench: WorkbenchStore,
        workspace: WorkspaceStore,
        gitService: any GitRepositoryServicing,
        diffPatchService: any DiffPatchApplying
    ) {
        self.timeline = timeline
        self.workbench = workbench
        self.workspace = workspace
        self.gitService = gitService
        self.diffPatchService = diffPatchService
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
        timeline.beginDiffPatch(
            id: id,
            editGroupID: editGroupID,
            workspaceRoot: workspaceRoot,
            patch: patch,
            files: files,
            reviewFiles: reviewFiles,
            status: status
        )
    }

    func updateDiffPatch(
        id: String,
        status: DiffPatchStatus,
        errorMessage: String?
    ) {
        if timeline.updateDiffPatch(
            id: id,
            status: status,
            errorMessage: errorMessage
        ) {
            Task { await workspace.reloadDiffs() }
        }
    }

    /// Projects one terminal tool artifact. In-flight progress remains in the
    /// generic activity surface, so the timeline receives a single immutable
    /// review receipt owned by the provider completion.
    func presentDiffPatch(
        _ receipt: DiffPatchReceipt,
        editGroupID: String?
    ) {
        let block = receipt.block
        beginDiffPatch(
            id: receipt.transactionID,
            editGroupID: editGroupID,
            workspaceRoot: block.workspaceRoot,
            patch: block.patch,
            files: block.files,
            reviewFiles: block.reviewFiles ?? [],
            status: block.status
        )
        // `beginDiffPatch` also serves the older running-then-update API and
        // therefore initializes errors to nil. Terminal receipts must restore
        // their immutable failure detail without reintroducing a side channel.
        if let errorMessage = block.errorMessage {
            timeline.updateDiffPatch(
                id: receipt.transactionID,
                status: block.status,
                errorMessage: errorMessage
            )
        }
        Task { await workspace.reloadDiffs() }
    }

    func reviewDiffPatch(_ id: String) {
        guard timeline.block(id: id)?.diffPatch != nil else { return }
        workbench.rightPanelMode = .changes
        Task { await workspace.reloadDiffs() }
    }

    /// Presents the immutable receipt from stable workbench state rather than
    /// from the lazy timeline row that originated the button action.
    func presentDiffPatchReview(_ id: String) {
        guard let patch = timeline.block(id: id)?.diffPatch else { return }
        workbench.inspectedDiffPatchReview = DiffPatchReviewPresentation(
            id: id,
            patch: patch
        )
    }

    func presentGitCommit(_ receipt: GitCommitBlock) {
        timeline.presentGitCommit(receipt)
    }

    func presentGitStatus(_ receipt: GitStatusBlock) {
        timeline.presentGitStatus(receipt)
    }

    func repositoryChanged() {
        Task { await workspace.refreshGitAfterToolMutation() }
    }

    func reviewGitCommit(_ id: String) {
        guard let receipt = timeline.block(id: id)?.gitCommit else { return }
        workbench.inspectedGitCommit = receipt
        workbench.rightPanelMode = .commit
    }

    func reviewWorkspaceListing(_ id: String) {
        guard timeline.block(id: id)?.workspaceListing != nil else { return }
        workbench.inspectedWorkspaceListingID = id
        workbench.rightPanelMode = .workspaceListing
    }

    func undoGitCommit(
        _ id: String,
        persist: @escaping @MainActor () async -> Void
    ) {
        guard var receipt = timeline.block(id: id)?.gitCommit,
              receipt.status == .committed else { return }
        receipt.status = .undoing
        receipt.errorMessage = nil
        timeline.updateGitCommit(id: id, receipt: receipt)

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
            timeline.updateGitCommit(id: id, receipt: receipt)
            if workbench.inspectedGitCommit?.hash == receipt.hash {
                workbench.inspectedGitCommit = receipt
            }
            await workspace.refreshGitAfterToolMutation()
            await persist()
        }
    }

    func undoDiffPatch(
        _ id: String,
        persist: @escaping @MainActor () async -> Void
    ) {
        guard let payload = timeline.block(id: id)?.diffPatch,
              payload.status == .applied else { return }
        updateDiffPatch(id: id, status: .undoing, errorMessage: nil)

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
                updateDiffPatch(id: id, status: .undone, errorMessage: nil)
            } catch {
                // Restore already-reverted patches so a partial undo never
                // leaves the workspace between two reviewed states.
                for patch in revertedPatches.reversed() {
                    try? await diffPatchService.apply(
                        patch: patch,
                        workspaceRoot: payload.workspaceRoot,
                        reverse: false,
                        tolerateInaccurateEOF: false
                    )
                }
                updateDiffPatch(
                    id: id,
                    status: .applied,
                    errorMessage: "Undo failed: \(error.localizedDescription)"
                )
            }
            await persist()
        }
    }
}
