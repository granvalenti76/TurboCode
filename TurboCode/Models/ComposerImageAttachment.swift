import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

// MARK: - ComposerImageAttachment

/// One image waiting in the composer or travelling with a native turn.
///
/// Holds re-encoded JPEG bytes rather than the source URL so the model receives
/// the image as it looked when dropped, even if the file later moves or changes.
nonisolated struct ComposerImageAttachment: Identifiable, Sendable, Hashable {
    let id: UUID
    let fileName: String
    /// Sent to the model. Bounded by `ComposerImagePolicy.maxModelPixelEdge`.
    let modelJPEGData: Data
    /// Rendered by the composer and timeline. Kept small because `ChatBlock`
    /// hashes its contents whenever the timeline diffs.
    let thumbnailJPEGData: Data

    var thumbnail: ChatImageThumbnail {
        ChatImageThumbnail(id: id, fileName: fileName, jpegData: thumbnailJPEGData)
    }
}

// MARK: - ComposerImagePolicy

nonisolated enum ComposerImagePolicy {
    static let maxAttachmentCount = 4
    static let maxSourceByteCount = 20 * 1_024 * 1_024
    /// A prompt image stays in the session transcript and is re-sent on every
    /// later turn, so its size is a recurring cost rather than a one-off upload.
    static let maxModelPixelEdge = 1_568
    static let thumbnailPixelEdge = 160
}

nonisolated enum ComposerImageNotice {
    static let visionUnsupported = "This model doesn't support images."
    static let notAnImage = "Only image files can be added."
    static let tooManyImages = "You can attach up to \(ComposerImagePolicy.maxAttachmentCount) images."
    static let tooLarge = "Images must be under \(ComposerImagePolicy.maxSourceByteCount / 1_048_576) MB."
    static let unreadable = "This image couldn't be read."
}

// MARK: - ComposerImageLoader

/// Decodes a dropped file into normalized attachment data. Performs file I/O, so
/// callers run it away from the main actor.
nonisolated enum ComposerImageLoader {
    enum LoadError: Error, Equatable {
        case notAnImage
        case tooLarge
        case unreadable
    }

    static func load(
        from url: URL,
        maxSourceByteCount: Int = ComposerImagePolicy.maxSourceByteCount
    ) throws(LoadError) -> ComposerImageAttachment {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
              values.contentType?.conforms(to: .image) == true else {
            throw .notAnImage
        }
        guard (values.fileSize ?? 0) <= maxSourceByteCount else {
            throw .tooLarge
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let modelData = jpegData(from: source, longestEdge: ComposerImagePolicy.maxModelPixelEdge),
              let thumbnailData = jpegData(from: source, longestEdge: ComposerImagePolicy.thumbnailPixelEdge)
        else {
            throw .unreadable
        }
        return ComposerImageAttachment(
            id: UUID(),
            fileName: url.lastPathComponent,
            modelJPEGData: modelData,
            thumbnailJPEGData: thumbnailData
        )
    }

    /// Applies EXIF orientation and flattens transparency onto white, because
    /// JPEG has no alpha and transparent pixels would otherwise turn black.
    private static func jpegData(from source: CGImageSource, longestEdge: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            flattened,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - ComposerImageIntake

/// Decides what one drop adds to the draft and which single notice it shows.
nonisolated enum ComposerImageIntake {
    struct Outcome: Sendable {
        var attachments: [ComposerImageAttachment] = []
        var notice: String?
    }

    /// The vision check runs only once the drop holds a candidate image, so
    /// dropping an unrelated file never waits on a server probe.
    static func process(
        urls: [URL],
        existingCount: Int,
        supportsVision: @Sendable () async -> Bool
    ) async -> Outcome {
        guard !urls.isEmpty else { return Outcome() }
        guard urls.contains(where: isImageFile) else {
            return Outcome(notice: ComposerImageNotice.notAnImage)
        }
        guard await supportsVision() else {
            return Outcome(notice: ComposerImageNotice.visionUnsupported)
        }

        var outcome = Outcome()
        let capacity = ComposerImagePolicy.maxAttachmentCount - existingCount
        for url in urls {
            if outcome.attachments.count >= capacity {
                outcome.notice = ComposerImageNotice.tooManyImages
                break
            }
            do {
                outcome.attachments.append(try ComposerImageLoader.load(from: url))
            } catch {
                outcome.notice = switch error {
                case .notAnImage: ComposerImageNotice.notAnImage
                case .tooLarge: ComposerImageNotice.tooLarge
                case .unreadable: ComposerImageNotice.unreadable
                }
            }
        }
        return outcome
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .image) == true
    }
}

// MARK: - ChatImageReference

/// Text marker recording that a user message carried images.
///
/// Image bytes are deliberately never written to disk. The marker is what
/// survives in the stored session, so a reopened conversation shows, and tells
/// the model, that an image existed instead of silently dropping that fact.
nonisolated enum ChatImageReference {
    static func appending(fileNames: [String], to text: String) -> String {
        guard !fileNames.isEmpty else { return text }
        return text + suffix(for: fileNames)
    }

    /// Hides the marker while the live thumbnails already show the same images.
    static func removing(fileNames: [String], from text: String) -> String {
        let marker = suffix(for: fileNames)
        guard !fileNames.isEmpty, text.hasSuffix(marker) else { return text }
        return String(text.dropLast(marker.count))
    }

    private static func suffix(for fileNames: [String]) -> String {
        "\n\n" + fileNames.map { "[Image: \($0)]" }.joined(separator: "\n")
    }
}

// MARK: - Prompt assembly

extension ComposerImageAttachment {
    /// Builds the multimodal prompt for one turn. Decoding happens here because
    /// `CGImage` values are not carried across the turn's concurrency boundaries.
    nonisolated static func prompt(
        text: String,
        attachments: [ComposerImageAttachment]
    ) -> Prompt {
        let images = attachments.compactMap { attachment -> CGImage? in
            guard let source = CGImageSourceCreateWithData(
                attachment.modelJPEGData as CFData,
                nil
            ) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return Prompt {
            text
            for image in images {
                Attachment(image)
            }
        }
    }
}

// MARK: - ModelVisionSupport

/// Answers whether the active model can receive images right now.
nonisolated enum ModelVisionSupport {
    /// Only the two backends this feature was validated on accept images.
    /// Cowork has a fixed VM tool plan and is excluded with its own focused rule.
    /// An unset `supportsVision` falls back to asking llama-server, because the
    /// model behind one configured endpoint can change between launches.
    static func resolve(
        backend: ModelBackend,
        isCowork: Bool,
        remoteModel: RemoteModelConfig?,
        systemModelSupportsVision: @Sendable () -> Bool,
        probeServer: @Sendable (String) async -> Bool
    ) async -> Bool {
        guard !isCowork else { return false }
        switch backend {
        case .foundationApple:
            return systemModelSupportsVision()
        case .llamaServer:
            guard let remoteModel else { return false }
            if let declared = remoteModel.supportsVision { return declared }
            return await probeServer(remoteModel.url)
        default:
            return false
        }
    }

    static func systemModelSupportsVision() -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.capabilities.contains(.vision)
    }
}
