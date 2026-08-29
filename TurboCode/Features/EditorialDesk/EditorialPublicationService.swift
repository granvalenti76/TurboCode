import Foundation

/// Actor boundary for the publication side effect. The existing publisher
/// remains a pure, synchronous implementation for focused tests, while UI
/// callers must hop here before touching the workspace filesystem.
actor EditorialPublicationService {
    func publish(
        document: String,
        title: String,
        workspaceRoot: String,
        metadata: EditorialDeskMetadata = .empty
    ) throws -> EditorialPublication {
        try EditorialDraftPublisher.publish(
            document: document,
            title: title,
            workspaceRoot: workspaceRoot,
            metadata: metadata,
            fileManager: FileManager.default
        )
    }
}
