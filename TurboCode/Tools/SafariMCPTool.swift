import Foundation
import FoundationModels

@Generable
struct SafariMCPArguments {
    /// Use `list_tools` before the first browser action, then `call`.
    var operation: String
    /// Exact MCP tool name returned by `list_tools`.
    var toolName: String?
    /// JSON object passed to the selected MCP tool.
    var argumentsJSON: String?
}

/// Stable Foundation Models gateway for the dynamically discovered Safari MCP
/// tools. Keeping one schema avoids rebuilding the session when Safari's tool
/// catalog changes and keeps the cacheable instruction prefix stable.
struct SafariMCPTool: Tool {
    typealias Arguments = SafariMCPArguments
    typealias Output = String

    let client: SafariMCPClient
    let enabled: Bool

    init(
        client: SafariMCPClient = .shared,
        enabled: Bool
    ) {
        self.client = client
        self.enabled = enabled
    }

    var name: String { "safari_mcp" }

    var description: String {
        "Use the explicitly enabled Safari MCP skill to discover and call safaridriver browser tools. Safari is not started until this tool is called."
    }

    var includesSchemaInInstructions: Bool { true }

    func call(arguments: SafariMCPArguments) async throws -> String {
        guard enabled else {
            return "Safari MCP is disabled in Settings > Agents > Experimental."
        }

        switch arguments.operation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "list_tools", "list", "discover":
            let tools = try await client.listTools()
            guard !tools.isEmpty else {
                return "Safari MCP is running but advertised no tools."
            }
            return tools.map { tool in
                let description = tool.description ?? "No description provided."
                let schema = tool.inputSchema?.compactJSONString(maxCharacters: 900)
                    ?? "{}"
                return "- \(tool.name): \(description)\n  input: \(schema)"
            }.joined(separator: "\n")

        case "call":
            let name = arguments.toolName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                return "Safari MCP call requires toolName. Use list_tools first."
            }
            let source = arguments.argumentsJSON?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? arguments.argumentsJSON!
                : "{}"
            guard let data = source.data(using: .utf8),
                  let value = try? JSONDecoder().decode(
                    SafariMCPJSONValue.self,
                    from: data
                  ),
                  value.objectValue != nil else {
                return "Safari MCP argumentsJSON must be a valid JSON object."
            }
            return try await client.call(tool: name, arguments: value)

        default:
            return "Unknown Safari MCP operation. Use list_tools or call."
        }
    }
}
