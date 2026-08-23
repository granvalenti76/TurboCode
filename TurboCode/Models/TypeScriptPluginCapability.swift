import Foundation

/// External capability identity. It intentionally does not extend
/// `ToolCapabilityID`, whose enum remains the closed catalog of native tools.
nonisolated struct TypeScriptPluginToolID: Codable, Sendable, Equatable, Hashable, Identifiable {
    let pluginID: String
    let toolName: String

    init(pluginID: String, toolName: String) {
        self.pluginID = pluginID
        self.toolName = toolName
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(pluginID: parts[0], toolName: parts[1])
    }

    var rawValue: String { "\(pluginID)/\(toolName)" }
    var id: String { rawValue }

    /// Responses-compatible alias used only in Codex dynamic-tool schemas.
    /// The slash remains part of the persisted/plugin identity, but the
    /// Responses API accepts ASCII letters, digits, `_`, and `-` only.
    var codexName: String {
        "plugin_\(Self.codexSafe(pluginID))_\(Self.codexSafe(toolName))"
    }

    private static func codexSafe(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                Character(String(scalar))
            default:
                "_"
            }
        }.map(String.init).joined()
    }
}

/// Immutable metadata shared by native and Codex provider adapters. The
/// original JSON Schema remains intact here; provider-specific translation is
/// deferred until a selected runtime consumes the snapshot.
nonisolated struct TypeScriptPluginToolSnapshot: Sendable, Equatable {
    let id: TypeScriptPluginToolID
    let description: String
    let inputSchema: PluginJSONValue

    init(
        id: TypeScriptPluginToolID,
        description: String,
        inputSchema: PluginJSONValue
    ) {
        self.id = id
        self.description = description
        self.inputSchema = inputSchema
    }
}

nonisolated struct TypeScriptPluginWidgetInvocation: Codable, Sendable, Equatable {
    let id: String
    let props: PluginJSONValue

    init(id: String, props: PluginJSONValue = .object([:])) {
        self.id = id
        self.props = props
    }
}

/// The wire result returned by a TypeScript tool before the host resolves its
/// widget entrypoint. Props remain JSON values so the WebView can receive the
/// plugin's own data model without a Swift-side widget schema.
nonisolated struct TypeScriptPluginToolCallResult: Codable, Sendable, Equatable {
    let text: String
    let isError: Bool
    let widget: TypeScriptPluginWidgetInvocation?
}

/// Host-resolved widget data. The plugin chooses the UI entrypoint and props;
/// TurboCode adds the installed root so WebKit can load only that plugin's
/// local assets.
nonisolated public struct TypeScriptPluginWidgetReceipt: Codable, Hashable, Sendable {
    public let pluginID: String
    public let widgetID: String
    public let title: String
    public let entrypoint: String
    public let pluginRoot: String
    public let propsJSON: Data

    init(
        pluginID: String,
        widgetID: String,
        title: String,
        entrypoint: String,
        pluginRoot: String,
        props: PluginJSONValue
    ) {
        self.pluginID = pluginID
        self.widgetID = widgetID
        self.title = title
        self.entrypoint = entrypoint
        self.pluginRoot = pluginRoot
        self.propsJSON = (try? JSONEncoder().encode(props)) ?? Data("{}".utf8)
    }

    public init(
        pluginID: String,
        widgetID: String,
        title: String,
        entrypoint: String,
        pluginRoot: String,
        propsJSON: Data
    ) {
        self.pluginID = pluginID
        self.widgetID = widgetID
        self.title = title
        self.entrypoint = entrypoint
        self.pluginRoot = pluginRoot
        self.propsJSON = propsJSON
    }

    var props: PluginJSONValue {
        (try? JSONDecoder().decode(PluginJSONValue.self, from: propsJSON)) ?? .object([:])
    }
}

nonisolated struct TypeScriptPluginToolResultEnvelope: Codable, Hashable, Sendable {
    let text: String
    let isError: Bool
    let widget: TypeScriptPluginWidgetReceipt?
}

/// Foundation Models tools currently return text. This compact envelope keeps
/// the custom widget payload attached to that result until the coordinator can
/// project it into the provider-neutral timeline receipt.
nonisolated enum TypeScriptPluginToolResultCodec {
    private static let marker = "\u{001E}TURBOCODE_PLUGIN_RESULT_V1:"

    static func encodeForModel(_ result: TypeScriptPluginToolResultEnvelope) -> String {
        guard result.widget != nil || result.isError,
              let data = try? JSONEncoder().encode(result),
              !data.isEmpty else {
            return result.text
        }
        return result.text + "\n" + marker + data.base64EncodedString()
    }

    static func decode(_ text: String) -> TypeScriptPluginToolResultEnvelope? {
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let encoded = String(text[range.upperBound...])
        guard let data = Data(base64Encoded: encoded),
              let result = try? JSONDecoder().decode(
                  TypeScriptPluginToolResultEnvelope.self,
                  from: data
              ) else {
            return nil
        }
        return result
    }

    static func visibleText(_ text: String) -> String {
        guard let range = text.range(of: marker, options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A live binding couples provider-neutral metadata to the actor-owned Node
/// host. It is copied into immutable session configuration; the host itself
/// remains the sole owner of process lifetime and request serialization.
nonisolated struct TypeScriptPluginToolBinding: @unchecked Sendable {
    let snapshot: TypeScriptPluginToolSnapshot
    private let manifest: TypeScriptPluginManifest
    private let pluginRoot: URL
    private let host: TypeScriptPluginHost

    init(
        snapshot: TypeScriptPluginToolSnapshot,
        manifest: TypeScriptPluginManifest,
        pluginRoot: URL,
        host: TypeScriptPluginHost
    ) {
        self.snapshot = snapshot
        self.manifest = manifest
        self.pluginRoot = pluginRoot
        self.host = host
    }

    func makeNativeAdapter() throws -> TypeScriptPluginToolAdapter {
        try TypeScriptPluginToolAdapter(
            snapshot: snapshot,
            manifest: manifest,
            pluginRoot: pluginRoot,
            host: host
        )
    }

    func call(arguments: PluginJSONValue) async throws -> TypeScriptPluginToolResultEnvelope {
        let result = try await host.call(
            tool: snapshot.id.toolName,
            arguments: arguments
        )
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
        return TypeScriptPluginToolResultEnvelope(
            text: result.text,
            isError: result.isError,
            widget: widget
        )
    }
}

nonisolated struct TypeScriptPluginDescriptor: Sendable, Equatable {
    let manifest: TypeScriptPluginManifest
    let rootURL: URL

    var toolIDs: [TypeScriptPluginToolID] {
        manifest.tools.map {
            TypeScriptPluginToolID(pluginID: manifest.id, toolName: $0.name)
        }
    }
}

nonisolated struct TypeScriptPluginDiscoveryFailure: Sendable, Equatable {
    let rootURL: URL
    let message: String
}

nonisolated struct TypeScriptPluginDiscoveryResult: Sendable, Equatable {
    let plugins: [TypeScriptPluginDescriptor]
    let failures: [TypeScriptPluginDiscoveryFailure]
}
