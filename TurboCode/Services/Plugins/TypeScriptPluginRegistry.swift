import Foundation

/// Discovers metadata without launching Node. Process creation belongs only to
/// explicit activation, so `/reload` can refresh this registry safely.
nonisolated struct TypeScriptPluginRegistry {
    private let pluginsRoot: URL
    private let fileManager: FileManager

    init(
        pluginsRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.pluginsRoot = pluginsRoot
        self.fileManager = fileManager
    }

    @MainActor
    static func live() -> Self {
        Self(
            pluginsRoot: TurboCodeConfig.shared.pluginsDirectoryURL
        )
    }

    func discover() -> TypeScriptPluginDiscoveryResult {
        var descriptors: [TypeScriptPluginDescriptor] = []
        var failures: [TypeScriptPluginDiscoveryFailure] = []
        var seenIDs = Set<String>()
        guard let children = try? fileManager.contentsOfDirectory(
            at: pluginsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TypeScriptPluginDiscoveryResult(plugins: [], failures: [])
        }
        for child in children.sorted(by: { $0.path < $1.path }) {
            let manifestURL = child.appendingPathComponent("plugin.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(
                    TypeScriptPluginManifest.self,
                    from: data
                )
                try manifest.validate(at: child)
                guard seenIDs.insert(manifest.id).inserted else {
                    throw TypeScriptPluginRegistryError.duplicatePluginID(manifest.id)
                }
                descriptors.append(
                    TypeScriptPluginDescriptor(manifest: manifest, rootURL: child)
                )
            } catch {
                failures.append(
                    TypeScriptPluginDiscoveryFailure(
                        rootURL: child,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return TypeScriptPluginDiscoveryResult(
            plugins: descriptors,
            failures: failures
        )
    }
}

nonisolated enum TypeScriptPluginRegistryError: LocalizedError, Sendable, Equatable {
    case duplicatePluginID(String)

    var errorDescription: String? {
        switch self {
        case .duplicatePluginID(let id):
            "Duplicate TypeScript plugin id: \(id)."
        }
    }
}
