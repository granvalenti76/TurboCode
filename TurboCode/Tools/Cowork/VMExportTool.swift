import Foundation
import FoundationModels

@Generable
struct VMExportArguments {
    /// Optional one-line description of what the deliverables are.
    var summary: String?
}

/// Lets the agent declare its work finished and learn exactly what the user
/// will be offered. It copies nothing: deliverables reach the Mac only when
/// the user reviews and approves them in Review & Export.
struct VMExportTool: Tool {
    typealias Arguments = VMExportArguments
    typealias Output = String

    static let maximumListedFiles = 30

    let context: CoworkSessionContext

    var name: String { ToolCapabilityID.vmExport.rawValue }
    var description: String {
        """
        Call when your deliverables in /out are complete. Returns the files the \
        user will be offered in Review & Export. It does not copy anything to \
        the Mac and never moves files.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: VMExportArguments) async throws -> String {
        // /out is the session outbox on the Mac; listing it needs no VM.
        let files = CoworkExportPlanner.deliverables(in: context.configuration.outbox)
        guard !files.isEmpty else {
            return "No deliverables are in /out yet. Copy the finished files there first."
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var lines = [
            "\(files.count) deliverable\(files.count == 1 ? "" : "s") (\(total.formatted(.byteCount(style: .file)))) are ready.",
        ]
        lines += files.prefix(Self.maximumListedFiles).map {
            "- \($0.path) (\($0.size.formatted(.byteCount(style: .file))))"
        }
        if files.count > Self.maximumListedFiles {
            lines.append("- … \(files.count - Self.maximumListedFiles) more")
        }
        lines.append("The user exports them with Review & Export in the toolbar or composer. Do not move them.")
        return lines.joined(separator: "\n")
    }
}
