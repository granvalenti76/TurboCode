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
