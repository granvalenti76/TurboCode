import Foundation

/// The exact guest TurboCode installs for Cowork, pinned in source.
///
/// Values come from a `TurboCode-Cowork-Image` release `manifest.json`, but
/// TurboCode never trusts a manifest at runtime: changing the guest always
/// requires a reviewed source change here. Every reference is content-addressed
/// (OCI digest or SHA-256), so a pinned descriptor always means the same bytes.
nonisolated struct CoworkImageDescriptor: Sendable, Equatable {
    /// Release of `granvalenti76/TurboCode-Cowork-Image` the pins come from.
    let version: String
    /// Guest root filesystem, an OCI image referenced by digest.
    let imageReference: String
    /// Guest kernel published as a release asset (GPL source ships next to it).
    let kernelURL: URL
    let kernelSHA256: String
    let kernelSizeBytes: Int64
    let kernelVersion: String
    /// Containerization init filesystem; must match the linked package version.
    let initReference: String
    let containerizationVersion: String

    static let current = Self(
        version: "0.62.0-rc.1",
        imageReference: "ghcr.io/granvalenti76/turbocode-cowork-image@sha256:d8bc5c895aea414201b41ffd48759fea8c44745cea94d6fe2e421b0042d3d35d",
        kernelURL: URL(string: "https://github.com/granvalenti76/TurboCode-Cowork-Image/releases/download/v0.62.0-rc.1/vmlinux-arm64")!,
        kernelSHA256: "e572c4e1fbaf7053fb79b49d2ff1601617c264639dfada96f28ef5d44d516647",
        kernelSizeBytes: 29_354_496,
        kernelVersion: "6.18.5",
        initReference: "ghcr.io/apple/containerization/vminit@sha256:91d814732cd59fa993b50ad0925685ee1766fca436d75077a6bcbb79c21222c0",
        containerizationVersion: "0.49.0"
    )

    /// Short, filesystem-safe identity of the pinned image. Derived artifacts
    /// such as the unpacked base rootfs are keyed by it, so an image upgrade can
    /// never silently reuse a root filesystem unpacked from an older image.
    var imageDigestPrefix: String {
        let digest = imageReference.split(separator: "@").last.map(String.init) ?? imageReference
        return String(digest.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }
}
