import Foundation
import FoundationModels

@Generable
struct VMViewImageArguments {
    /// Guest path of a PNG, JPEG, GIF, or WebP file. Relative paths start at the session directory.
    var path: String
}

/// The raster formats `vm_view_image` hands to the Mac's image decoder.
///
/// The bytes come from the guest, which may have downloaded them from anywhere,
/// so the format is recognized from its signature before ImageIO sees the data.
/// Keeping the list short keeps the host decoder away from the rarer formats
/// ImageIO also understands.
nonisolated enum CoworkImageFormat: String, Sendable, CaseIterable {
    case png, jpeg, gif, webP

    init?(signatureOf data: Data) {
        let bytes = [UInt8](data.prefix(12))
        func starts(with signature: [UInt8]) -> Bool {
            bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature
        }
        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if starts(with: Array("GIF87a".utf8)) || starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else if starts(with: Array("RIFF".utf8)), bytes.count == 12,
                  Array(bytes[8...]) == Array("WEBP".utf8) {
            self = .webP
        } else {
            return nil
        }
    }
}

/// Shows the model an image that exists only inside the Cowork VM, such as a
/// Chromium screenshot or a downloaded picture.
///
/// The image travels from the guest to the model and nowhere else: it is not
/// written to the Mac's disk, does not reach the workspace, and does not replace
/// the approval-gated export. Like every Cowork tool it reads the guest only
/// through `CoworkSessionContext`.
struct VMViewImageTool: Tool {
    typealias Arguments = VMViewImageArguments
    typealias Output = Prompt

    /// Screenshots and web images are far smaller; the cap bounds what one call
    /// can pull out of the guest into the app's memory.
    static let maximumSourceBytes = 10 * 1_024 * 1_024

    /// What one call produced, kept separate from `Prompt` so the decision can
    /// be tested without inspecting an opaque prompt value.
    enum Outcome: Sendable, Equatable {
        case image(text: String, attachment: ComposerImageAttachment)
        case message(String)
    }

    let context: CoworkSessionContext
    /// Asked on every call rather than once per session: vision is known only
    /// from an asynchronous probe, and the local server can restart with another
    /// model while the session stays open. A server without vision rejects any
    /// request that contains an image, so the image must never be returned to it.
    let supportsVision: @Sendable () async -> Bool

    var name: String { ToolCapabilityID.vmViewImage.rawValue }
    var description: String {
        """
        Look at an image file in the isolated Cowork VM (PNG, JPEG, GIF, WebP), \
        for example a Chromium screenshot or a downloaded picture. Create or \
        download the file with vm_exec first, then pass its path. Each viewed \
        image stays in the conversation, so view only what you need.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: VMViewImageArguments) async throws -> Prompt {
        switch await view(arguments: arguments) {
        case .image(let text, let attachment):
            ComposerImageAttachment.prompt(text: text, attachments: [attachment])
        case .message(let text):
            Prompt(text)
        }
    }

    func view(arguments: VMViewImageArguments) async -> Outcome {
        // Checked before the VM is touched, so a model without vision costs no
        // boot and no transfer.
        guard await supportsVision() else {
            return .message("The active model cannot see images. Inspect the file with vm_exec instead.")
        }
        let path = context.guestPath(arguments.path)
        let data: Data
        do {
            // One byte over the limit is enough to detect an oversized file
            // without transferring it, and `head` also bounds a file that grows
            // while it is read. The path is single-quoted and nothing but the
            // file's bytes is written to standard output.
            let result = try await context.run("""
                test -f \(CoworkShell.quote(path)) || exit 2
                head -c \(Self.maximumSourceBytes + 1) -- \(CoworkShell.quote(path))
                """)
            switch result.exitCode {
            case 0: data = result.stdout
            case 2: return .message("Not a file: \(path)")
            default:
                // Whatever reached standard output is partial binary data, so
                // only the status and the error stream are worth reporting.
                var failure = result
                failure.stdout = Data()
                return .message(CoworkOutputFormatter.render(failure))
            }
        } catch {
            // Expected VM states are reported as text so the model can explain
            // them instead of retrying blindly.
            return .message("The image was not read: \(error.localizedDescription)")
        }

        guard data.count <= Self.maximumSourceBytes else {
            return .message("\(path) is larger than \(Self.maximumSourceBytes / 1_048_576) MB. Resize or convert it with vm_exec first.")
        }
        guard CoworkImageFormat(signatureOf: data) != nil else {
            return .message("\(path) is not a PNG, JPEG, GIF, or WebP image. Convert it with vm_exec first.")
        }
        do {
            let attachment = try ComposerImageLoader.load(
                data: data,
                fileName: (path as NSString).lastPathComponent,
                maxSourceByteCount: Self.maximumSourceBytes
            )
            return .image(text: "Image \(path):", attachment: attachment)
        } catch {
            return .message("\(path) could not be decoded as an image.")
        }
    }
}
