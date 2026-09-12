import Foundation
import Testing
@testable import TurboCode

@Suite("Workspace file preview service")
struct WorkspaceFilePreviewServiceTests {
    @Test("Markdown preview reads bounded UTF-8 content inside the workspace")
    func loadsMarkdownContent() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("# Preview\n\nBody".utf8).write(
            to: workspace.appendingPathComponent("notes.md")
        )

        let preview = try await WorkspaceFilePreviewService().load(
            relativePath: "notes.md",
            workspaceRoot: workspace.path
        )

        #expect(preview.kind == .markdown)
        #expect(preview.content == "# Preview\n\nBody")
        #expect(preview.fileName == "notes.md")
        #expect(preview.sizeBytes == 15)
        #expect(preview.previewedByteCount == 15)
        #expect(!preview.isTruncated)
    }

    @Test("Large files become partial previews without splitting UTF-8")
    func truncatesLargePreviewAtAValidScalarBoundary() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let content = "abcérest"
        try Data(content.utf8).write(
            to: workspace.appendingPathComponent("large.txt")
        )

        let preview = try await WorkspaceFilePreviewService().load(
            relativePath: "large.txt",
            workspaceRoot: workspace.path,
            maximumByteCount: 4
        )

        #expect(preview.content == "abc")
        #expect(preview.previewedByteCount == 3)
        #expect(preview.sizeBytes == content.lengthOfBytes(using: .utf8))
        #expect(preview.isTruncated)
    }

    @Test("Unsupported, invalid UTF-8, and missing files stay explicit")
    func rejectsUnavailablePreviewContent() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data([0xFF]).write(to: workspace.appendingPathComponent("invalid.txt"))
        try Data([0x00]).write(to: workspace.appendingPathComponent("image.png"))
        let service = WorkspaceFilePreviewService()

        await #expect(throws: WorkspaceFilePreviewError.invalidUTF8("invalid.txt")) {
            try await service.load(
                relativePath: "invalid.txt",
                workspaceRoot: workspace.path
            )
        }
        await #expect(throws: WorkspaceFilePreviewError.unsupportedFormat("image.png")) {
            try await service.load(
                relativePath: "image.png",
                workspaceRoot: workspace.path
            )
        }
        await #expect(throws: WorkspaceFilePreviewError.unavailable("missing.md")) {
            try await service.load(
                relativePath: "missing.md",
                workspaceRoot: workspace.path
            )
        }
    }

    @Test("Workspace path validation rejects an escaped preview")
    func rejectsPathOutsideWorkspace() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        await #expect(throws: (any Error).self) {
            try await WorkspaceFilePreviewService().load(
                relativePath: "../outside.md",
                workspaceRoot: workspace.path
            )
        }
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilePreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
