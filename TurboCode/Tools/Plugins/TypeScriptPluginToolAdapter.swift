import Foundation
import FoundationModels

/// Adapts one validated external tool to Foundation Models without inventing
/// a generic `run_plugin` capability. The model sees a provider-safe alias while
/// the host call below keeps the plugin's original tool name.
struct TypeScriptPluginToolAdapter: @unchecked Sendable, Tool {
    let name: String
    let description: String
    let includesSchemaInInstructions = true
    let parameters: GenerationSchema

    private let host: TypeScriptPluginHost
    private let manifest: TypeScriptPluginManifest
    private let pluginRoot: URL
    private let toolName: String

    init(
        snapshot: TypeScriptPluginToolSnapshot,
        manifest: TypeScriptPluginManifest,
        pluginRoot: URL,
        host: TypeScriptPluginHost
    ) throws {
        self.name = snapshot.id.codexName
        self.description = snapshot.description
        self.manifest = manifest
        self.pluginRoot = pluginRoot
        self.toolName = snapshot.id.toolName
        self.parameters = try Self.generationSchema(from: snapshot.inputSchema)
        self.host = host
    }

    init(
        manifest: TypeScriptPluginManifest,
        tool: TypeScriptPluginToolManifest,
        pluginRoot: URL,
        host: TypeScriptPluginHost
    ) throws {
        try self.init(
            snapshot: TypeScriptPluginToolSnapshot(
                id: TypeScriptPluginToolID(
                    pluginID: manifest.id,
                    toolName: tool.name
                ),
                description: tool.description,
                inputSchema: tool.inputSchema
            ),
            manifest: manifest,
            pluginRoot: pluginRoot,
            host: host
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        guard let data = arguments.jsonString.data(using: .utf8) else {
            throw TypeScriptPluginToolAdapterError.invalidArguments
        }
        let value: PluginJSONValue
        do {
            value = try JSONDecoder().decode(PluginJSONValue.self, from: data)
        } catch {
            throw TypeScriptPluginToolAdapterError.invalidArguments
        }
        let result = try await host.call(tool: toolName, arguments: value)
        let widget = result.widget.flatMap { invocation -> TypeScriptPluginWidgetReceipt? in
            guard let definition = manifest.widgets.first(where: { $0.id == invocation.id }) else {
                return nil
            }
            return TypeScriptPluginWidgetReceipt(
                pluginID: manifest.id,
                widgetID: definition.id,
                title: definition.title,
                entrypoint: definition.entrypoint,
                pluginRoot: pluginRoot.path,
                props: invocation.props
            )
        }
        return TypeScriptPluginToolResultCodec.encodeForModel(
            TypeScriptPluginToolResultEnvelope(
                text: result.text,
                isError: result.isError,
                widget: widget
            )
        )
    }

    private static func generationSchema(
        from schema: PluginJSONValue
    ) throws -> GenerationSchema {
        guard case .object(let properties)? = schema["properties"],
              case .array(let requiredValues)? = schema["required"] else {
            throw TypeScriptPluginToolAdapterError.unsupportedSchema
        }
        let required = Set(requiredValues.compactMap(\.stringValue))
        guard required.count == properties.count else {
            throw TypeScriptPluginToolAdapterError.unsupportedSchema
        }

        let dynamicProperties = try properties.keys.sorted().map { name in
            guard case .object(let property) = properties[name] ?? .null,
                  let type = property["type"]?.stringValue else {
                throw TypeScriptPluginToolAdapterError.unsupportedSchema
            }
            return DynamicGenerationSchema.Property(
                name: name,
                schema: dynamicSchema(for: type)
            )
        }
        return try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "Arguments",
                properties: dynamicProperties
            ),
            dependencies: []
        )
    }

    private static func dynamicSchema(
        for type: String
    ) -> DynamicGenerationSchema {
        switch type {
        case "string": DynamicGenerationSchema(type: String.self)
        case "integer": DynamicGenerationSchema(type: Int.self)
        case "number": DynamicGenerationSchema(type: Double.self)
        case "boolean": DynamicGenerationSchema(type: Bool.self)
        default: DynamicGenerationSchema(type: String.self)
        }
    }
}

nonisolated enum TypeScriptPluginToolAdapterError: LocalizedError, Sendable, Equatable {
    case invalidArguments
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "The plugin tool received invalid arguments."
        case .unsupportedSchema: "The plugin tool schema cannot be represented by Foundation Models."
        }
    }
}
