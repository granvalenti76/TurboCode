import Foundation
import FoundationModels

@Generable
struct ConnectorArguments {
    /// Identifier of the connector, as listed in the tool description. May be
    /// omitted when the session has exactly one connector.
    var connector: String?
    /// Use `list_tools` before the first call to a connector, then `call`.
    var operation: String
    /// Exact tool name returned by `list_tools`.
    var toolName: String?
    /// JSON object passed to the selected tool.
    var argumentsJSON: String?
}

/// One stable gateway to the connectors the user turned on for this session.
///
/// Like the Safari and Xcode gateways it keeps a single schema while the apps'
/// own tool catalogs change. The tool is registered only when the session has
/// at least one connector, and it can reach nothing but those: the list is
/// fixed when the session is built, so turning a connector off rebuilds the
/// session without it.
///
/// Calls are not approved one by one. Enabling a connector for a session is
/// the user's consent to let the model drive that app there, and a sculpting
/// request is made of dozens of small calls that the app itself can undo.
struct ConnectorTool: Tool {
    typealias Arguments = ConnectorArguments
    typealias Output = Prompt

    /// Bounds what one call can add to the conversation.
    static let maximumImageBytes = 10 * 1_024 * 1_024
    static let maximumImagesPerCall = 4
    static let maximumTextCharacters = 20_000

    /// What one call produced, kept apart from `Prompt` so tests can read it.
    enum Outcome: Sendable, Equatable {
        case message(String)
        case images(text: String, attachments: [ComposerImageAttachment])
    }

    let connectors: [MCPConnector]
    let clients: MCPConnectorClients
    /// Asked on every call, like `vm_view_image`: a server without vision
    /// rejects any request that contains an image.
    let supportsVision: @Sendable () async -> Bool

    init(
        connectors: [MCPConnector],
        clients: MCPConnectorClients = .shared,
        supportsVision: @escaping @Sendable () async -> Bool
    ) {
        self.connectors = connectors
        self.clients = clients
        self.supportsVision = supportsVision
    }

    var name: String { ToolCapabilityID.connector.rawValue }

    var description: String {
        let list = connectors.map { "\($0.id): \($0.modelGuidance)" }.joined(separator: " ")
        return "Work with another app on the user's Mac through a connector the user enabled for this session. Use operation list_tools first, then call. Connectors: \(list)"
    }

    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ConnectorArguments) async throws -> Prompt {
        switch await run(arguments: arguments) {
        case .message(let text):
            Prompt(text)
        case .images(let text, let attachments):
            ComposerImageAttachment.prompt(text: text, attachments: attachments)
        }
    }

    func run(arguments: ConnectorArguments) async -> Outcome {
        guard let connector = resolve(arguments.connector) else {
            let known = connectors.map(\.id).joined(separator: ", ")
            return .message("Unknown connector. This session has: \(known).")
        }
        let client = await clients.client(for: connector)
        do {
            switch arguments.operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "list_tools", "list", "discover":
                let tools = try await client.listTools()
                guard !tools.isEmpty else { return .message("\(connector.name) advertised no tools.") }
                return .message(tools.map { tool in
                    "- \(tool.name): \(tool.description ?? "No description provided.")\n  input: \(tool.inputSchema?.jsonString ?? "{}")"
                }.joined(separator: "\n"))

            case "call":
                let toolName = arguments.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !toolName.isEmpty else {
                    return .message("A connector call requires toolName. Use list_tools first.")
                }
                let trimmed = arguments.argumentsJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let value = try? JSONDecoder().decode(
                    MCPJSONValue.self,
                    from: Data((trimmed.isEmpty ? "{}" : trimmed).utf8)
                ), value.objectValue != nil else {
                    return .message("argumentsJSON must be a valid JSON object.")
                }
                return await Self.outcome(
                    for: try await client.call(tool: toolName, arguments: value),
                    supportsVision: supportsVision
                )

            default:
                return .message("Unknown operation. Use list_tools or call.")
            }
        } catch MCPLoopbackHTTPError.notRunning {
            // Reported as text so the model tells the user what to start
            // instead of retrying blindly.
            return .message("\(connector.name) is not reachable. Ask the user: \(connector.startHint)")
        } catch {
            return .message("\(connector.name) connector failed: \(error.localizedDescription)")
        }
    }

    private func resolve(_ id: String?) -> MCPConnector? {
        let wanted = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if wanted.isEmpty { return connectors.count == 1 ? connectors.first : nil }
        return connectors.first { $0.id == wanted }
    }

    /// Turns an MCP result into text plus the images the model may see.
    ///
    /// Image blocks are never rendered as text: their base64 payload would
    /// fill the context without the model being able to read it.
    static func outcome(
        for result: MCPToolResult,
        supportsVision: @Sendable () async -> Bool
    ) async -> Outcome {
        var texts: [String] = []
        var images: [Data] = []
        var skipped = 0
        for block in result.content {
            guard let object = block.objectValue else { continue }
            switch object["type"]?.stringValue {
            case "text":
                if let text = object["text"]?.stringValue { texts.append(text) }
            case "image":
                if images.count < maximumImagesPerCall,
                   let encoded = object["data"]?.stringValue,
                   encoded.utf8.count <= maximumImageBytes * 4 / 3 + 4,
                   let data = Data(base64Encoded: encoded) {
                    images.append(data)
                } else {
                    skipped += 1
                }
            default:
                skipped += 1
            }
        }
        if texts.isEmpty, let structured = result.structuredContent {
            texts.append(structured.jsonString)
        }
        var text = texts.joined(separator: "\n")
        if text.count > maximumTextCharacters {
            text = String(text.prefix(maximumTextCharacters)) + "\n[output truncated]"
        }
        if result.isError { text = "Tool error:\n" + text }
        if skipped > 0 { text += "\n[\(skipped) content block(s) not shown]" }

        guard !images.isEmpty else { return .message(text.isEmpty ? "Done." : text) }
        guard await supportsVision() else {
            return .message(text + "\n[\(images.count) image(s) not shown: the active model cannot see images]")
        }
        let attachments = images.enumerated().compactMap { index, data in
            try? ComposerImageLoader.load(
                data: data,
                fileName: "connector-\(index + 1).png",
                maxSourceByteCount: maximumImageBytes
            )
        }
        guard !attachments.isEmpty else { return .message(text + "\n[image could not be decoded]") }
        return .images(text: text.isEmpty ? "Image:" : text, attachments: attachments)
    }
}
