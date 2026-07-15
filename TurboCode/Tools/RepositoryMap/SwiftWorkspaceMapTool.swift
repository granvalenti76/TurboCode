import Foundation
import FoundationModels

@Generable
struct SwiftWorkspaceMapArguments {
    /// Operation: overview, symbols, related, or refresh.
    var action: String
    /// Symbol, type, file name, or architectural term for symbols and related.
    var query: String?
    /// Optional workspace-relative Swift file or directory used to narrow results.
    var path: String?
}

/// One stable, flat tool surface backed by compact or enhanced map services.
struct SwiftWorkspaceMapTool: Tool {
    typealias Arguments = SwiftWorkspaceMapArguments
    typealias Output = String

    let workspaceRoot: String
    let detail: RepositoryMapDetail
    let contextWindowTokens: Int

    var name: String { "swift_workspace_map" }
    var description: String {
        let relationshipGuidance = detail == .enhanced
            ? "The enhanced map also includes imports and referenced type relationships."
            : "The compact map is bounded for a 32k model context."
        return """
        Navigate an existing Swift, SwiftUI, Xcode, or Swift Package workspace
        without reading entire files. Call overview before broad project work,
        symbols to locate declarations and line numbers, and related to find the
        files surrounding a type. Use an optional workspace-relative path to
        narrow large results. Call refresh only when files changed outside
        TurboCode. \(relationshipGuidance) After using the map, call read_file
        only for the precise implementation ranges required by the task.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: SwiftWorkspaceMapArguments) async throws -> String {
        do {
            return try await RepositoryMapService(
                workspaceRoot: workspaceRoot,
                detail: detail,
                outputCharacterBudget: detail.outputCharacterBudget(
                    contextWindowTokens: contextWindowTokens
                )
            ).response(
                action: arguments.action,
                query: arguments.query,
                path: arguments.path
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
