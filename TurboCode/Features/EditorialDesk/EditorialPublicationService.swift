import Foundation
import Observation

/// Actor boundary for the publication side effect. The existing publisher
/// remains a pure, synchronous implementation for focused tests, while UI
/// callers must hop here before touching the workspace filesystem.
actor EditorialPublicationService {
    func publish(
        _ request: EditorialPublicationRequest
    ) throws -> EditorialPublication {
        try EditorialDraftPublisher.publish(
            draft: request.draft,
            draftID: request.draftID,
            targetRelativePath: request.targetRelativePath,
            workspaceRoot: request.workspaceRoot,
            metadata: request.metadata,
            fileManager: FileManager.default
        )
    }
}

/// Coordinates the filesystem write and the native timeline receipt. The
/// presenter cannot start a model turn, preserving Publish Draft as one clear
/// application action.
@MainActor
@Observable
final class EditorialPublicationCoordinator {
    private let publicationService: EditorialPublicationService
    private let receiptPresenter: any EditorialPublicationReceiptPresenting
    private var generation: UInt64 = 0

    private(set) var phase: EditorialPublicationPhase = .idle
    private(set) var receipt: EditorialPublication?

    init(
        publicationService: EditorialPublicationService,
        receiptPresenter: any EditorialPublicationReceiptPresenting
    ) {
        self.publicationService = publicationService
        self.receiptPresenter = receiptPresenter
    }

    var isActive: Bool {
        phase.isActive
    }

    /// Writes once and presents the immutable result. Stale completions cannot
    /// replace a newer generation or append an unrelated timeline receipt.
    func publish(_ request: EditorialPublicationRequest) async -> EditorialPublicationAttempt {
        guard !phase.isActive else { return .ignored }
        generation &+= 1
        let admittedGeneration = generation
        phase = .writing
        receipt = nil

        do {
            let publication = try await publicationService.publish(request)
            guard generation == admittedGeneration else { return .ignored }
            receipt = publication
            let block = EditorialPublicationBlock(
                draftID: publication.draftID,
                workspaceRoot: request.workspaceRoot,
                relativePath: publication.relativePath,
                fileName: publication.fileName,
                wordCount: request.draft.document.split(whereSeparator: { $0.isWhitespace }).count,
                publishedAt: publication.publishedAt
            )
            await receiptPresenter.present(block)
            guard generation == admittedGeneration else { return .ignored }
            phase = .completed
            return .completed(publication)
        } catch {
            guard generation == admittedGeneration else { return .ignored }
            phase = .failed
            return .failed(error.localizedDescription)
        }
    }
}
