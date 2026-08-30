import Foundation
import FoundationModels

/// Converts provider structure segments directly into typed Core receipts.
/// Model-facing text is deliberately ignored so widget data cannot be flattened
/// and parsed back into an application payload.
nonisolated enum ToolReceiptRouter {
    static func receipt(
        for call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        workspaceName: String?,
        capturedAt: Date = .now
    ) -> ToolReceipt? {
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
                    errorMessage: listing.errorMessage,
                    capturedAt: capturedAt,
                    workspaceName: workspaceName
                )
            )
        }
        return nil
    }
}
