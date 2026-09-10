import Foundation
import FoundationModels

@Generable
struct XcodeMCPArguments {
    /// Use list_tools before call when the server catalog is not yet known.
    var operation: String
    /// Exact tool name returned by Xcode MCP tools/list.
    var toolName: String?
    /// JSON object passed to the selected Xcode MCP tool.
    var argumentsJSON: String?
}

/// Stable Foundation Models gateway for Xcode's dynamic MCP catalog. A
/// gateway keeps nested and provider-incompatible JSON schemas intact while
/// still exposing the complete discovered catalog to the model.
struct XcodeMCPTool: Tool {
    typealias Arguments = XcodeMCPArguments
    typealias Output = String

    let client: XcodeMCPClient
    let enabled: Bool

    init(
        client: XcodeMCPClient = .shared,
        enabled: Bool
    ) {
        self.client = client
        self.enabled = enabled
    }

    var name: String { ToolCapabilityID.xcodeMCP.rawValue }

    var description: String {
        "Discover and call the tools published by the Xcode MCP service. Xcode must allow external agents in Intelligence settings."
    }

    var includesSchemaInInstructions: Bool { true }

    func call(arguments: XcodeMCPArguments) async throws -> String {
        guard enabled else {
            return "Xcode MCP is disabled in Settings > Agents > Experimental."
        }

        switch arguments.operation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "list_tools", "list", "discover":
            let tools = try await client.listTools()
            guard !tools.isEmpty else {
                return "Xcode MCP is connected but advertised no tools."
            }
            return tools.map { tool in
                "- \(tool.name): \(tool.description ?? "No description provided.")\n  input: \(tool.inputSchema?.jsonString ?? "{}")"
            }.joined(separator: "\n")

        case "call":
            let name = arguments.toolName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                return "Xcode MCP call requires toolName. Use list_tools first."
            }
            let source = arguments.argumentsJSON?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? arguments.argumentsJSON!
                : "{}"
            guard let data = source.data(using: .utf8),
                  let value = try? JSONDecoder().decode(
                    MCPJSONValue.self,
                    from: data
                  ),
                  value.objectValue != nil else {
                return "Xcode MCP argumentsJSON must be a valid JSON object."
            }
            let result = try await client.call(tool: name, arguments: value)
            return result.renderedForModel

        default:
            return "Unknown Xcode MCP operation. Use list_tools or call."
        }
    }
}
