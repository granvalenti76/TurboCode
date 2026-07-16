import Foundation
import FoundationModels

@Generable
struct RemoveFileArguments {
    /// Path of the file to remove, relative to the workspace root.
    var path: String
}

/// Minimal destructive tool for models that benefit from a flat schema.
/// Authorization is owned by the app and is intentionally absent from the
/// model-facing arguments and result protocol.
struct RemoveFileTool: Tool {
    typealias Arguments = RemoveFileArguments
    typealias Output = String

    let workspaceRoot: String
    private let requestApproval: @Sendable (PendingToolApproval) async -> String

    init(
        workspaceRoot: String,
        requestApproval: @escaping @Sendable (PendingToolApproval) async -> String = {
            await ToolApprovalRegistry.shared.request($0)
        }
    ) {
        self.workspaceRoot = workspaceRoot
        self.requestApproval = requestApproval
    }

    var name: String { "remove_file" }
    var description: String {
        "Remove one existing file inside the workspace. The path may be relative to the workspace root. Directories and symbolic links are rejected."
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: RemoveFileArguments) async throws -> String {
        let requestedPath = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPath.isEmpty else {
            return "Error: path cannot be empty."
        }

        let validation: ValidatedRemoval
        do {
            validation = try validateRemoval(path: requestedPath, within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let workspaceRoot = workspaceRoot
        let request = PendingToolApproval(
            id: UUID().uuidString,
            operation: "removeFile",
            path: validation.url.path,
            destination: nil,
            summary: "Permanently delete '\(validation.relativePath)'?",
            action: {
                do {
                    let current = try validateRemoval(
                        path: requestedPath,
                        within: workspaceRoot
                    )
                    try FileManager.default.removeItem(at: current.url)
                    return "Removed \(current.relativePath)."
                } catch {
                    return "Error: \(error.localizedDescription)"
                }
            }
        )
        return await requestApproval(request)
    }
}

nonisolated private struct ValidatedRemoval: Sendable {
    let url: URL
    let relativePath: String
}

nonisolated private func validateRemoval(
    path: String,
    within workspaceRoot: String
) throws -> ValidatedRemoval {
    let resolved = try WorkspacePathResolver.resolve(path, within: workspaceRoot)
    let root = URL(fileURLWithPath: workspaceRoot)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    guard resolved.path != root.path else {
        throw RemoveFileError.fileRequired
    }

    let lexicalRoot = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
    let lexicalURL = ((path as NSString).isAbsolutePath
        ? URL(fileURLWithPath: path)
        : lexicalRoot.appendingPathComponent(path))
        .standardizedFileURL
    let attributes = try FileManager.default.attributesOfItem(atPath: lexicalURL.path)
    guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
        throw RemoveFileError.symbolicLinkNotAllowed
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
        throw RemoveFileError.fileNotFound(path)
    }
    guard !isDirectory.boolValue else {
        throw RemoveFileError.directoryNotAllowed
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw RemoveFileError.fileRequired
    }

    let relativePath = String(resolved.path.dropFirst(root.path.count + 1))
    return ValidatedRemoval(url: resolved, relativePath: relativePath)
}

nonisolated private enum RemoveFileError: LocalizedError {
    case fileNotFound(String)
    case directoryNotAllowed
    case symbolicLinkNotAllowed
    case fileRequired

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "File not found: '\(path)'."
        case .directoryNotAllowed: "remove_file can remove files only, not directories."
        case .symbolicLinkNotAllowed: "remove_file does not remove symbolic links."
        case .fileRequired: "remove_file requires a file inside the workspace."
        }
    }
}
