import Foundation

/// Descriptor published by an MCP server through `tools/list`.
nonisolated struct MCPToolDescriptor: Codable, Equatable, Hashable, Sendable {
    let name: String
    let description: String?
    let inputSchema: MCPJSONValue?

    init(
        name: String,
        description: String? = nil,
        inputSchema: MCPJSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// MCP keeps tool failures inside a successful JSON-RPC result. Retaining the
/// raw content lets each model adapter decide how to represent rich output.
nonisolated struct MCPToolResult: Equatable, Sendable {
    let content: [MCPJSONValue]
    let structuredContent: MCPJSONValue?
    let isError: Bool

    var text: String {
        let textBlocks = content.compactMap { item -> String? in
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "text" else { return nil }
            return object["text"]?.stringValue
        }
        var parts = textBlocks
        if textBlocks.isEmpty, !content.isEmpty {
            parts.append(contentsOf: content.map(\.jsonString))
        }
        if let structuredContent {
            parts.append(structuredContent.jsonString)
        }
        return parts.isEmpty ? "{}" : parts.joined(separator: "\n")
    }

    var renderedForModel: String {
        let prefix = isError ? "MCP tool error" : "MCP tool result"
        return "\(prefix):\n\(text)"
    }
}
