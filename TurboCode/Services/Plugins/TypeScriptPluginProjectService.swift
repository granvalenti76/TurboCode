import Foundation

/// The bounded result of one npm command. Output is retained only for
/// actionable diagnostics; callers must not surface an unbounded child-process
/// log in the conversation or approval UI.
nonisolated struct TypeScriptPluginCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }

    init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        timedOut: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

nonisolated struct TypeScriptPluginImportReceipt: Sendable, Equatable {
    let pluginID: String
    let installedRoot: URL
    let replacedExistingInstallation: Bool
    let commands: [String]
}

nonisolated enum TypeScriptPluginProjectError: LocalizedError, Sendable, Equatable {
    case projectNotFound(URL)
    case packageManifestMissing(URL)
    case invalidPackageManifest(String)
    case pluginManifestMissing(URL)
    case invalidPluginManifest(String)
    case nodeUnavailable(String)
    case nodeVersionUnavailable(String)
    case commandFailed(command: String, diagnostics: String)
    case sdkPackageInvalid(URL)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let url):
            "TypeScript project not found: \(url.path)."
        case .packageManifestMissing(let url):
            "TypeScript project is missing package.json at \(url.path)."
        case .invalidPackageManifest(let message):
            "Invalid package.json: \(message)"
        case .pluginManifestMissing(let url):
            "TypeScript project is missing plugin.json at \(url.path)."
        case .invalidPluginManifest(let message):
            "Invalid TypeScript plugin manifest: \(message)"
        case .nodeUnavailable(let message):
            message
        case .nodeVersionUnavailable(let message):
            message
        case .commandFailed(let command, let diagnostics):
            "TypeScript plugin command '\(command)' failed.\n\(diagnostics)"
        case .sdkPackageInvalid(let url):
            "The TurboCode SDK package is incomplete: \(url.path)."
        case .importFailed(let message):
            "TypeScript plugin import failed: \(message)"
        }
    }
}

/// Installs only the compiled SDK package surface. The source project remains
/// a normal npm project, while plugin builds receive the stable package name
/// through `node_modules/@granvalenti/turbocode-sdk`.
nonisolated struct TypeScriptPluginSDKInstaller: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func install(
        from sourcePackageURL: URL,
        to destinationPackageURL: URL
    ) throws {
        let source = sourcePackageURL.standardizedFileURL
        let packageJSON = source.appendingPathComponent("package.json")
        let dist = source.appendingPathComponent("dist", isDirectory: true)
        guard fileManager.fileExists(atPath: packageJSON.path),
              fileManager.fileExists(atPath: dist.path) else {
            throw TypeScriptPluginProjectError.sdkPackageInvalid(source)
        }

        let staging = destinationPackageURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".turbocode-sdk-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: packageJSON,
            to: staging.appendingPathComponent("package.json")
        )
        try fileManager.copyItem(
            at: dist,
            to: staging.appendingPathComponent("dist", isDirectory: true)
        )
        try replaceDirectory(
            staging,
            at: destinationPackageURL,
            fileManager: fileManager
        )
    }

    private func replaceDirectory(
        _ staging: URL,
        at destination: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}

