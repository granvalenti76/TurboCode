import Foundation

nonisolated enum TypeScriptPluginActivationError: LocalizedError, Sendable, Equatable {
    case disabled
    case alreadyActive(String)
    case notActive(String)
    case invalidToolList(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Third-party TypeScript plugins are disabled in Settings > Agents."
        case .alreadyActive(let id):
            "TypeScript plugin \(id) is already active."
        case .notActive(let id):
            "TypeScript plugin \(id) is not active."
        case .invalidToolList(let id):
            "TypeScript plugin \(id) returned a tool list different from its manifest."
        }
    }
}

/// Owns explicit plugin activation and the process-backed tool adapters. The
/// registry can be refreshed independently; only this actor is allowed to
/// turn a discovered manifest into a live Node process.
actor TypeScriptPluginActivationStore {
    private struct ActivePlugin {
        let host: TypeScriptPluginHost
        let tools: [TypeScriptPluginToolBinding]
    }

    private let nodePolicy: NodeRuntimePolicy
    private let requestTimeout: Duration
    private let sessionTranscript: @Sendable () async -> PluginJSONValue?
    private var enabled: Bool
    private var active: [String: ActivePlugin] = [:]

    init(
        nodePolicy: NodeRuntimePolicy = .init(),
        requestTimeout: Duration = .seconds(10),
        enabled: Bool = false,
        sessionTranscript: @escaping @Sendable () async -> PluginJSONValue? = { nil }
    ) {
        self.nodePolicy = nodePolicy
        self.requestTimeout = requestTimeout
        self.enabled = enabled
        self.sessionTranscript = sessionTranscript
    }

    func activate(
        _ descriptor: TypeScriptPluginDescriptor
    ) async throws -> [TypeScriptPluginToolBinding] {
        guard enabled else { throw TypeScriptPluginActivationError.disabled }
        guard active[descriptor.manifest.id] == nil else {
            throw TypeScriptPluginActivationError.alreadyActive(descriptor.manifest.id)
        }
        let host = TypeScriptPluginHost(
            configuration: TypeScriptPluginHostConfiguration(
                manifest: descriptor.manifest,
                pluginRoot: descriptor.rootURL,
                nodePolicy: nodePolicy,
                requestTimeout: requestTimeout,
                sessionTranscript: sessionTranscript
            )
        )
        let handshake = try await host.start()
        guard handshake.tools == descriptor.manifest.tools.map(\.name) else {
            await host.shutdown()
            throw TypeScriptPluginActivationError.invalidToolList(descriptor.manifest.id)
        }
        // Activation is a process concern, not a Foundation Models schema
        // gate. A provider adapter may omit a rich JSON Schema while the
        // Node plugin remains active and available to other providers.
        let tools = descriptor.manifest.tools.map { tool in
            TypeScriptPluginToolBinding(
                snapshot: TypeScriptPluginToolSnapshot(
                    id: TypeScriptPluginToolID(
                        pluginID: descriptor.manifest.id,
                        toolName: tool.name
                    ),
                    description: tool.description,
                    inputSchema: tool.inputSchema
                ),
                host: host
            )
        }
        active[descriptor.manifest.id] = ActivePlugin(host: host, tools: tools)
        return tools
    }

    func deactivate(pluginID: String) async throws {
        guard let plugin = active.removeValue(forKey: pluginID) else {
            throw TypeScriptPluginActivationError.notActive(pluginID)
        }
        await plugin.host.shutdown()
    }

    func activeTools() -> [TypeScriptPluginToolBinding] {
        guard enabled else { return [] }
        return active.values
            .flatMap(\.tools)
            .sorted { $0.snapshot.id.rawValue < $1.snapshot.id.rawValue }
    }

    func isActive(pluginID: String) -> Bool {
        enabled && active[pluginID] != nil
    }

    /// Disabling the global trust-boundary switch terminates all active Node
    /// processes before the next provider snapshot can observe plugin tools.
    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        guard !enabled else { return }
        for plugin in active.values {
            await plugin.host.shutdown()
        }
        active.removeAll()
    }

    func isEnabled() -> Bool {
        enabled
    }

    func shutdown() async {
        for plugin in active.values {
            await plugin.host.shutdown()
        }
        active.removeAll()
    }
}
