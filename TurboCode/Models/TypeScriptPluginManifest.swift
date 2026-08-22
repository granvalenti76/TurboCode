import Foundation

/// JSON value used at the plugin boundary. Keeping the tree typed prevents
/// plugin payloads from crossing the actor boundary as `[String: Any]`.
nonisolated enum PluginJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([PluginJSONValue])
    case object([String: PluginJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PluginJSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(_ key: String) -> PluginJSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}

nonisolated struct TypeScriptPluginRuntime: Codable, Sendable, Equatable {
    let kind: String
    let node: String

    init(node: String = "24.x") {
        self.kind = "node"
        self.node = node
    }
}

nonisolated struct TypeScriptPluginToolManifest: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: PluginJSONValue
}

/// Versioned metadata for one compiled TypeScript plugin.
nonisolated struct TypeScriptPluginManifest: Codable, Sendable, Equatable {
    static let currentManifestVersion = 1
    static let supportedProtocolVersion = 1
    static let supportedNodeMajor = 24

    let manifestVersion: Int
    let id: String
    let name: String
    let version: String
    let entrypoint: String
    let runtime: TypeScriptPluginRuntime
    let tools: [TypeScriptPluginToolManifest]

    init(
        manifestVersion: Int = Self.currentManifestVersion,
        id: String,
        name: String,
        version: String,
        entrypoint: String,
        runtime: TypeScriptPluginRuntime = .init(),
        tools: [TypeScriptPluginToolManifest]
    ) {
        self.manifestVersion = manifestVersion
        self.id = id
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.runtime = runtime
        self.tools = tools
    }

    /// Validates host-owned fields before a child process is allowed to run.
    func validate(at pluginRoot: URL) throws {
        guard manifestVersion == Self.currentManifestVersion else {
            throw TypeScriptPluginManifestError.unsupportedManifestVersion(manifestVersion)
        }
        guard isValidIdentifier(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TypeScriptPluginManifestError.invalidIdentifier
        }
        guard runtime.kind == "node", runtime.node == "24.x" else {
            throw TypeScriptPluginManifestError.unsupportedNodeRange(runtime.node)
        }
        guard !tools.isEmpty else {
            throw TypeScriptPluginManifestError.noTools
        }
        var names = Set<String>()
        for tool in tools {
            guard isValidIdentifier(tool.name), names.insert(tool.name).inserted else {
                throw TypeScriptPluginManifestError.invalidToolName(tool.name)
            }
            try Self.validateSchema(tool.inputSchema, toolName: tool.name)
        }

        let root = pluginRoot.standardizedFileURL.resolvingSymlinksInPath()
        let entryURL = pluginRoot.appendingPathComponent(entrypoint).standardizedFileURL
        let resolvedEntry = entryURL.resolvingSymlinksInPath()
        guard resolvedEntry.path.hasPrefix(root.path + "/"),
              FileManager.default.isReadableFile(atPath: resolvedEntry.path) else {
            throw TypeScriptPluginManifestError.invalidEntrypoint(entrypoint)
        }
    }

    private static func validateSchema(
        _ schema: PluginJSONValue,
        toolName: String
    ) throws {
        // JSON Schema belongs to the plugin/provider contract. TurboCode only
        // requires an object root here; it must not reject nested schemas,
        // arrays, nullable values, or provider-specific keywords merely
        // because one native model adapter cannot express them.
        guard case .object = schema,
              schema["type"]?.stringValue == "object" else {
            throw TypeScriptPluginManifestError.unsupportedSchema(toolName)
        }
    }

    private func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 80
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 80
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

nonisolated enum TypeScriptPluginManifestError: LocalizedError, Sendable, Equatable {
    case unsupportedManifestVersion(Int)
    case invalidIdentifier
    case unsupportedNodeRange(String)
    case noTools
    case invalidToolName(String)
    case unsupportedSchema(String)
    case invalidEntrypoint(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedManifestVersion(let version):
            "Unsupported TypeScript plugin manifest version: \(version)."
        case .invalidIdentifier:
            "Plugin identifiers and names must be non-empty safe identifiers."
        case .unsupportedNodeRange(let range):
            "TypeScript plugins require Node 24.x; manifest requested \(range)."
        case .noTools:
            "A TypeScript plugin must declare at least one tool."
        case .invalidToolName(let name):
            "Invalid or duplicate plugin tool name: \(name)."
        case .unsupportedSchema(let tool):
            "Tool \(tool) uses a JSON Schema shape not supported by TurboCode."
        case .invalidEntrypoint(let path):
            "Plugin entrypoint is missing or escapes the plugin directory: \(path)."
        }
    }
}
