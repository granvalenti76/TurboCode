import Foundation
import FoundationModels

@Generable
struct SwiftPackageInitArguments {
    /// Swift package name, such as TaskCLI.
    var packageName: String
    /// Official SwiftPM template type.
    @Guide(.anyOf([
        "executable",
        "library",
        "tool",
        "build-tool-plugin",
        "command-plugin",
        "macro",
        "empty"
    ]))
    var packageType: String
}

/// Creates an official SwiftPM scaffold without granting Bash source-write access.
///
/// SwiftPM runs in a private staging directory. The generated UTF-8 files are
/// then applied to the workspace through the same atomic Review/Undo path as
/// edit_file, so an existing workspace file is never overwritten.
struct SwiftPackageInitTool: Tool {
    typealias Arguments = SwiftPackageInitArguments
    typealias Output = String

    let workspaceRoot: String
    let reportsChanges: Bool

    init(workspaceRoot: String, reportsChanges: Bool = true) {
        self.workspaceRoot = workspaceRoot
        self.reportsChanges = reportsChanges
    }

    var name: String { "swift_package_init" }
    var description: String {
        """
        Initialize an official Swift Package Manager scaffold in the workspace.
        Use this instead of running `swift package init` through bash. Choose one
        package type and provide the requested package name. The tool never
        overwrites existing files: it stages the official SwiftPM template, then
        applies all generated UTF-8 files as one reviewable transaction. After it
        succeeds, use edit_file for implementation changes and bash for builds.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: SwiftPackageInitArguments) async throws -> String {
        let packageName = arguments.packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPackageName(packageName) else {
            return "Error: packageName must be a non-empty name without path separators."
        }

        let packageType = arguments.packageType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.supportedTypes.contains(packageType) else {
            return "Error: packageType must be one of: \(Self.supportedTypes.sorted().joined(separator: ", "))."
        }

        do {
            _ = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SwiftPackageInit-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SwiftPackageInitOutput-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return "Error preparing Swift package initialization: \(error.localizedDescription)"
        }
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let result: ProcessResult
        do {
            result = try runSwiftPackageInit(
                packageName: packageName,
                packageType: packageType,
                directory: stagingDirectory,
                stdoutURL: stdoutURL,
                stderrURL: stderrURL
            )
        } catch {
            return "Error launching swift package init: \(error.localizedDescription)"
        }
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            return "Error: swift package init failed with exit code \(result.status).\(detail.isEmpty ? "" : "\n\(detail)")"
        }

        let generatedFiles: [(path: String, content: String)]
        do {
            generatedFiles = try collectGeneratedFiles(in: stagingDirectory)
        } catch {
            return "Error reading generated Swift package: \(error.localizedDescription)"
        }
        guard !generatedFiles.isEmpty else {
            return "Error: swift package init generated no files."
        }

        let conflicts = generatedFiles.compactMap { file -> String? in
            guard let url = try? WorkspacePathResolver.resolve(file.path, within: workspaceRoot),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return file.path
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
            reportsChanges: reportsChanges
        ).call(arguments: ApplyEditsArguments(files: requests))
        guard applyResult.hasPrefix("Applied ") else { return applyResult }

        let paths = generatedFiles.map(\.path).joined(separator: ", ")
        return "SWIFT_PACKAGE_CREATED: \(packageName) (\(packageType)); files: \(paths)"
    }

    private static let supportedTypes: Set<String> = [
        "executable",
        "library",
        "tool",
        "build-tool-plugin",
        "command-plugin",
        "macro",
        "empty"
    ]

    private func isValidPackageName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private func runSwiftPackageInit(
        packageName: String,
        packageType: String,
        directory: URL,
        stdoutURL: URL,
        stderrURL: URL
    ) throws -> ProcessResult {
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["package", "init", "--type", packageType, "--name", packageName]
        process.currentDirectoryURL = directory
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private func collectGeneratedFiles(in root: URL) throws -> [(path: String, content: String)] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
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
            let content = try String(contentsOf: url, encoding: .utf8)
            files.append((relativePath, content))
        }
        return files.sorted { $0.path < $1.path }
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
