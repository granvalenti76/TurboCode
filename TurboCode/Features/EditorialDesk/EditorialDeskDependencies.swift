import Foundation

/// Immutable data passed from the desk to the canonical chat handoff. The
/// feature snapshots this value before awaiting so the chat boundary never
/// needs to inspect the live editor or its observable state.
nonisolated struct EditorialCanonicalPublishRequest: Sendable, Equatable {
    let draft: EditorialDraftSnapshot
    let fileName: String
    let sources: [EditorialSource]
    let metadata: EditorialDeskMetadata

    init(
        draft: EditorialDraftSnapshot,
        fileName: String,
        sources: [EditorialSource],
        metadata: EditorialDeskMetadata = .empty
    ) {
        self.draft = draft
        self.fileName = fileName
        self.sources = sources
        self.metadata = metadata
    }
}

/// The first boundary result distinguishes admission from silent failure. A
/// later slice can refine this into a two-phase publication receipt without
/// changing the sheet's dependency direction.
nonisolated enum EditorialCanonicalHandoffOutcome: Sendable, Equatable {
    case accepted
    case unavailable(String)
}

/// Narrow application port used by the desk to publish into the canonical
/// session. The implementation may currently bridge existing chat services,
/// but the feature must not receive ChatStore or any observable store.
@MainActor
protocol EditorialCanonicalHandoff {
    func publish(
        _ request: EditorialCanonicalPublishRequest
    ) async -> EditorialCanonicalHandoffOutcome
}

/// Composition-time dependencies for one desk presentation. Mutable UI state
/// remains in EditorialDeskViewModel; these values are only service ports.
@MainActor
struct EditorialDeskDependencies {
    let modelClient: any EditorialModelClient
    let sourceService: EditorialSourceService
    let publicationService: EditorialPublicationService
    let canonicalHandoff: any EditorialCanonicalHandoff

    init(
        modelClient: any EditorialModelClient,
        sourceService: EditorialSourceService,
        publicationService: EditorialPublicationService,
        canonicalHandoff: any EditorialCanonicalHandoff
    ) {
        self.modelClient = modelClient
        self.sourceService = sourceService
        self.publicationService = publicationService
        self.canonicalHandoff = canonicalHandoff
    }
}
