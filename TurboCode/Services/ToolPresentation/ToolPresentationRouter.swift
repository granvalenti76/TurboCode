import FoundationModels

nonisolated enum ToolPresentation: Sendable {
    case workspaceListing(WorkspaceListingBlock)
}

/// Decodes structured tool outputs into persisted timeline payloads. ChatStore
/// coordinates placement only; it does not know individual output schemas.
nonisolated enum ToolPresentationRouter {
    static func presentation(
        for call: Transcript.ToolCall,
        output: Transcript.ToolOutput
    ) -> ToolPresentation? {
        guard call.toolName == "list_workspace" else { return nil }
        for segment in output.segments {
            guard case .structure(let structured) = segment,
                  let listing = try? WorkspaceListingToolOutput(structured.content) else {
                continue
            }
            let entries = listing.entries.compactMap { entry -> WorkspaceListingEntry? in
                guard let kind = WorkspaceListingEntryKind(rawValue: entry.kind) else { return nil }
                return WorkspaceListingEntry(
                    name: entry.name,
                    relativePath: entry.relativePath,
                    kind: kind,
                    sizeBytes: entry.sizeBytes,
                    modifiedAt: entry.modifiedAt,
                    fileExtension: entry.fileExtension
                )
            }
            return .workspaceListing(
                WorkspaceListingBlock(
                    toolCallID: call.id,
                    path: listing.path,
                    entries: entries,
                    totalCount: listing.totalCount,
                    isTruncated: listing.isTruncated,
                    errorMessage: listing.errorMessage
                )
            )
        }
        return nil
    }
}