/// Validates, builds, and imports a user-created TypeScript plugin without
/// changing the source project. Build commands run in a temporary copy, and
/// the installed generation is replaced only after every check succeeds.
nonisolated struct TypeScriptPluginProjectService: @unchecked Sendable {
    typealias CommandRunner = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ workingDirectory: URL,
        _ timeout: TimeInterval
    ) async throws -> TypeScriptPluginCommandResult

    private let pluginsRoot: URL
    private let sdkRoot: URL
    private let nodePolicy: NodeRuntimePolicy
    private let nodeExecutableURL: URL?
    private let commandTimeout: TimeInterval
    private let fileManager: FileManager
    private let commandRunner: CommandRunner

    init(
        pluginsRoot: URL,
        sdkRoot: URL,
        nodePolicy: NodeRuntimePolicy = .init(),
        nodeExecutableURL: URL? = nil,
        commandTimeout: TimeInterval = 120,
        fileManager: FileManager = .default,
        commandRunner: CommandRunner? = nil
    ) {
        self.pluginsRoot = pluginsRoot
        self.sdkRoot = sdkRoot
        self.nodePolicy = nodePolicy
        self.nodeExecutableURL = nodeExecutableURL
        self.commandTimeout = commandTimeout
        self.fileManager = fileManager
        self.commandRunner = commandRunner ?? Self.runCommand
    }

    @MainActor
    static func live() -> Self {
        Self(
            pluginsRoot: TurboCodeConfig.shared.pluginsDirectoryURL,
            sdkRoot: TurboCodeConfig.shared.sdkDirectoryURL
        )
    }

    /// Finds the SDK package shipped with the app. Debug builds also support
    /// the repository checkout so onboarding works directly from Xcode before
    /// an archive resource has been added.
    @MainActor
    static func liveSDKSourceURL() -> URL? {
        let candidates: [URL] = [
            Bundle.main.url(forResource: "TypeScriptSDK", withExtension: nil),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TypeScriptSDK", isDirectory: true)
        ].compactMap { $0 }
        let fileManager = FileManager.default
        return candidates.first { source in
            fileManager.fileExists(
                atPath: source.appendingPathComponent("package.json").path
            ) && fileManager.fileExists(
                atPath: source.appendingPathComponent("dist/index.js").path
            )
        }
    }

    /// Installs a compiled SDK package at the canonical user-local path.
    func bootstrapSDK(from sourcePackageURL: URL) throws -> URL {
        let destination = sdkRoot
            .appendingPathComponent("@granvalenti", isDirectory: true)
            .appendingPathComponent("turbocode-sdk", isDirectory: true)
        let packageJSON = destination.appendingPathComponent("package.json")
        let entrypoint = destination.appendingPathComponent("dist/index.js")
        guard !fileManager.fileExists(atPath: packageJSON.path)
                || !fileManager.fileExists(atPath: entrypoint.path) else {
            return destination
        }
        try TypeScriptPluginSDKInstaller(fileManager: fileManager).install(
            from: sourcePackageURL,
            to: destination
        )
        return destination
    }

    /// Runs the complete build gate and atomically installs the resulting
    /// plugin generation. The old installation is untouched on any failure.
    func buildAndImport(
        projectRoot: URL,
        sdkPackageURL: URL? = nil
    ) async throws -> TypeScriptPluginImportReceipt {
        let project = try validateProject(
            at: projectRoot,
            requireEntrypoint: false
        )
        let node = try resolveNode()
        try await validateNode(node)

        let buildRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "TurboCode-TypeScriptBuild-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: buildRoot) }
        try fileManager.copyItem(at: project.rootURL, to: buildRoot)

        if let sdkPackageURL {
            let sdkDestination = buildRoot
                .appendingPathComponent("node_modules/@granvalenti/turbocode-sdk", isDirectory: true)
            try TypeScriptPluginSDKInstaller(fileManager: fileManager).install(
                from: sdkPackageURL,
                to: sdkDestination
            )
        }

        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        guard fileManager.isExecutableFile(atPath: npm.path) else {
            throw TypeScriptPluginProjectError.nodeUnavailable(
                "npm was not found next to Node at \(npm.path)."
            )
        }

        var commands: [String] = []
        try await run(
            executable: npm,
            arguments: ["exec", "--", "tsc", "--noEmit"],
            workingDirectory: buildRoot,
            label: "tsc --noEmit",
            commands: &commands
        )
        try await run(
            executable: npm,
            arguments: ["run", "build"],
            workingDirectory: buildRoot,
            label: "npm run build",
            commands: &commands
        )
        try await run(
            executable: npm,
            arguments: ["run", "--if-present", "lint"],
            workingDirectory: buildRoot,
            label: "npm run lint --if-present",
            commands: &commands
        )

        let builtProject = try validateProject(at: buildRoot)
        let destination = pluginsRoot.appendingPathComponent(
            builtProject.manifest.id,
            isDirectory: true
        )
        let replacedExistingInstallation = fileManager.fileExists(atPath: destination.path)
        try stageRuntime(
            from: buildRoot,
            manifest: builtProject.manifest,
            to: destination
        )
        return TypeScriptPluginImportReceipt(
            pluginID: builtProject.manifest.id,
            installedRoot: destination,
            replacedExistingInstallation: replacedExistingInstallation,
            commands: commands
        )
    }

    private struct Project {
        let rootURL: URL
        let manifest: TypeScriptPluginManifest
    }

    private func validateProject(
        at rootURL: URL,
        requireEntrypoint: Bool = true
    ) throws -> Project {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TypeScriptPluginProjectError.projectNotFound(root)
        }
        let packageURL = root.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw TypeScriptPluginProjectError.packageManifestMissing(packageURL)
        }
        do {
            let packageObject = try JSONSerialization.jsonObject(
                with: Data(contentsOf: packageURL)
            )
            guard packageObject is [String: Any] else {
                throw TypeScriptPluginProjectError.invalidPackageManifest(
                    "the root value must be a JSON object"
                )
            }
        } catch let error as TypeScriptPluginProjectError {
            throw error
        } catch {
            throw TypeScriptPluginProjectError.invalidPackageManifest(
                error.localizedDescription
            )
        }
        let manifestURL = root.appendingPathComponent("plugin.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw TypeScriptPluginProjectError.pluginManifestMissing(manifestURL)
        }
        do {
            let manifest = try JSONDecoder().decode(
                TypeScriptPluginManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            try manifest.validate(
                at: root,
                requireEntrypoint: requireEntrypoint
            )
            return Project(rootURL: root, manifest: manifest)
        } catch let error as TypeScriptPluginProjectError {
            throw error
        } catch {
            throw TypeScriptPluginProjectError.invalidPluginManifest(
                error.localizedDescription
            )
        }
    }

    private func resolveNode() throws -> URL {
        if let nodeExecutableURL {
            guard fileManager.isExecutableFile(atPath: nodeExecutableURL.path) else {
                throw TypeScriptPluginProjectError.nodeUnavailable(
                    "Configured Node executable is not runnable: \(nodeExecutableURL.path)."
                )
            }
            return nodeExecutableURL
        }
        do {
            return try NodeRuntimeResolver.resolve(
                policy: nodePolicy,
                fileManager: fileManager
            )
        } catch {
            throw TypeScriptPluginProjectError.nodeUnavailable(
                error.localizedDescription
            )
        }
    }

    private func validateNode(_ node: URL) async throws {
        let result = try await commandRunner(
            node,
            ["--version"],
            fileManager.temporaryDirectory,
            commandTimeout
        )
        guard result.succeeded else {
            throw TypeScriptPluginProjectError.nodeVersionUnavailable(
                boundedDiagnostics(for: result)
            )
        }
        let version = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let major = version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .first
            .flatMap { Int($0) }
        guard let major, major >= nodePolicy.supportedMajor else {
            throw TypeScriptPluginProjectError.nodeVersionUnavailable(
                "Node \(version) is incompatible; TurboCode requires Node \(nodePolicy.supportedMajor) or newer."
            )
        }
    }

    private func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        label: String,
        commands: inout [String]
    ) async throws {
        commands.append(label)
        let result = try await commandRunner(
            executable,
            arguments,
            workingDirectory,
            commandTimeout
        )
        guard result.succeeded else {
            throw TypeScriptPluginProjectError.commandFailed(
                command: label,
                diagnostics: boundedDiagnostics(for: result)
            )
        }
    }

    private func stageRuntime(
        from buildRoot: URL,
        manifest: TypeScriptPluginManifest,
        to destination: URL
    ) throws {
        let staging = pluginsRoot
            .appendingPathComponent(
                ".\(manifest.id)-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )
            for filename in ["plugin.json", "package.json", "package-lock.json", "npm-shrinkwrap.json"] {
                let source = buildRoot.appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: staging.appendingPathComponent(filename)
                )
            }

            let dist = buildRoot.appendingPathComponent("dist", isDirectory: true)
            if fileManager.fileExists(atPath: dist.path) {
                try fileManager.copyItem(
                    at: dist,
                    to: staging.appendingPathComponent("dist", isDirectory: true)
                )
            }

            let entrypoint = buildRoot.appendingPathComponent(manifest.entrypoint)
            let stagedEntrypoint = staging.appendingPathComponent(manifest.entrypoint)
            let entrypointIsAlreadyStaged = fileManager.fileExists(atPath: stagedEntrypoint.path)
            if !entrypointIsAlreadyStaged {
                let destinationEntrypoint = staging.appendingPathComponent(manifest.entrypoint)
                try fileManager.createDirectory(
                    at: destinationEntrypoint.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: entrypoint, to: destinationEntrypoint)
            }

            let nodeModules = buildRoot.appendingPathComponent("node_modules", isDirectory: true)
            if fileManager.fileExists(atPath: nodeModules.path) {
                try fileManager.copyItem(
                    at: nodeModules,
                    to: staging.appendingPathComponent("node_modules", isDirectory: true)
                )
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw TypeScriptPluginProjectError.importFailed(error.localizedDescription)
        }
    }

    private func boundedDiagnostics(
        for result: TypeScriptPluginCommandResult,
        limit: Int = 8_000
    ) -> String {
        let output = [result.standardError, result.standardOutput]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let diagnostic = output.isEmpty ? "exit code \(result.exitCode)" : output
        if diagnostic.count <= limit { return diagnostic }
        return String(diagnostic.prefix(limit)) + "\n[diagnostics truncated]"
    }

    private static func runCommand(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> TypeScriptPluginCommandResult {
        try await Task.detached(priority: nil) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = output
            process.standardError = error
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            process.waitUntilExit()
            return TypeScriptPluginCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: String(
                    data: output.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "",
                standardError: String(
                    data: error.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "",
                timedOut: timedOut
            )
        }.value
    }
}
