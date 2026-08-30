import Foundation

/// Immutable inputs for one filesystem publication. Existing selections carry
/// a bounded relative path; new drafts leave it nil so the publisher can choose
/// a collision-free Markdown filename.
nonisolated struct EditorialPublicationRequest: Sendable, Equatable {
    let draft: EditorialDraftSnapshot
    let draftID: UUID
    let targetRelativePath: String?
    let workspaceRoot: String
    let metadata: EditorialDeskMetadata
    let reviewContext: EditorialReviewContext?

    init(
        draft: EditorialDraftSnapshot,
        draftID: UUID = UUID(),
        targetRelativePath: String? = nil,
        workspaceRoot: String,
        metadata: EditorialDeskMetadata = .empty,
        reviewContext: EditorialReviewContext? = nil
    ) {
        self.draft = draft
        self.draftID = draftID
        self.targetRelativePath = targetRelativePath
        self.workspaceRoot = workspaceRoot
        self.metadata = metadata
        self.reviewContext = reviewContext
    }
}

/// Outcome returned by the publication coordinator. A successful receipt has
/// already been written and projected into the local conversation timeline.
nonisolated enum EditorialPublicationAttempt: Sendable, Equatable {
    case completed(EditorialPublication)
    case failed(String)
    case ignored
}

/// Narrow application port for the native publication widget. The feature
/// never receives the timeline store or an ordinary model-message sender.
@MainActor
protocol EditorialPublicationReceiptPresenting {
    func present(_ publication: EditorialPublicationBlock) async
}

/// Composition-time dependencies for one desk presentation. Mutable UI state
/// remains in EditorialDeskViewModel; these values are only service ports.
@MainActor
struct EditorialDeskDependencies {
    let modelClient: any EditorialModelClient
    let sourceService: EditorialSourceService
    let publicationService: EditorialPublicationService
    let draftLibrary: EditorialDraftLibraryService
    let receiptPresenter: any EditorialPublicationReceiptPresenting

    init(
        modelClient: any EditorialModelClient,
        sourceService: EditorialSourceService,
        publicationService: EditorialPublicationService,
        draftLibrary: EditorialDraftLibraryService,
        receiptPresenter: any EditorialPublicationReceiptPresenting
    ) {
        self.modelClient = modelClient
        self.sourceService = sourceService
        self.publicationService = publicationService
        self.draftLibrary = draftLibrary
        self.receiptPresenter = receiptPresenter
    }
}
