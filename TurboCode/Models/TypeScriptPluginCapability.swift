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

/// A live binding couples provider-neutral metadata to the actor-owned Node
/// host. It is copied into immutable session configuration; the host itself
/// remains the sole owner of process lifetime and request serialization.
nonisolated struct TypeScriptPluginToolBinding: @unchecked Sendable {
    let snapshot: TypeScriptPluginToolSnapshot
    private let host: TypeScriptPluginHost

    init(
        snapshot: TypeScriptPluginToolSnapshot,
        host: TypeScriptPluginHost
    ) {
        self.snapshot = snapshot
        self.host = host
    }

    func makeNativeAdapter() throws -> TypeScriptPluginToolAdapter {
        try TypeScriptPluginToolAdapter(
            snapshot: snapshot,
            host: host
        )
    }

    func call(arguments: PluginJSONValue) async throws -> String {
        try await host.call(
            tool: snapshot.id.toolName,
            arguments: arguments
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
