import Foundation
import FoundationModels

@Generable
struct WriteOnDeviceArguments {
    /// File name in the workspace root, such as "NOTES.md". Paths and directories are not allowed.
    var fileName: String
    /// Complete UTF-8 content to write to the file.
    var content: String
}

/// A minimal root-only writer designed for the weakest on-device model.
///
/// The model supplies no operation, path hierarchy, line range, or revision.
/// TurboCode derives create-versus-replace and the current revision internally,
/// then uses the same atomic transaction and Review/Undo path as edit_file.
struct WriteOnDeviceTool: Tool {
    typealias Arguments = WriteOnDeviceArguments
    typealias Output = ToolCommandOutput

    let workspaceRoot: String
    let reportsChanges: Bool
    let taskScope: AgentTaskPathScope?
    private let receiptRegistry: ToolReceiptRegistry?

    init(
        workspaceRoot: String,
        reportsChanges: Bool = true,
        taskScope: AgentTaskPathScope? = nil,
        receiptRegistry: ToolReceiptRegistry? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.reportsChanges = reportsChanges
        self.taskScope = taskScope
        self.receiptRegistry = receiptRegistry
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            reportsChanges: reportsChanges,
            taskScope: scope,
            receiptRegistry: receiptRegistry
        )
    }

    var name: String { "write_ondevice" }
    var description: String {
        """
        Immediately create or replace one UTF-8 text file in the workspace root.
        Use this tool once when the user asks to write a root-level file. Pass a
        file name such as NOTES.md, never a path or directory, and pass the full
        final file content. Do not ask for confirmation and do not print the file
        content after a successful call.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: WriteOnDeviceArguments) async throws -> ToolCommandOutput {
        let fileName = arguments.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRootFileName(fileName) else {
            return "Error: fileName must be one file name in the workspace root, without '/', '\\', or '..'."
        }
        do {
            try taskScope?.validate(fileName)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        let fileURL: URL
        do {
            fileURL = try WorkspacePathResolver.resolve(fileName, within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        guard !exists || !isDirectory.boolValue else {
            return "Error: '\(fileName)' is a directory. write_ondevice writes files only."
        }

        let operation: String
        let revision: String?
        if exists {
            let currentContent: String
            do {
                currentContent = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                return "Error: Existing file '\(fileName)' is not readable UTF-8 text."
            }
            operation = "replace_file"
            revision = FileRevision.hash(currentContent)
        } else {
            operation = "create"
            revision = nil
        }

        let result = try await ApplyEditsTool(
            workspaceRoot: workspaceRoot,
            reportsChanges: reportsChanges,
            taskScope: taskScope,
            receiptRegistry: receiptRegistry
        ).call(
            arguments: ApplyEditsArguments(
                files: [
                    FileEditRequest(
                        filePath: fileName,
                        revision: revision,
                        operations: [
                            LineEditOperation(
                                operation: operation,
                                startLine: nil,
                                endLine: nil,
                                content: arguments.content
                            )
                        ]
                    )
                ]
            )
        )
        guard result.hasPrefix("Applied ") else { return result }
        return result.replacingText(with: "WRITE_COMPLETE: \(fileName)")
    }

    private func isValidRootFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }
}
