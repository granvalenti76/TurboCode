import Darwin
import Foundation
import FoundationModels

@Generable
struct SwiftPackageManagerArguments {
    /// SwiftPM operation to perform.
    @Guide(.anyOf([
        "initialize",
        "addDependency",
        "addTargetDependency",
        "resolve",
        "update",
        "build",
        "test",
        "run",
        "clean",
        "reset",
        "describe",
        "showDependencies",
        "dumpPackage"
    ]))
    var action: String
    /// Package name used only by initialize.
    var packageName: String?
    /// Official SwiftPM template used only by initialize.
    var packageType: String?
    /// Dependency URL, registry identity, or workspace-relative path.
    var dependency: String?
    /// Dependency kind: url, path, or registry.
    var dependencyType: String?
    /// Version requirement: from, exact, branch, revision, or upToNextMinor.
    var requirement: String?
    /// Version, branch, or revision value paired with requirement.
    var requirementValue: String?
    /// Product or target dependency name used by addTargetDependency.
    var dependencyName: String?
    /// Target to update, build, or test.
    var target: String?
    /// Package identity that supplies a target dependency.
    var package: String?
    /// Build configuration: debug or release.
    var configuration: String?
    /// Product to build or executable to run.
    var product: String?
    /// Test case or suite filter.
    var filter: String?
    /// Timeout in seconds, clamped by Agent Settings.
    var timeoutSeconds: Int?

