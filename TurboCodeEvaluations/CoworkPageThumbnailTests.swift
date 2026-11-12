import AppKit
import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Cowork page thumbnails")
struct CoworkPageThumbnailTests {
    @Test("A page rewritten in place gets a new cache key; an untouched one keeps its key")
    func keyFollowsTheFileContent() throws {
        let outbox = try Self.makeOutbox()
        defer { try? FileManager.default.removeItem(at: outbox) }
        let page = outbox.appendingPathComponent("index.html")
        try Data("<p>one</p>".utf8).write(to: page)

        let first = CoworkPageThumbnailRenderer.Key(fileURL: page)
        #expect(first == CoworkPageThumbnailRenderer.Key(fileURL: page))

        try Data("<p>a longer second version</p>".utf8).write(to: page)
        #expect(first != CoworkPageThumbnailRenderer.Key(fileURL: page))
    }

    @Test("A page is rendered with its styles applied, and the result is reused")
    func rendersThePageAndCachesIt() async throws {
        let outbox = try Self.makeOutbox()
        defer { try? FileManager.default.removeItem(at: outbox) }
        let page = outbox.appendingPathComponent("index.html")
        // The color comes from a sibling stylesheet, so the test also covers
        // read access to the rest of the outbox.
        try Data("html, body { margin: 0; background: #ff0000; }".utf8)
            .write(to: outbox.appendingPathComponent("style.css"))
        try Data(#"<html><head><link rel="stylesheet" href="style.css"></head><body></body></html>"#.utf8)
            .write(to: page)

        let renderer = CoworkPageThumbnailRenderer()
        let image = try #require(await renderer.thumbnail(for: page, outbox: outbox))

        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        )
        #expect(color.redComponent > 0.8)
        #expect(color.greenComponent < 0.3)
        #expect(color.blueComponent < 0.3)
        #expect(abs(image.size.width / image.size.height - 4.0 / 3.0) < 0.01)

        let again = await renderer.thumbnail(for: page, outbox: outbox)
        #expect(again === image)
    }

    private static func makeOutbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
