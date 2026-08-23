import Foundation
import FoundationModels

/// Adapts one validated external tool to Foundation Models without inventing
/// a generic `run_plugin` capability. The model sees the plugin's real name and
/// the same primitive object schema that Codex receives.
struct TypeScriptPluginToolAdapter: @unchecked Sendable, Tool {
    let name: String
    let description: String
    let includesSchemaInInstructions = true
    let parameters: GenerationSchema

    private let host: TypeScriptPluginHost
    private let toolName: String

    init(
        snapshot: TypeScriptPluginToolSnapshot,
        host: TypeScriptPluginHost
    ) throws {
        self.name = snapshot.id.rawValue
        self.description = snapshot.description
        self.toolName = snapshot.id.toolName
        self.parameters = try Self.generationSchema(from: snapshot.inputSchema)
        self.host = host
    }

    init(
        manifest: TypeScriptPluginManifest,
        tool: TypeScriptPluginToolManifest,
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
        return try await host.call(tool: toolName, arguments: value)
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