    init(
        action: String,
        packageName: String? = nil,
        packageType: String? = nil,
        dependency: String? = nil,
        dependencyType: String? = nil,
        requirement: String? = nil,
        requirementValue: String? = nil,
        dependencyName: String? = nil,
        target: String? = nil,
        package: String? = nil,
        configuration: String? = nil,
        product: String? = nil,
        filter: String? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.action = action
        self.packageName = packageName
        self.packageType = packageType
        self.dependency = dependency
        self.dependencyType = dependencyType
        self.requirement = requirement
        self.requirementValue = requirementValue
        self.dependencyName = dependencyName
        self.target = target
        self.package = package
        self.configuration = configuration
        self.product = product
        self.filter = filter
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Provides a structured, workspace-bound Swift Package Manager surface.
///
/// Manifest mutations run against a private staging copy and flow back through
/// the atomic Review/Undo editor. Execution actions invoke `/usr/bin/swift`
/// directly, never a shell, and can write only SwiftPM state and build artifacts.
struct SwiftPackageManagerTool: Tool {
    typealias Arguments = SwiftPackageManagerArguments
    typealias Output = ToolCommandOutput

    let workspaceRoot: String
    let executionPolicy: ExecutionPolicy
    let reportsChanges: Bool
    let taskScope: AgentTaskPathScope?
    private let receiptRegistry: ToolReceiptRegistry?
    private let service = SwiftPackageManagerService()

    init(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        reportsChanges: Bool = true,
        taskScope: AgentTaskPathScope? = nil,
        receiptRegistry: ToolReceiptRegistry? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
        self.reportsChanges = reportsChanges
        self.taskScope = taskScope
        self.receiptRegistry = receiptRegistry
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            reportsChanges: reportsChanges,
            taskScope: scope,
            receiptRegistry: receiptRegistry
        )
    }

    var name: String { "swift_package_manager" }
    var description: String {
        """
        Manage Swift packages with a structured wrapper. Use initialize to create
        an official scaffold; addDependency and addTargetDependency to make
        reviewable Package.swift changes; resolve or update for dependency
        resolution; build, test, and run for package execution; clean or reset for
        package artifacts; and describe, showDependencies, or dumpPackage for
        inspection. Its structured results complement commands run through Bash.
        All paths are workspace-bound, manifest edits support Review/Undo, and
        command time, output, network access, and filesystem writes are bounded.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: SwiftPackageManagerArguments) async throws -> ToolCommandOutput {
        if let taskScope, !taskScope.isWorkspaceWide {
            return "Error: swift_package_manager requires an entire-workspace task scope because package manifests and build state span the package."
        }
        switch arguments.action {
        case "initialize":
            return try await initialize(arguments)
        case "addDependency":
            return try await mutateManifest(arguments, operation: .addDependency)
        case "addTargetDependency":
            return try await mutateManifest(arguments, operation: .addTargetDependency)
        case "resolve", "update", "build", "test", "run", "clean", "reset",
             "describe", "showDependencies", "dumpPackage":
            return .plain(await execute(arguments))
        default:
            return "Error: unsupported Swift Package Manager action '\(arguments.action)'."
        }
    }

    private func initialize(
        _ arguments: SwiftPackageManagerArguments
    ) async throws -> ToolCommandOutput {
        let packageName = trimmed(arguments.packageName)
        guard let packageName,
              packageName != ".",
              packageName != "..",
              !packageName.contains("/"),
              !packageName.contains("\\"),
              !packageName.contains("\0") else {
            return "Error: packageName must be a non-empty name without path separators."
        }
        let packageType = trimmed(arguments.packageType)
        guard let packageType, Self.supportedPackageTypes.contains(packageType) else {
            return "Error: packageType must be one of: \(Self.supportedPackageTypes.sorted().joined(separator: ", "))."
        }

        let workspaceURL: URL
        do {
            workspaceURL = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let staging = makeTemporaryDirectory(prefix: "TurboCode-SwiftPM-Init")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return "Error preparing Swift package initialization: \(error.localizedDescription)"
        }

        let result = await service.runUnsandboxed(
            arguments: ["package", "init", "--type", packageType, "--name", packageName],
            directory: staging,
            timeoutSeconds: boundedTimeout(arguments.timeoutSeconds),
            outputLimit: executionPolicy.maximumToolOutputCharacters
        )
        guard result.status == 0 else {
            return .plain(result.formatted(command: "swift package init"))
        }

        let generatedFiles: [(path: String, content: String)]
        do {
            generatedFiles = try collectGeneratedFiles(in: staging)
        } catch {
            return "Error reading generated Swift package: \(error.localizedDescription)"
        }
        guard !generatedFiles.isEmpty else {
            return "Error: swift package init generated no files."
        }

        let conflicts = generatedFiles.compactMap { file -> String? in
            let url = workspaceURL.appendingPathComponent(file.path)
            return FileManager.default.fileExists(atPath: url.path) ? file.path : nil
        }
        guard conflicts.isEmpty else {
            return "Error: Swift package initialization would overwrite existing file(s): \(conflicts.joined(separator: ", "))."
        }

        let requests = generatedFiles.map { file in
            FileEditRequest(
                filePath: file.path,
                revision: nil,
                operations: [
                    LineEditOperation(
                        operation: "create",
                        startLine: nil,
                        endLine: nil,
                        content: file.content
                    )
                ]
            )
        }
        let applyResult = try await ApplyEditsTool(
            workspaceRoot: workspaceRoot,
            reportsChanges: reportsChanges,
            receiptRegistry: receiptRegistry
        ).call(arguments: ApplyEditsArguments(files: requests))
        guard applyResult.hasPrefix("Applied ") else { return applyResult }

        return applyResult.replacingText(
            with: "SWIFT_PACKAGE_CREATED: \(packageName) (\(packageType)); files: \(generatedFiles.map(\.path).joined(separator: ", "))"
        )
    }

    private enum ManifestOperation {
        case addDependency
        case addTargetDependency
    }

    private func mutateManifest(
        _ arguments: SwiftPackageManagerArguments,
        operation: ManifestOperation
    ) async throws -> ToolCommandOutput {
        let manifestURL: URL
        let original: String
        do {
            manifestURL = try WorkspacePathResolver.resolve("Package.swift", within: workspaceRoot)
            original = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            return "Error: read Package.swift before changing package dependencies. \(error.localizedDescription)"
        }

        let command: [String]
        var stagedPathDependency: (relativePath: String, sourceURL: URL)?
        switch operation {
        case .addDependency:
            guard let dependency = trimmed(arguments.dependency),
                  !dependency.hasPrefix("-") else {
                return "Error: dependency is required and cannot begin with '-'."
            }
            let dependencyType = trimmed(arguments.dependencyType) ?? "url"
            guard ["url", "path", "registry"].contains(dependencyType) else {
                return "Error: dependencyType must be url, path, or registry."
            }
            if dependencyType == "path" {
                let components = NSString(string: dependency).pathComponents
                guard !dependency.hasPrefix("/"), !components.contains("..") else {
                    return "Error: path dependencies must use a workspace-relative path without '..'."
                }
                do {
                    let sourceURL = try WorkspacePathResolver.resolve(
                        dependency,
                        within: workspaceRoot
                    )
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(
                        atPath: sourceURL.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue else {
                        return "Error: path dependency '\(dependency)' is not a workspace directory."
                    }
                    stagedPathDependency = (dependency, sourceURL)
                } catch {
                    return "Error: invalid path dependency. \(error.localizedDescription)"
                }
            }
            var values = ["package", "add-dependency", dependency, "--type", dependencyType]
            if let requirement = trimmed(arguments.requirement) {
                guard let flag = Self.requirementFlags[requirement],
                      let value = trimmed(arguments.requirementValue),
                      !value.hasPrefix("-") else {
                    return "Error: requirement must have a valid requirementValue."
                }
                values += [flag, value]
            }
            command = values
        case .addTargetDependency:
            guard let dependencyName = safeIdentifier(arguments.dependencyName),
                  let target = safeIdentifier(arguments.target) else {
                return "Error: dependencyName and target are required."
            }
            var values = ["package", "add-target-dependency", dependencyName, target]
            if let package = safeIdentifier(arguments.package) {
                values += ["--package", package]
            }
            command = values
        }

        let staging = makeTemporaryDirectory(prefix: "TurboCode-SwiftPM-Manifest")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try original.write(
                to: staging.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )
            if let stagedPathDependency {
                let linkURL = staging.appendingPathComponent(stagedPathDependency.relativePath)
                try FileManager.default.createDirectory(
                    at: linkURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Preserve the portable workspace-relative spelling in the
                // generated manifest while letting SwiftPM validate the package.
                try FileManager.default.createSymbolicLink(
                    at: linkURL,
                    withDestinationURL: stagedPathDependency.sourceURL
                )
            }
        } catch {
            return "Error preparing the reviewable manifest change: \(error.localizedDescription)"
        }

        let result = await service.runUnsandboxed(
            arguments: command,
            directory: staging,
            timeoutSeconds: boundedTimeout(arguments.timeoutSeconds),
            outputLimit: executionPolicy.maximumToolOutputCharacters
        )
        guard result.status == 0 else {
            return .plain(
                result.formatted(command: "swift \(command.joined(separator: " "))")
            )
        }

        let updated: String
        do {
            updated = try String(
                contentsOf: staging.appendingPathComponent("Package.swift"),
                encoding: .utf8
            )
        } catch {
            return "Error reading the staged Package.swift change: \(error.localizedDescription)"
        }
        guard updated != original else {
            return "Error: SwiftPM completed without changing Package.swift."
        }

        return try await ApplyEditsTool(
            workspaceRoot: workspaceRoot,
            reportsChanges: reportsChanges,
            receiptRegistry: receiptRegistry
        ).call(arguments: ApplyEditsArguments(files: [
            FileEditRequest(
                filePath: "Package.swift",
                revision: FileRevision.hash(original),
                operations: [
                    LineEditOperation(
                        operation: "replace_file",
                        startLine: nil,
                        endLine: nil,
                        content: updated
                    )
                ]
            )
        ]))
    }

    private func execute(_ arguments: SwiftPackageManagerArguments) async -> String {
        let packageURL: URL
        do {
            packageURL = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        guard FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("Package.swift").path
        ) else {
            return "Error: Package.swift was not found at the workspace root."
        }

        let command: [String]
        switch arguments.action {
        case "build":
            var values = swiftExecutionPrefix("build")
            if let configuration = validatedConfiguration(arguments.configuration) {
                values += ["--configuration", configuration]
            } else if trimmed(arguments.configuration) != nil {
                return "Error: configuration must be debug or release."
            }
            if let target = safeIdentifier(arguments.target) {
                values += ["--target", target]
            }
            if let product = safeIdentifier(arguments.product) {
                values += ["--product", product]
            }
            command = values
        case "test":
            var values = swiftExecutionPrefix("test")
            if let configuration = validatedConfiguration(arguments.configuration) {
                values += ["--configuration", configuration]
            } else if trimmed(arguments.configuration) != nil {
                return "Error: configuration must be debug or release."
            }
            if let filter = trimmed(arguments.filter), !filter.hasPrefix("-") {
                values += ["--filter", filter]
            }
            command = values
        case "run":
            var values = swiftExecutionPrefix("run")
            if let configuration = validatedConfiguration(arguments.configuration) {
                values += ["--configuration", configuration]
            } else if trimmed(arguments.configuration) != nil {
                return "Error: configuration must be debug or release."
            }
            if let product = safeIdentifier(arguments.product) {
                values.append(product)
            }
            command = values
        case "resolve":
            command = swiftPackagePrefix() + ["resolve"]
        case "update":
            command = swiftPackagePrefix() + ["update"]
        case "clean":
            command = swiftPackagePrefix() + ["clean"]
        case "reset":
            command = swiftPackagePrefix() + ["reset"]
        case "describe":
            command = swiftPackagePrefix() + ["describe"]
        case "showDependencies":
            command = swiftPackagePrefix() + ["show-dependencies"]
        case "dumpPackage":
            command = swiftPackagePrefix() + ["dump-package"]
        default:
            return "Error: unsupported execution action."
        }

        let result = await service.runSandboxed(
            arguments: command,
            workspace: packageURL,
            timeoutSeconds: boundedTimeout(arguments.timeoutSeconds),
            outputLimit: executionPolicy.maximumToolOutputCharacters,
            allowNetworkAccess: executionPolicy.allowNetworkAccess
        )
        return result.formatted(command: "swift \(command.joined(separator: " "))")
    }

    private func swiftExecutionPrefix(_ command: String) -> [String] {
        [
            command,
            "--disable-sandbox",
            "--cache-path", ".swiftpm/cache",
            "--config-path", ".swiftpm/configuration",
            "--security-path", ".swiftpm/security"
        ]
    }

    private func swiftPackagePrefix() -> [String] {
        [
            "package",
            "--disable-sandbox",
            "--cache-path", ".swiftpm/cache",
            "--config-path", ".swiftpm/configuration",
            "--security-path", ".swiftpm/security"
        ]
    }

    private func boundedTimeout(_ requested: Int?) -> Int {
        min(
            max(requested ?? executionPolicy.defaultCommandTimeoutSeconds, 1),
            executionPolicy.maximumCommandTimeoutSeconds
        )
    }

    private func validatedConfiguration(_ value: String?) -> String? {
        guard let value = trimmed(value), ["debug", "release"].contains(value) else { return nil }
        return value
    }

    private func safeIdentifier(_ value: String?) -> String? {
        guard let value = trimmed(value),
              !value.hasPrefix("-"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else { return nil }
        return value
    }

    private func trimmed(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }
        return result
    }

    private func makeTemporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func collectGeneratedFiles(in root: URL) throws -> [(path: String, content: String)] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var files: [(path: String, content: String)] = []
        for case let url as URL in enumerator {
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(rootPath + "/") else {
                throw CocoaError(.fileReadNoPermission)
            }
            let relativePath = String(resolvedPath.dropFirst(rootPath.count + 1))
            if relativePath == ".build" || relativePath == ".swiftpm" {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            guard values.isRegularFile == true else { continue }
            files.append((relativePath, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static let supportedPackageTypes: Set<String> = [
        "executable",
        "library",
        "tool",
        "build-tool-plugin",
        "command-plugin",
        "macro",
        "empty"
    ]

    private static let requirementFlags: [String: String] = [
        "from": "--from",
        "exact": "--exact",
        "branch": "--branch",
        "revision": "--revision",
        "upToNextMinor": "--up-to-next-minor-from"
    ]
}

private actor SwiftPackageManagerService {
    func runUnsandboxed(
        arguments: [String],
        directory: URL,
        timeoutSeconds: Int,
        outputLimit: Int
    ) async -> SwiftPackageProcessResult {
        await run(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: arguments,
            directory: directory,
            timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit,
            environment: nil
        )
    }

    func runSandboxed(
        arguments: [String],
        workspace: URL,
        timeoutSeconds: Int,
        outputLimit: Int,
        allowNetworkAccess: Bool
    ) async -> SwiftPackageProcessResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SwiftPM-Command-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return SwiftPackageProcessResult(
                status: -1,
                duration: 0,
                stdout: "",
                stderr: "Error preparing SwiftPM command: \(error.localizedDescription)",
                timedOut: false
            )
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let profile = sandboxProfile(
            workspacePath: workspace.path,
            outputPath: outputDirectory.path,
            allowNetworkAccess: allowNetworkAccess
        )
        // Nested `swift test` invocations must not inherit the host app's XCTest
        // injection variables; doing so can leave the package test runner waiting
        // on the outer Xcode test session after its build has completed.
        let inheritedEnvironment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("XCTest")
                && key != "XCInjectBundleInto"
                && key != "DYLD_INSERT_LIBRARIES"
        }
        let environment = inheritedEnvironment.merging([
            "PWD": workspace.path,
            "TMPDIR": outputDirectory.path,
            "HOME": outputDirectory.path,
            "XDG_CACHE_HOME": outputDirectory.appendingPathComponent(".cache").path,
            "GIT_CONFIG_GLOBAL": "/dev/null"
        ]) { _, new in new }
        return await run(
            executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile, "/usr/bin/swift"] + arguments,
            directory: workspace,
            timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit,
            environment: environment
        )
    }

    private func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        timeoutSeconds: Int,
        outputLimit: Int,
        environment: [String: String]?
    ) async -> SwiftPackageProcessResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SwiftPM-Output-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return SwiftPackageProcessResult(
                status: -1,
                duration: 0,
                stdout: "",
                stderr: "Error preparing command output: \(error.localizedDescription)",
                timedOut: false
            )
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return SwiftPackageProcessResult(
                status: -1,
                duration: 0,
                stdout: "",
                stderr: "Error opening command output: \(error.localizedDescription)",
                timedOut: false
            )
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let startedAt = Date()

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return SwiftPackageProcessResult(
                status: -1,
                duration: Date().timeIntervalSince(startedAt),
                stdout: "",
                stderr: "Error launching SwiftPM: \(error.localizedDescription)",
                timedOut: false
            )
        }

        var timedOut = false
        while process.isRunning {
            if Task.isCancelled || Date().timeIntervalSince(startedAt) >= Double(timeoutSeconds) {
                timedOut = true
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if timedOut {
            // `Process.waitUntilExit()` can remain blocked after sandbox-exec has
            // already reaped SwiftPM. Polling the observable process state keeps
            // the agent loop responsive and gives graceful termination a bounded
            // opportunity before escalating to SIGKILL.
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < killDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return SwiftPackageProcessResult(
            // A process that remains observable after SIGKILL is reported as an
            // execution failure instead of blocking the tool call indefinitely.
            status: process.isRunning ? -1 : process.terminationStatus,
            duration: Date().timeIntervalSince(startedAt),
            stdout: readOutput(at: stdoutURL, limit: outputLimit / 2),
            stderr: readOutput(at: stderrURL, limit: outputLimit / 2),
            timedOut: timedOut
        )
    }

    private func sandboxProfile(
        workspacePath: String,
        outputPath: String,
        allowNetworkAccess: Bool
    ) -> String {
        let workspace = escaped(workspacePath)
        let output = escaped(outputPath)
        let networkPolicy = allowNetworkAccess ? "" : "(deny network*)"
        return """
        (version 1)
        (allow default)
        \(networkPolicy)
        (deny file-write*)
        (allow file-write* (literal "\(workspace)/.build"))
        (allow file-write* (subpath "\(workspace)/.build"))
        (allow file-write* (literal "\(workspace)/.swiftpm"))
        (allow file-write* (subpath "\(workspace)/.swiftpm"))
        (allow file-write* (literal "\(workspace)/Package.resolved"))
        (allow file-write* (subpath "\(output)"))
        (allow file-write* (subpath "/var/folders"))
        (allow file-write* (subpath "/private/var/folders"))
        (allow file-write-data (literal "/dev/null"))
        """
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func readOutput(at url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let truncated = data.count > limit
        let visible = truncated ? data.prefix(limit) : data[...]
        let text = String(decoding: visible, as: UTF8.self).trimmingCharacters(in: .newlines)
        return truncated ? text + "\n... (output truncated)" : text
    }
}

private nonisolated struct SwiftPackageProcessResult: Sendable {
    let status: Int32
    let duration: TimeInterval
    let stdout: String
    let stderr: String
    let timedOut: Bool

    nonisolated func formatted(command: String) -> String {
        var sections = [
            "Command: \(command)",
            "Exit code: \(status)",
            String(format: "Duration: %.2fs", duration)
        ]
        if timedOut {
            sections.append("Command timed out or was cancelled.")
        }
        if !stdout.isEmpty {
            sections.append("STDOUT:\n\(stdout)")
        }
        if !stderr.isEmpty {
            sections.append("STDERR:\n\(stderr)")
        }
        if stdout.isEmpty && stderr.isEmpty {
            sections.append("(no output)")
        }
        return sections.joined(separator: "\n\n")
    }
}
