import Darwin
import Foundation
import Testing
@testable import TurboCode

/// The approved export is the only path from the Cowork VM to the user's
/// folders. These tests pin what may cross, what never crosses, and that a
/// reviewed decision cannot be applied to files that changed afterwards.
@Suite("Cowork export")
struct CoworkExportTests {
    // MARK: Planner

    @Test("Files are classified as new, conflicting, or identical")
    func planClassifiesFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeOutbox("site/index.html", "<h1>new</h1>")
        try fixture.writeOutbox("notes.md", "same")
        try fixture.writeDestination("notes.md", "same")
        try fixture.writeOutbox("chapter.md", "revised\n")
        try fixture.writeDestination("chapter.md", "original\n")

        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        let kinds = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.relativePath, $0.kind) })
        #expect(kinds["site/index.html"] == .new)
        #expect(kinds["notes.md"] == .identical)
        guard case .conflict = kinds["chapter.md"] else {
            Issue.record("chapter.md should conflict")
            return
        }
        #expect(plan.items.first { $0.relativePath == "chapter.md" }?.isText == true)
        #expect(plan.items.map { CoworkExportDecision.default(for: $0) } == [.skip, .skip, .copy])
    }

    @Test("Build folders are excluded without reading their contents")
    func planExcludesBuildFolders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeOutbox("app/node_modules/react/index.js", "x")
        try fixture.writeOutbox("app/.git/HEAD", "ref")
        try fixture.writeOutbox("app/src/main.jsx", "x")

        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        #expect(plan.items.map(\.relativePath) == ["app/src/main.jsx"])
        #expect(Set(plan.skipped.map(\.relativePath)) == ["app/node_modules", "app/.git"])
        #expect(plan.skipped.allSatisfy { $0.reason == .excluded })
    }

    @Test("Symbolic links and special files are never exported or followed")
    func planSkipsLinksAndSpecialFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(
            at: fixture.outbox.appendingPathComponent("hosts"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        try fileManager.createSymbolicLink(
            at: fixture.outbox.appendingPathComponent("home"),
            withDestinationURL: fileManager.homeDirectoryForCurrentUser
        )
        #expect(mkfifo(fixture.outbox.appendingPathComponent("pipe").path, 0o644) == 0)

        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        #expect(plan.items.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.relativePath, $0.reason) })
        #expect(reasons["hosts"] == .symbolicLink)
        #expect(reasons["home"] == .symbolicLink)
        #expect(reasons["pipe"] == .notRegularFile)
    }

    @Test("A link inside the destination cannot redirect the copy elsewhere")
    func planRejectsEscapingDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.destination.appendingPathComponent("docs"),
            withDestinationURL: elsewhere
        )
        try fixture.writeOutbox("docs/readme.md", "x")
        try fixture.writeOutbox("report", "x")
        try FileManager.default.createDirectory(
            at: fixture.destination.appendingPathComponent("report"),
            withIntermediateDirectories: true
        )

        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        #expect(plan.items.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.relativePath, $0.reason) })
        #expect(reasons["docs/readme.md"] == .unsafeDestination)
        #expect(reasons["report"] == .destinationIsDirectory)
    }

    @Test("Large exports are flagged for explicit confirmation")
    func planFlagsLargeExports() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for index in 0...CoworkExportPlan.maximumFiles {
            try Data().write(to: fixture.outbox.appendingPathComponent("f\(index)"))
        }

        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        #expect(plan.exceedsLimits)
    }

    // MARK: Service

    @Test("Copied files lose execute permission and carry the quarantine attribute")
    func exportNeutralizesFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.writeOutbox("bin/run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        let report = await CoworkExportService().export(plan: plan, decisions: [:])

        let exported = fixture.destination.appendingPathComponent("bin/run.sh")
        #expect(report.copiedCount == 1)
        #expect(try String(contentsOf: exported, encoding: .utf8) == "#!/bin/sh\necho hi\n")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.uint16Value & 0o111 == 0)
        #expect(getxattr(exported.path, CoworkExportService.quarantineAttribute, nil, 0, 0, 0) > 0)
        // No staging folder is left in the user's folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)
        #expect(!leftovers.contains { $0.hasPrefix(".turbocode-export-") })
    }

    @Test("Conflicts are untouched by default, replaced or kept both only when chosen")
    func exportConflictDecisions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeOutbox("a.md", "new a")
        try fixture.writeDestination("a.md", "old a")
        try fixture.writeOutbox("b.md", "new b")
        try fixture.writeDestination("b.md", "old b")
        try fixture.writeOutbox("c.md", "new c")
        try fixture.writeDestination("c.md", "old c")
        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        _ = await CoworkExportService().export(plan: plan, decisions: ["b.md": .replace, "c.md": .keepBoth])

        #expect(try fixture.readDestination("a.md") == "old a")
        #expect(try fixture.readDestination("b.md") == "new b")
        #expect(try fixture.readDestination("c.md") == "old c")
        #expect(try fixture.readDestination("c 2.md") == "new c")
    }

    @Test("Files changed after review are reported, never overwritten")
    func exportRejectsChangesAfterReview() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeOutbox("draft.md", "agent v1")
        try fixture.writeDestination("draft.md", "mac v1")
        try fixture.writeOutbox("new.md", "agent")
        try fixture.writeOutbox("moving.md", "agent v1")
        let plan = try CoworkExportPlanner.plan(outbox: fixture.outbox, destination: fixture.destination)

        try fixture.writeDestination("draft.md", "mac v2 edited during review")
        try fixture.writeDestination("new.md", "appeared during review")
        try fixture.writeOutbox("moving.md", "agent v2 written during review")
        let report = await CoworkExportService().export(
            plan: plan,
            decisions: ["draft.md": .replace, "new.md": .copy, "moving.md": .copy]
        )

        #expect(report.changedCount == 3)
        #expect(try fixture.readDestination("draft.md") == "mac v2 edited during review")
        #expect(try fixture.readDestination("new.md") == "appeared during review")
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("moving.md").path))
    }

    // MARK: Diffs

    @Test("Review diffs count lines, reject binary text, and are marked as Cowork")
    func reviewDiffs() throws {
        let counts = UnifiedTextDiff.lineCounts(original: "a\nb\nc", modified: "a\nB\nc\nd")
        #expect(counts.additions == 2)
        #expect(counts.deletions == 1)
        #expect(UnifiedTextDiff.reviewableText(Data([0x61, 0x00, 0x62])) == nil)

        let block = UnifiedTextDiff.reviewBlock(
            path: "chapter.md", original: "old\n", modified: "new\n", root: "/tmp", location: .coworkVM
        )
        #expect(block.isCoworkVM)
        #expect(block.patch.contains("-old"))
        #expect(block.patch.contains("+new"))
        #expect(block.reviewFiles?.first?.modifiedText == "new\n")
    }

    @Test("Receipts saved before 0.62 decode as Mac workspace changes")
    func legacyDiffReceiptsAreWorkspace() throws {
        let block = DiffPatchBlock(
            workspaceRoot: "/w", patch: "", patches: nil, files: [], reviewFiles: nil,
            status: .applied, errorMessage: nil
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any]
        )
        object.removeValue(forKey: "location")
        let decoded = try JSONDecoder().decode(
            DiffPatchBlock.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.location == nil)
        #expect(!decoded.isCoworkVM)
    }
}

// MARK: - Fixture

private struct Fixture {
    let root: URL
    let outbox: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoworkExportTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        outbox = root.appendingPathComponent("outbox", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    @discardableResult
    func writeOutbox(_ path: String, _ text: String) throws -> URL {
        try write(text, to: outbox.appendingPathComponent(path))
    }

    @discardableResult
    func writeDestination(_ path: String, _ text: String) throws -> URL {
        try write(text, to: destination.appendingPathComponent(path))
    }

    func readDestination(_ path: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
