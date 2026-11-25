import Foundation
import FoundationModels

/// Arguments of the connector gateway.
///
/// Doc comments on a `@Generable` property never reach the model: only
/// `@Guide` text and constraints become part of the schema. Without them a
/// local model saw `operation: STRING` and kept writing the connector's tool
/// name there instead of `call`, so every guide below is load-bearing.
@Generable
struct ConnectorArguments {
    @Guide(description: "Connector id from the tool description. May be left out when the session has one connector.")
    var connector: String?
    @Guide(description: "Literally list_tools or call. Never a connector tool name: that goes in toolName.", .anyOf(["list_tools", "call"]))
    var operation: String
    @Guide(description: "With call: the exact tool name returned by list_tools.")
    var toolName: String?
    @Guide(description: "With call: a JSON object with the tool's input, as a string.")
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
            switch Self.intent(operation: arguments.operation, toolName: arguments.toolName) {
            case .listTools:
                let tools = try await client.listTools()
                guard !tools.isEmpty else { return .message("\(connector.name) advertised no tools.") }
                let listing = tools.map { tool in
                    "- \(tool.name): \(tool.description ?? "No description provided.")\n  input: \(tool.inputSchema?.jsonString ?? "{}")"
                }.joined(separator: "\n")
                // The call shape is repeated here because this is the text
                // the model reads right before its first call.
                return .message(listing + "\n\n" + Self.callExample(connector: connector.id, toolName: tools[0].name))

            case .missingToolName:
                return .message("A connector call requires toolName. " + Self.callExample(connector: connector.id, toolName: "<name from list_tools>"))

            case .unknown:
                return .message("Unknown operation. " + Self.callExample(connector: connector.id, toolName: "<name from list_tools>"))

            case .call(let toolName):
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

            }
        } catch MCPLoopbackHTTPError.notRunning {
            // Reported as text so the model tells the user what to start
            // instead of retrying blindly.
            return .message("\(connector.name) is not reachable. Ask the user: \(connector.startHint)")
        } catch {
            return .message("\(connector.name) connector failed: \(error.localizedDescription)")
        }
    }

    /// What a call asks the gateway to do.
    enum Intent: Sendable, Equatable {
        case listTools
        case call(toolName: String)
        case missingToolName
        case unknown
    }

    /// Reads the operation leniently.
    ///
    /// Backends without guided generation ignore the `anyOf` constraint, and
    /// models often name the connector tool as the operation. That intent is
    /// unambiguous, so it is honoured instead of failing: an explicit
    /// `toolName` wins, otherwise a one-word operation is taken as the tool
    /// name. A wrong name is rejected by the connector's own server, which can
    /// reach only the tools that connector advertises.
    static func intent(operation: String, toolName: String?) -> Intent {
        let operation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch operation.lowercased() {
        case "list_tools", "list", "discover":
            return .listTools
        case "call":
            return toolName.isEmpty ? .missingToolName : .call(toolName: toolName)
        default:
            if !toolName.isEmpty { return .call(toolName: toolName) }
            let isOneWord = !operation.isEmpty && !operation.contains(where: \.isWhitespace)
            return isOneWord ? .call(toolName: operation) : .unknown
        }
    }

    /// A literal call the model can copy, used wherever it got the shape wrong.
    static func callExample(connector: String, toolName: String) -> String {
        "To run a tool, set operation to call and put the tool name in toolName: "
            + #"{"connector":"\#(connector)","operation":"call","toolName":"\#(toolName)","argumentsJSON":"{}"}"#
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
