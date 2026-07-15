import Foundation

/// Converts xcresult's stable JSON summaries into small domain reports. The
/// renderer deliberately caps individual issues so compiler logs don't consume
/// the model's working context.
nonisolated struct XcodeDiagnosticsParser: Sendable {
    let workspaceRoot: String

    func buildReport(from data: Data) -> XcodeBuildReport? {
        guard let value = try? JSONDecoder().decode(BuildResultsPayload.self, from: data) else {
            return nil
        }
        let issues = value.errors.map { issue($0, severity: .error) }
            + value.warnings.map { issue($0, severity: .warning) }
            + value.analyzerWarnings.map { issue($0, severity: .analyzerWarning) }
        let destination = [value.destination?.platform, value.destination?.deviceName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return XcodeBuildReport(
            status: value.status,
            errorCount: value.errorCount ?? value.errors.count,
            warningCount: value.warningCount ?? value.warnings.count,
            analyzerWarningCount: value.analyzerWarningCount ?? value.analyzerWarnings.count,
            issues: issues,
            duration: duration(start: value.startTime, end: value.endTime),
            destination: destination.isEmpty ? nil : destination
        )
    }

    func testReport(from data: Data) -> XcodeTestReport? {
        guard let value = try? JSONDecoder().decode(TestSummaryPayload.self, from: data) else {
            return nil
        }
        return XcodeTestReport(
            result: value.result,
            totalCount: value.totalTestCount,
            passedCount: value.passedTests,
            failedCount: value.failedTests,
            skippedCount: value.skippedTests,
            failures: value.testFailures.map {
                XcodeTestFailure(
                    testName: $0.testName,
                    targetName: $0.targetName,
                    message: compactWhitespace($0.failureText)
                )
            },
            duration: duration(start: value.startTime, end: value.finishTime),
            environment: compactWhitespace(value.environmentDescription)
        )
    }

    func fallbackIssues(from output: String, maximum: Int) -> [String] {
        let markers = [": error:", ": warning:", "Testing failed:", "BUILD FAILED", "TEST FAILED"]
        var seen = Set<String>()
        return output.split(whereSeparator: \Character.isNewline).compactMap { raw -> String? in
            let line = compactWhitespace(raw.description)
            guard markers.contains(where: line.contains), seen.insert(line).inserted else { return nil }
            return abbreviatedWorkspacePath(in: line)
        }.prefix(maximum).map { $0 }
    }

    private func issue(_ value: IssuePayload, severity: XcodeIssue.Severity) -> XcodeIssue {
        let location = sourceLocation(value.sourceURL)
        return XcodeIssue(
            severity: severity,
            message: compactWhitespace(value.message),
            sourcePath: location.path,
            line: location.line,
            targetName: value.targetName
        )
    }

    private func sourceLocation(_ rawURL: String?) -> (path: String?, line: Int?) {
        guard let rawURL, let url = URL(string: rawURL) else { return (nil, nil) }
        let path = abbreviatedPath(url.path)
        let line = URLComponents(string: rawURL)?.fragment?
            .split(separator: "&")
            .first(where: { $0.hasPrefix("StartingLineNumber=") })?
            .split(separator: "=").last
            .flatMap { Int($0) }
        return (path, line)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let root = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        if path == root { return "." }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func abbreviatedWorkspacePath(in text: String) -> String {
        text.replacingOccurrences(
            of: URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path + "/",
            with: ""
        )
    }

    private func duration(start: Double?, end: Double?) -> TimeInterval? {
        guard let start, let end, end >= start else { return nil }
        return end - start
    }

    private func compactWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}

private nonisolated struct BuildResultsPayload: Decodable {
    let status: String?
    let startTime: Double?
    let endTime: Double?
    let analyzerWarningCount: Int?
    let errorCount: Int?
    let warningCount: Int?
    let analyzerWarnings: [IssuePayload]
    let warnings: [IssuePayload]
    let errors: [IssuePayload]
    let destination: DevicePayload?
}

private nonisolated struct DevicePayload: Decodable {
    let deviceName: String?
    let platform: String?
}

private nonisolated struct IssuePayload: Decodable {
    let message: String
    let targetName: String?
    let sourceURL: String?
}

private nonisolated struct TestSummaryPayload: Decodable {
    let startTime: Double?
    let finishTime: Double?
    let environmentDescription: String
    let result: String
    let totalTestCount: Int
    let passedTests: Int
    let failedTests: Int
    let skippedTests: Int
    let testFailures: [TestFailurePayload]
}

private nonisolated struct TestFailurePayload: Decodable {
    let testName: String
    let targetName: String
    let failureText: String
}
