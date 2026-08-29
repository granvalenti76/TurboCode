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
            document: request.draft.document,
            title: request.draft.title,
            workspaceRoot: request.workspaceRoot,
            metadata: request.metadata,
            fileManager: FileManager.default
        )
    }
}

/// Coordinates file writing and canonical handoff as two observable phases.
/// It owns the receipt so retrying the second phase cannot allocate a new file.
@MainActor
@Observable
final class EditorialPublicationCoordinator {
    private let publicationService: EditorialPublicationService
    private let canonicalHandoff: any EditorialCanonicalHandoff
    private var generation: UInt64 = 0
    private var handoffRequest: EditorialCanonicalPublishRequest?

    private(set) var phase: EditorialPublicationPhase = .idle
    private(set) var receipt: EditorialPublication?

    init(
        publicationService: EditorialPublicationService,
        canonicalHandoff: any EditorialCanonicalHandoff
    ) {
        self.publicationService = publicationService
        self.canonicalHandoff = canonicalHandoff
    }

    var isActive: Bool {
        phase.isActive
    }

    /// Writes once, then records the exact canonical request before starting
    /// the handoff. Stale completions cannot replace a newer generation.
    func publish(_ request: EditorialPublicationRequest) async -> EditorialPublicationAttempt {
        guard !phase.isActive, handoffRequest == nil else { return .ignored }
        generation &+= 1
        let admittedGeneration = generation
        phase = .writing
        receipt = nil
        handoffRequest = nil

        do {
            let publication = try await publicationService.publish(request)
            guard generation == admittedGeneration else { return .ignored }
            let canonicalRequest = EditorialCanonicalPublishRequest(
                draft: request.draft,
                fileName: publication.fileName,
                sources: request.sources,
                metadata: request.metadata
            )
            receipt = publication
            handoffRequest = canonicalRequest
            phase = .fileWritten
            return await performHandoff(
                canonicalRequest,
                generation: admittedGeneration,
                receipt: publication
            )
        } catch {
            guard generation == admittedGeneration else { return .ignored }
            phase = .failed
            return .failed(error.localizedDescription)
        }
    }

    /// Reuses the stored handoff request and receipt. No publication service
    /// call is made on this path, which prevents duplicate files on retry.
    func retryHandoff() async -> EditorialPublicationAttempt {
        guard phase == .handoffFailed,
              let handoffRequest,
              let receipt else { return .ignored }
        generation &+= 1
        return await performHandoff(
            handoffRequest,
            generation: generation,
            receipt: receipt
        )
    }

    private func performHandoff(
        _ request: EditorialCanonicalPublishRequest,
        generation: UInt64,
        receipt: EditorialPublication
    ) async -> EditorialPublicationAttempt {
        phase = .handoff
        let outcome = await canonicalHandoff.publish(request)
        guard self.generation == generation else { return .ignored }

        switch outcome {
        case .accepted:
            phase = .completed
            return .completed(receipt)
        case .unavailable(let message):
            phase = .handoffFailed
            return .handoffFailed(
                receipt: receipt,
                request: request,
                message: "File \(receipt.fileName) was saved, but the canonical handoff failed: \(message)"
            )
        }
    }
}
