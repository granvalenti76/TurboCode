import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A small picture of an artifact: a thumbnail of the file itself where the
/// system can make one, otherwise the symbol of its kind.
///
/// Shared by the library's cards and the inspector's strip so the same file
/// looks the same in both places. The caller decides the size and the frame.
struct CoworkArtifactThumbnailView: View {
    let artifact: CoworkArtifact
    let fileURL: URL?
    /// Changes when the outbox was read again, so a file the agent rewrote in
    /// place gets a fresh thumbnail.
    let revision: Int
    var symbolSize: CGFloat = 30
    var cornerRadius: CGFloat = 10

    @State private var thumbnail: NSImage?

    /// Large enough for a library card at Retina scale; the strip scales the
    /// same image down rather than asking Quick Look twice.
    private static let requestSize = CGSize(width: 440, height: 330)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(cornerRadius * 0.4)
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
