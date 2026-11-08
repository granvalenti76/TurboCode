import AppKit
import SwiftUI

// MARK: - ImageThumbnailView

/// Square preview shared by the composer draft and the sent user message.
struct ImageThumbnailView: View {
    let thumbnail: ChatImageThumbnail
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(data: thumbnail.jpegData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .help(thumbnail.fileName)
        .accessibilityLabel("Image \(thumbnail.fileName)")
    }
}
