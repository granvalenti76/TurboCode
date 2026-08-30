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
        let candidates = candidateURLs(
            bundle: bundle,
            explicitExecutableURL: policy.explicitExecutableURL,
            environment: environment,
            fileManager: fileManager
        )
        var seen = Set<String>()
        var incompatible: (version: String, major: Int)?
        for candidate in candidates {
            let url = candidate.standardizedFileURL
            guard seen.insert(url.path).inserted,
                  fileManager.isExecutableFile(atPath: url.path),
                  let version = nodeVersion(at: url) else { continue }
            if version.major >= policy.supportedMajor {
                return url
            }
            incompatible = incompatible ?? version
        }
        if let incompatible {
            throw NodeRuntimeError.incompatibleVersion(
                incompatible.version,
                requiredMajor: policy.supportedMajor
            )
        }
        throw NodeRuntimeError.executableNotFound
    }

    private static func candidateURLs(
        bundle: Bundle,
        explicitExecutableURL: URL?,
        environment: [String: String],
        fileManager: FileManager
    ) -> [URL] {
        var candidates: [URL] = []
        if let bundled = bundle.url(forResource: "NodeRuntime", withExtension: nil) {
            candidates.append(bundled.appendingPathComponent("bin/node"))
        }
        if let explicit = explicitExecutableURL {
            candidates.append(explicit)
        }
        if let configured = environment["TURBOCODE_NODE_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        // GUI-launched macOS apps do not inherit shell initialization files,
        // so managed runtimes are discovered from the user's home and their
        // manager variables before falling back to PATH.
        let home = fileManager.homeDirectoryForCurrentUser
        appendEnvironmentRuntime(environment["NVM_BIN"], to: &candidates)
        appendEnvironmentRuntime(
            environment["FNM_MULTISHELL_PATH"],
            to: &candidates
        )
        appendEnvironmentRuntime(
            environment["VOLTA_HOME"].map { "\($0)/bin" },
            to: &candidates
        )
        appendEnvironmentRuntime(
            environment["ASDF_DATA_DIR"].map { "\($0)/shims" },
            to: &candidates
        )
        appendEnvironmentRuntime(
            environment["MISE_DATA_DIR"].map { "\($0)/shims" },
            to: &candidates
        )
        appendVersionedRuntimes(
            at: home.appendingPathComponent(".nvm/versions/node", isDirectory: true),
            fileManager: fileManager,
            to: &candidates
        )
        appendVersionedRuntimes(
            at: home.appendingPathComponent(".asdf/installs/node", isDirectory: true),
            fileManager: fileManager,
            to: &candidates
        )
        appendVersionedRuntimes(
            at: home.appendingPathComponent(".local/share/mise/installs/node", isDirectory: true),
            fileManager: fileManager,
            to: &candidates
        )
        candidates += [
            home.appendingPathComponent(".fnm/current/bin/node"),
            home.appendingPathComponent(".volta/bin/node"),
            home.appendingPathComponent(".asdf/shims/node"),
            home.appendingPathComponent(".local/share/mise/shims/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node")
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { directory in
                URL(fileURLWithPath: String(directory)).appendingPathComponent("node")
            }
        }
        return candidates
    }

    private static func appendEnvironmentRuntime(
        _ path: String?,
        to candidates: inout [URL]
    ) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        candidates.append(
            url.lastPathComponent == "node"
                ? url
                : url.appendingPathComponent("node")
        )
    }

    private static func appendVersionedRuntimes(
        at root: URL,
        fileManager: FileManager,
        to candidates: inout [URL]
    ) {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        candidates += versions
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/node") }
    }

    private static func nodeVersion(
        at executableURL: URL
    ) -> (version: String, major: Int)? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let version = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              let major = version
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".")
                .first
                .flatMap({ Int($0) }) else { return nil }
        return (version, major)
    }
}

nonisolated enum NodeRuntimeError: LocalizedError, Sendable, Equatable {
    case executableNotFound
    case incompatibleVersion(String, requiredMajor: Int)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Node 24 or newer was not found. Install a supported Node version or configure TURBOCODE_NODE_PATH."
        case .incompatibleVersion(let version, let requiredMajor):
            "Node \(version) is incompatible; TurboCode requires Node \(requiredMajor) or newer."
        }
    }
}
