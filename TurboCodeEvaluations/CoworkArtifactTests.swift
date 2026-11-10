import Foundation
import Testing
@testable import TurboCode

/// The Artifacts inspector is a read-only view of a session outbox. These
/// tests pin what it lists, which file it opens first, and that a path can
/// never resolve outside the outbox.
@Suite("Cowork artifacts")
struct CoworkArtifactTests {
    @Test("Artifacts are the exportable files, without build folders or links")
    func listingMatchesTheExportRules() throws {
        let outbox = try Self.makeOutbox()
        defer { try? FileManager.default.removeItem(at: outbox) }
        try Self.write("site/index.html", "<h1>hi</h1>", in: outbox)
        try Self.write("site/node_modules/react/index.js", "x", in: outbox)
        try Self.write("report.pdf", "%PDF", in: outbox)
        try FileManager.default.createSymbolicLink(
            at: outbox.appendingPathComponent("passwd"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )

        let artifacts = CoworkArtifactCatalog.artifacts(in: outbox)

        #expect(artifacts.map(\.relativePath) == ["report.pdf", "site/index.html"])
        #expect(artifacts.map(\.relativePath) == CoworkExportPlanner.deliverables(in: outbox).map(\.path))
        #expect(artifacts.first { $0.name == "index.html" }?.size == 11)
    }

    @Test("The preview kind follows the file extension, whatever its case")
    func kindFollowsExtension() {
        #expect(CoworkArtifact.kind(forPath: "site/INDEX.HTML") == .webPage)
        #expect(CoworkArtifact.kind(forPath: "page.png") == .image)
        #expect(CoworkArtifact.kind(forPath: "logo.svg") == .image)
        #expect(CoworkArtifact.kind(forPath: "report.pdf") == .pdf)
        #expect(CoworkArtifact.kind(forPath: "src/app.tsx") == .text)
        #expect(CoworkArtifact.kind(forPath: "data.csv") == .text)
        #expect(CoworkArtifact.kind(forPath: "bundle.zip") == .other)
        #expect(CoworkArtifact.kind(forPath: "Makefile") == .other)
    }

    @Test("The first artifact shown is the shallowest index.html, then any page, then any preview")
    func preferredArtifactFavorsTheEntryPage() {
        func artifacts(_ paths: String...) -> [CoworkArtifact] {
            paths.map { CoworkArtifact(relativePath: $0, size: 1) }
        }

        #expect(CoworkArtifactCatalog.preferred(
            in: artifacts("a.zip", "dist/assets/index.html", "dist/index.html", "page.png")
        )?.relativePath == "dist/index.html")
        #expect(CoworkArtifactCatalog.preferred(
            in: artifacts("a.zip", "docs/deep/about.html", "about.html")
        )?.relativePath == "about.html")
        #expect(CoworkArtifactCatalog.preferred(in: artifacts("a.zip", "page.png"))?.relativePath == "page.png")
        #expect(CoworkArtifactCatalog.preferred(in: artifacts("a.zip"))?.relativePath == "a.zip")
        #expect(CoworkArtifactCatalog.preferred(in: []) == nil)
    }

    @Test("The list shows pages first, then images, PDFs, text, and other files, each by path")
    func displayOrderGroupsByWhatCanBePreviewed() {
        let ordered = CoworkArtifactCatalog.displayOrdered(
            ["a.zip", "notes.md", "shot10.png", "shot2.png", "report.pdf", "site/index.html"]
                .map { CoworkArtifact(relativePath: $0, size: 1) }
        )

        #expect(ordered.map(\.relativePath) == [
            "site/index.html", "shot2.png", "shot10.png", "report.pdf", "notes.md", "a.zip"
        ])
    }

    @Test("After a reload the preview follows a new file, else keeps the user's choice")
    func selectionFollowsNewWork() {
        func artifacts(_ paths: String...) -> [CoworkArtifact] {
            paths.map { CoworkArtifact(relativePath: $0, size: 1) }
        }
        let before = artifacts("index.html", "page.png")

        // First load of a session: nothing is new, the entry page opens.
        #expect(CoworkArtifactCatalog.selection(current: nil, previous: nil, updated: before)?.id == "index.html")
        // Nothing changed: the user's choice stays.
        #expect(CoworkArtifactCatalog.selection(current: "page.png", previous: before, updated: before)?.id == "page.png")
        // The agent added a screenshot: the preview moves to it.
        #expect(CoworkArtifactCatalog.selection(
            current: "index.html", previous: before, updated: artifacts("index.html", "page.png", "chart.png")
        )?.id == "chart.png")
        // A new file without a preview does not steal the selection.
        #expect(CoworkArtifactCatalog.selection(
            current: "page.png", previous: before, updated: artifacts("index.html", "page.png", "site.zip")
        )?.id == "page.png")
        // The chosen file was removed: fall back to the entry page.
        #expect(CoworkArtifactCatalog.selection(
            current: "page.png", previous: before, updated: artifacts("index.html")
        )?.id == "index.html")
        #expect(CoworkArtifactCatalog.selection(current: "page.png", previous: before, updated: []) == nil)
    }

    // MARK: Live previews

    @Test("Only servers listening on every interface above the system ports are offered")
    func probeOffersReachableServers() {
        let output = """
        00000000:0BB8
        0100007F:1F90
        00000000:0035
        00000000000000000000000000000000:1435
        00000000000000000000000001000000:2328
        00000000:0BB8
        ---
        192.168.64.3 fd00::3

        """

        let previews = CoworkLivePreviewProbe.parse(output)

        // 3000 on 0.0.0.0 and 5173 on [::]; loopback 8080 and 9000 and the
        // DNS port 53 are left out, and the duplicate is listed once.
        #expect(previews.map(\.port) == [3000, 5173])
        #expect(previews.first?.url?.absoluteString == "http://192.168.64.3:3000/")
        #expect(previews.first?.id == "/live/3000")
    }

    @Test("Without a guest IPv4 address or with unexpected output nothing is offered")
    func probeNeedsAnAddress() {
        #expect(CoworkLivePreviewProbe.parse("00000000:0BB8\n---\n\n").isEmpty)
        #expect(CoworkLivePreviewProbe.parse("00000000:0BB8\n---\nfd00::3\n").isEmpty)
        #expect(CoworkLivePreviewProbe.parse("---\n192.168.64.3\n").isEmpty)
        #expect(CoworkLivePreviewProbe.parse("bash: awk: command not found").isEmpty)
        #expect(CoworkLivePreviewProbe.parse("").isEmpty)
    }

    @Test("A server that starts takes the preview; a file keeps it otherwise")
    func liveSelectionFollowsARunningServer() {
        let server = CoworkLivePreview(port: 3000, host: "192.168.64.3")
        let other = CoworkLivePreview(port: 5173, host: "192.168.64.3")
        let page = CoworkArtifact(relativePath: "index.html", size: 1)
        func select(_ current: String?, _ previous: [CoworkLivePreview]?, _ updated: [CoworkLivePreview]) -> String? {
            CoworkLivePreviewSelection.selection(
                current: current, previousLive: previous, updatedLive: updated, artifact: page
            )
        }

        // First load with nothing chosen: the running server is the current work.
        #expect(select(nil, nil, [server]) == server.id)
        // A server started during the session takes over from a file.
        #expect(select(page.id, [], [server]) == server.id)
        #expect(select(server.id, [server], [server, other]) == other.id)
        // Nothing new: the selection stays, whether server or file.
        #expect(select(server.id, [server], [server]) == server.id)
        #expect(select(page.id, [server], [server]) == page.id)
        // The server stopped: fall back to the file.
        #expect(select(server.id, [server], []) == page.id)
        // No file at all: any running server is better than an empty panel.
        #expect(CoworkLivePreviewSelection.selection(
            current: "gone.png", previousLive: [server], updatedLive: [server], artifact: nil
        ) == server.id)
    }

    @Test("An artifact path resolves inside the outbox or not at all")
    func fileURLStaysInsideTheOutbox() throws {
        let outbox = try Self.makeOutbox()
        defer { try? FileManager.default.removeItem(at: outbox) }
        try Self.write("site/index.html", "x", in: outbox)

        let inside = CoworkArtifactCatalog.fileURL(
            for: CoworkArtifact(relativePath: "site/index.html", size: 1), in: outbox
        )
        #expect(inside?.path.hasSuffix("/site/index.html") == true)
        #expect(FileManager.default.fileExists(atPath: inside?.path ?? ""))

        for escaping in ["../secret.txt", "site/../../secret.txt", "../\(outbox.lastPathComponent)-other/x"] {
            #expect(CoworkArtifactCatalog.fileURL(
                for: CoworkArtifact(relativePath: escaping, size: 1), in: outbox
            ) == nil, "\(escaping) must not resolve")
        }
    }

    @Test("The inspector source reads the outbox and never copies or exports by itself")
    func inspectorOnlyReads() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TurboCode/Views/Inspector/CoworkArtifactsInspectorView.swift"),
            encoding: .utf8
        )
        for forbidden in ["copyItem", "moveItem", "write(to", "CoworkExportService", "NSWorkspace", "addScriptMessageHandler", ".add("] {
            #expect(!source.contains(forbidden), "The artifacts inspector must not use \(forbidden)")
        }
    }

    // MARK: Helpers

    static func makeOutbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ path: String, _ content: String, in outbox: URL) throws {
        let url = outbox.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }
}
