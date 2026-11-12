import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A small picture of an artifact: a thumbnail of the file itself where one
/// can be made (a rendered page, or what Quick Look provides for other kinds),
/// otherwise the symbol of its kind.
///
/// Shared by the library's cards and the inspector's strip so the same file
/// looks the same in both places. The caller decides the size and the frame.
struct CoworkArtifactThumbnailView: View {
    let artifact: CoworkArtifact
    let fileURL: URL?
    /// The session's outbox. With it, a web page is rendered for its thumbnail
    /// instead of asking Quick Look, which cannot run the page's scripts.
    var outbox: URL? = nil
    /// Changes when the outbox was read again, so a file the agent rewrote in
    /// place gets a fresh thumbnail.
    let revision: Int
    var symbolSize: CGFloat = 30
    var cornerRadius: CGFloat = 10
    /// Lets a page or an image cover the whole frame from its top edge, as a
    /// library card wants: fitted with a margin, a tall screenshot shrinks to a
    /// narrow strip. Other kinds stay fitted so a document page is not cropped.
    var fillsFrame = false

    @State private var thumbnail: NSImage?

    /// Large enough for a library card at Retina scale; the strip scales the
    /// same image down rather than asking Quick Look twice.
    private static let requestSize = CGSize(width: 440, height: 330)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            if let thumbnail {
                if fillsFrame, artifact.kind == .webPage || artifact.kind == .image {
                    // The clear color takes the frame's size; the overlay pins
                    // the oversized image to the top and the clip trims it.
                    Color.clear.overlay(alignment: .top) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                } else {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(cornerRadius * 0.4)
                }
            } else {
                Image(systemName: artifact.kind.symbolName)
                    .font(.system(size: symbolSize, weight: .light))
                    .foregroundStyle(artifact.kind.tint)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(artifact.id)|\(revision)") { await load() }
    }

    /// Asks Quick Look for a real thumbnail only. When the system has none for
    /// the type, the kind symbol stays instead of a generic document icon,
    /// which says more about what the file is.
    private func load() async {
        guard let fileURL, artifact.kind != .other else { return }
        if artifact.kind == .webPage, let outbox {
            // No Quick Look fallback: its black or white rectangle is worse
            // than the kind symbol that shows while, or instead of, a render.
            if let rendered = await CoworkPageThumbnailRenderer.shared.thumbnail(for: fileURL, outbox: outbox) {
                thumbnail = rendered
            }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: Self.requestSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return
        }
        thumbnail = representation.nsImage
    }
}
