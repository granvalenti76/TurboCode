import CryptoKit
import Foundation

/// Streaming file digests for pinned downloads (AnchorSignal model files,
/// the Cowork kernel). Files are read in 1 MiB chunks so multi-gigabyte assets
/// never have to fit in memory.
nonisolated enum FileDigest {
    /// Lowercase hexadecimal SHA-256, the format used by release manifests and
    /// `shasum -a 256`.
    static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hexadecimal SHA-256 of bytes already in memory, matching
    /// `sha256sum` output so a digest computed in the Studio VM compares
    /// equal to one computed here.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
