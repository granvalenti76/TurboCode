import Foundation

struct XcodeProjectService: Sendable {
    let workspaceRoot: String
    let executionPolicy: ExecutionPolicy
    let enhancedOutput: Bool

    private let runner = XcodeCommandRunner()

    func response(
        action rawAction: String,
        containerPath: String?,
        scheme requestedScheme: String?,
        configuration: String?,
        destination: String?,
        timeoutSeconds: Int?
    ) async throws -> String {
        let normalizedAction = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let action = XcodeProjectAction(rawValue: normalizedAction) else {
            throw XcodeProjectError.unsupportedAction(rawAction)
        }
        let container = try XcodeProjectDiscoveryService(workspaceRoot: workspaceRoot)
            .resolveContainer(path: containerPath)
        let timeout = boundedTimeout(timeoutSeconds)
        let description = try await inspect(container: container, timeoutSeconds: min(timeout, 45))

        switch action {
        case .inspect:
            return render(description)
        case .build, .test:
            let scheme = try resolvedScheme(requestedScheme, in: description)
            return try await execute(
                action: action,
                description: description,
                scheme: scheme,
                configuration: normalized(configuration),
                destination: normalized(destination),
                timeoutSeconds: timeout
            ).summary
        }
    }

    /// Executes a build or test and exposes a typed outcome for orchestration.
    /// Tool UI continues to consume `response`, while verification never parses
    /// the human-readable Xcode summary to decide whether work is verified.
    func verification(
        request: VerificationRequest,
        parameters: AgentVerificationParameters?,
        timeoutSeconds: Int?
    ) async throws -> XcodeVerificationExecution {
        let action: XcodeProjectAction = switch request {
        case .build: .build
        case .test: .test
        case .none:
            throw XcodeProjectError.unsupportedAction(request.rawValue)
        }
        let container = try XcodeProjectDiscoveryService(workspaceRoot: workspaceRoot)
            .resolveContainer(path: parameters?.containerPath)
        let timeout = boundedTimeout(timeoutSeconds)
        let description = try await inspect(
            container: container,
            timeoutSeconds: min(timeout, 45)
        )
        let scheme = try resolvedScheme(parameters?.scheme, in: description)
        return try await execute(
            action: action,
            description: description,
            scheme: scheme,
            configuration: normalized(parameters?.configuration),
            destination: normalized(parameters?.destination),
            timeoutSeconds: timeout
        )
    }

