import Foundation
import Testing
@testable import TurboCode

@Suite("Git diff service")
struct GitDiffServiceTests {
    @Test("Large diff output is drained without blocking", .timeLimit(.minutes(1)))
    @MainActor
    func largeDiffOutputIsDrainedWithoutBlocking() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        try runGit(["init", "--quiet"], at: repository)
        let file = repository.appendingPathComponent("large.txt")
        let original = (0..<12_000).map { "original line \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "large.txt"], at: repository)
        try runGit(
            ["-c", "user.name=TurboCode Tests", "-c", "user.email=tests@turbocode.local", "commit", "--quiet", "-m", "baseline"],
            at: repository
        )

        let changed = (0..<12_000).map { "changed line \($0)" }.joined(separator: "\n") + "\n"
        try changed.write(to: file, atomically: true, encoding: .utf8)

        let lines = try await GitDiffService().fetchDiff(for: "large.txt", at: repository)

        #expect(lines.count == 24_000)
        #expect(lines.first?.type == .removed)
        #expect(lines.last?.type == .added)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
