import Foundation

/// Host-owned Node selection. Plugins can declare a supported range, but they
/// never provide the executable used to launch themselves.
nonisolated struct NodeRuntimePolicy: Sendable, Equatable {
    let supportedMajor: Int
    let explicitExecutableURL: URL?

    init(
        supportedMajor: Int = TypeScriptPluginManifest.supportedNodeMajor,
        explicitExecutableURL: URL? = nil
    ) {
        self.supportedMajor = supportedMajor
        self.explicitExecutableURL = explicitExecutableURL
    }
}

nonisolated enum NodeRuntimeResolver {
    static func resolve(
        policy: NodeRuntimePolicy = .init(),
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        var candidates: [URL] = []
        if let bundled = bundle.url(forResource: "NodeRuntime", withExtension: nil) {
            candidates.append(bundled.appendingPathComponent("bin/node"))
        }
        if let explicit = policy.explicitExecutableURL {
            candidates.append(explicit)
        }
        if let configured = environment["TURBOCODE_NODE_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { directory in
                URL(fileURLWithPath: String(directory)).appendingPathComponent("node")
            }
        }

        var seen = Set<String>()
        for candidate in candidates {
            let url = candidate.standardizedFileURL
            guard seen.insert(url.path).inserted,
                  fileManager.isExecutableFile(atPath: url.path) else { continue }
            return url
        }
        throw NodeRuntimeError.executableNotFound
    }
}

nonisolated enum NodeRuntimeError: LocalizedError, Sendable, Equatable {
    case executableNotFound
    case incompatibleVersion(String, requiredMajor: Int)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Node 24.x was not found. Install Node 24.x or configure TURBOCODE_NODE_PATH."
        case .incompatibleVersion(let version, let requiredMajor):
            "Node \(version) is incompatible; TurboCode requires Node \(requiredMajor).x."
        }
    }
}