    private func inspect(
        container: XcodeContainer,
        timeoutSeconds: Int
    ) async throws -> XcodeProjectDescription {
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "xcodebuild",
                container.kind.xcodebuildFlag,
                container.url.path,
                "-list",
                "-json"
            ],
            workingDirectory: URL(fileURLWithPath: workspaceRoot),
            timeoutSeconds: timeoutSeconds
        )
        let command = try commandResult(from: result)
        guard command.exitCode == 0,
              let data = command.stdout.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ProjectListPayload.self, from: data) else {
            let message = compactFailure(command.combinedOutput)
            throw XcodeProjectError.launchFailed(
                message.isEmpty ? "xcodebuild could not inspect \(container.relativePath)." : message
            )
        }
        let contents = payload.project ?? payload.workspace
        return XcodeProjectDescription(
            container: container,
            schemes: contents?.schemes ?? [],
            targets: contents?.targets ?? [],
            configurations: contents?.configurations ?? []
        )
    }

    private func execute(
        action: XcodeProjectAction,
        description: XcodeProjectDescription,
        scheme: String,
        configuration: String?,
        destination: String?,
        timeoutSeconds: Int
    ) async throws -> XcodeVerificationExecution {
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Xcode-\(UUID().uuidString)", isDirectory: true)
        let resultBundleURL = runDirectory.appendingPathComponent("Result.xcresult", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        var arguments = [
            "xcodebuild",
            description.container.kind.xcodebuildFlag,
            description.container.url.path,
            "-scheme", scheme
        ]
        if let configuration { arguments += ["-configuration", configuration] }
        if let destination { arguments += ["-destination", destination] }
        arguments += [
            "-resultBundlePath", resultBundleURL.path,
            action.rawValue
        ]

        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: workspaceRoot),
            timeoutSeconds: timeoutSeconds
        )
        let command = try commandResult(from: result)
        let parser = XcodeDiagnosticsParser(workspaceRoot: workspaceRoot)
        let buildReport = await extractBuildReport(at: resultBundleURL, parser: parser)
        let testReport = action == .test
            ? await extractTestReport(at: resultBundleURL, parser: parser)
            : nil

        let summary = renderExecution(
            action: action,
            description: description,
            scheme: scheme,
            configuration: configuration,
            requestedDestination: destination,
            command: command,
            buildReport: buildReport,
            testReport: testReport,
            parser: parser
        )
        return XcodeVerificationExecution(
            succeeded: command.exitCode == 0
                && !command.timedOut
                && !command.cancelled,
            cancelled: command.cancelled,
            summary: summary
        )
    }

    private func extractBuildReport(
        at resultBundleURL: URL,
        parser: XcodeDiagnosticsParser
    ) async -> XcodeBuildReport? {
        guard FileManager.default.fileExists(atPath: resultBundleURL.path) else { return nil }
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "xcresulttool", "get", "build-results",
                "--path", resultBundleURL.path, "--compact"
            ],
            workingDirectory: URL(fileURLWithPath: workspaceRoot),
            timeoutSeconds: 30
        )
        guard case .success(let command) = result,
              command.exitCode == 0,
              let data = command.stdout.data(using: .utf8) else { return nil }
        return parser.buildReport(from: data)
    }

    private func extractTestReport(
        at resultBundleURL: URL,
        parser: XcodeDiagnosticsParser
    ) async -> XcodeTestReport? {
        guard FileManager.default.fileExists(atPath: resultBundleURL.path) else { return nil }
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "xcresulttool", "get", "test-results", "summary",
                "--path", resultBundleURL.path, "--compact"
            ],
            workingDirectory: URL(fileURLWithPath: workspaceRoot),
            timeoutSeconds: 30
        )
        guard case .success(let command) = result,
              command.exitCode == 0,
              let data = command.stdout.data(using: .utf8) else { return nil }
        return parser.testReport(from: data)
    }

    private func render(_ description: XcodeProjectDescription) -> String {
        var sections = [
            "XCODE PROJECT",
            "container: \(description.container.relativePath) (\(description.container.kind.rawValue))"
        ]
        sections.append(list("schemes", values: description.schemes))
        if !description.targets.isEmpty { sections.append(list("targets", values: description.targets)) }
        if !description.configurations.isEmpty {
            sections.append(list("configurations", values: description.configurations))
        }
        sections.append(
            "Next: call xcode_project with action build or test and one of the listed schemes."
        )
        return sections.joined(separator: "\n")
    }

    private func renderExecution(
        action: XcodeProjectAction,
        description: XcodeProjectDescription,
        scheme: String,
        configuration: String?,
        requestedDestination: String?,
        command: XcodeCommandResult,
        buildReport: XcodeBuildReport?,
        testReport: XcodeTestReport?,
        parser: XcodeDiagnosticsParser
    ) -> String {
        let succeeded = command.exitCode == 0 && !command.timedOut && !command.cancelled
        var output = "XCODE \(action.rawValue.uppercased()) \(succeeded ? "SUCCEEDED" : "FAILED")\n"
        output += "container: \(description.container.relativePath)\n"
        output += "scheme: \(scheme)"
        if let configuration { output += " · \(configuration)" }
        output += "\n"
        if let destination = buildReport?.destination ?? requestedDestination {
            output += "destination: \(destination)\n"
        }
        output += String(format: "duration: %.1fs\n", command.duration)
        if command.timedOut { output += "timeout: command stopped at the configured limit\n" }
        if command.cancelled { output += "cancelled: command stopped with the active response\n" }

        if let buildReport {
            output += "diagnostics: \(buildReport.errorCount) errors · \(buildReport.warningCount) warnings"
            if buildReport.analyzerWarningCount > 0 {
                output += " · \(buildReport.analyzerWarningCount) analyzer warnings"
            }
            output += "\n"
            output += renderIssues(buildReport.issues)
        }

        if action == .test, let testReport {
            output += "tests: \(testReport.result) · \(testReport.passedCount)/\(testReport.totalCount) passed"
            if testReport.failedCount > 0 { output += " · \(testReport.failedCount) failed" }
            if testReport.skippedCount > 0 { output += " · \(testReport.skippedCount) skipped" }
            output += "\n"
            if enhancedOutput, !testReport.environment.isEmpty {
                output += "environment: \(testReport.environment)\n"
            }
            output += renderTestFailures(testReport.failures)
        }

        if buildReport == nil && testReport == nil {
            let fallback = parser.fallbackIssues(
                from: command.combinedOutput,
                maximum: enhancedOutput ? 24 : 12
            )
            if fallback.isEmpty {
                output += "diagnostics: structured xcresult summary unavailable\n"
                output += compactFailure(command.combinedOutput) + "\n"
            } else {
                output += "diagnostics (fallback):\n"
                output += fallback.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
        }

        if !succeeded {
            output += "Focus on the first source error, make a scoped change, then run this same action again."
        }
        return String(output.prefix(enhancedOutput ? 18_000 : 10_000))
    }

    private func renderIssues(_ issues: [XcodeIssue]) -> String {
        let maximum = enhancedOutput ? 24 : 12
        guard !issues.isEmpty else { return "" }
        var lines = ["ISSUES"]
        for issue in issues.prefix(maximum) {
            var location = issue.sourcePath ?? issue.targetName ?? "project"
            if let line = issue.line { location += ":\(line)" }
            lines.append("- [\(issue.severity.rawValue)] \(location) — \(issue.message)")
        }
        if issues.count > maximum { lines.append("- … +\(issues.count - maximum) more issues") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderTestFailures(_ failures: [XcodeTestFailure]) -> String {
        let maximum = enhancedOutput ? 20 : 10
        guard !failures.isEmpty else { return "" }
        var lines = ["TEST FAILURES"]
        for failure in failures.prefix(maximum) {
            lines.append("- \(failure.targetName).\(failure.testName) — \(failure.message)")
        }
        if failures.count > maximum { lines.append("- … +\(failures.count - maximum) more failures") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func resolvedScheme(
        _ requestedScheme: String?,
        in description: XcodeProjectDescription
    ) throws -> String {
        if let requested = normalized(requestedScheme) {
            guard description.schemes.contains(requested) else {
                throw XcodeProjectError.noScheme(
                    "\(description.container.relativePath); requested '\(requested)', available: \(description.schemes.joined(separator: ", "))"
                )
            }
            return requested
        }
        let containerName = description.container.url.deletingPathExtension().lastPathComponent
        if let matchingContainer = description.schemes.first(where: {
            $0.caseInsensitiveCompare(containerName) == .orderedSame
        }) {
            return matchingContainer
        }
        if let matchingTarget = description.schemes.first(where: { scheme in
            description.targets.contains {
                $0.caseInsensitiveCompare(scheme) == .orderedSame
            }
        }) {
            return matchingTarget
        }
        guard let first = description.schemes.first else {
            throw XcodeProjectError.noScheme(description.container.relativePath)
        }
        return first
    }

    private func commandResult(
        from result: Result<XcodeCommandResult, XcodeProjectError>
    ) throws -> XcodeCommandResult {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private func boundedTimeout(_ requested: Int?) -> Int {
        min(
            max(requested ?? executionPolicy.maximumCommandTimeoutSeconds, 5),
            executionPolicy.maximumCommandTimeoutSeconds
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func list(_ label: String, values: [String]) -> String {
        values.isEmpty ? "\(label): none" : "\(label): \(values.joined(separator: ", "))"
    }

    private func compactFailure(_ output: String) -> String {
        let lines = output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.suffix(8).joined(separator: "\n")
    }
}

private nonisolated struct ProjectListPayload: Decodable {
    let project: ProjectListContents?
    let workspace: ProjectListContents?
}

private nonisolated struct ProjectListContents: Decodable {
    let schemes: [String]?
    let targets: [String]?
    let configurations: [String]?
}
