import Foundation
import FoundationModels

nonisolated struct ToolOutputResolution: Sendable {
    let text: String
    let receipt: ToolReceipt?
}

/// Converts provider structure segments directly into typed Core receipts.
/// Model-facing text is deliberately ignored so widget data cannot be flattened
/// and parsed back into an application payload.
nonisolated enum ToolReceiptRouter {
    /// Resolves the compact output envelope used by mutating native tools.
    /// Legacy typed outputs, such as `list_workspace`, continue through the
    /// schema-specific fallback while their adapters are migrated independently.
    static func resolve(
        for call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        registry: ToolReceiptRegistry,
        workspaceName: String?,
        capturedAt: Date = .now
    ) async -> ToolOutputResolution {
        for segment in output.segments {
            guard case .structure(let structured) = segment,
                  let commandOutput = try? ToolCommandOutput(structured.content) else {
                continue
            }
            let receipt: ToolReceipt? = if let token = commandOutput.receiptToken {
                await registry.take(token)
            } else {
                nil
            }
            return ToolOutputResolution(
                text: commandOutput.text,
                receipt: receipt
            )
        }

        return ToolOutputResolution(
            text: rawText(from: output),
            receipt: receipt(
                for: call,
                output: output,
                workspaceName: workspaceName,
                capturedAt: capturedAt
            )
        )
    }

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

    private static func rawText(from output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment -> String? in
            switch segment {
            case .text(let value):
                return value.content
            case .structure(let value):
                return value.content.jsonString
            default:
                return nil
            }
        }.joined()
    }
}
