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
        version: "0.62.0",
        imageReference: "ghcr.io/granvalenti76/turbocode-cowork-image@sha256:03fa97eceb696537a404fa65805a0fa6ecfd964c98058ef44e2b42aed37680de",
        kernelURL: URL(string: "https://github.com/granvalenti76/TurboCode-Cowork-Image/releases/download/v0.62.0/vmlinux-arm64")!,
        kernelSHA256: "1c063d31419cfe43d475fe954c352b128e14ccaba65caa8f1f351bc2a42052a0",
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
