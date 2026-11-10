import Foundation

/// One file in a Cowork session's outbox, as the Artifacts inspector shows it.
///
/// An artifact is not a new kind of storage: it is a deliverable the agent put
/// in `/out`, which is a folder on the Mac. Showing it reads that folder only;
/// it copies nothing into the user's folders and is not an export.
nonisolated struct CoworkArtifact: Identifiable, Sendable, Hashable {
    /// How the inspector can present the file. Decided from the extension:
    /// the preview is a convenience, so a wrong guess only shows a poorer view.
    enum Kind: String, Sendable, Hashable {
        case webPage, image, pdf, text, other
    }

    /// Path inside the outbox, with "/" separators.
    let relativePath: String
    let size: Int64

    var id: String { relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }
    var kind: Kind { Self.kind(forPath: relativePath) }

    static func kind(forPath path: String) -> Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm":
            .webPage
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg":
            .image
        case "pdf":
            .pdf
        case "md", "txt", "json", "csv", "tsv", "log", "xml", "yml", "yaml", "toml",
             "js", "mjs", "ts", "tsx", "jsx", "css", "scss", "py", "sh", "rb", "go",
             "rs", "c", "h", "cpp", "java", "swift", "sql", "ini", "env":
            .text
        default:
            .other
        }
    }
}

/// Lists and resolves the artifacts of one session outbox.
nonisolated enum CoworkArtifactCatalog {
    /// Same files, exclusions, and link rules as the export review, so the
    /// inspector never shows something the user could not also export.
    static func artifacts(in outbox: URL) -> [CoworkArtifact] {
        CoworkExportPlanner.deliverables(in: outbox).map {
            CoworkArtifact(relativePath: $0.path, size: $0.size)
        }
    }

    /// The artifact to show when the user has not chosen one: the page a web
    /// deliverable starts from, then anything else that has a real preview.
    static func preferred(in artifacts: [CoworkArtifact]) -> CoworkArtifact? {
        func depth(_ artifact: CoworkArtifact) -> Int {
            artifact.relativePath.split(separator: "/").count
        }
        let pages = artifacts.filter { $0.kind == .webPage }
        let entry = pages
            .filter { $0.name.lowercased() == "index.html" }
            .min { depth($0) < depth($1) }
        return entry
            ?? pages.min { depth($0) < depth($1) }
            ?? artifacts.first { $0.kind != .other }
            ?? artifacts.first
    }

    /// List order for the inspector: what can be looked at first (pages, then
    /// images, PDFs, text), other files last, each group by path. Mixed
    /// alphabetical order would bury a session's page under its assets.
    static func displayOrdered(_ artifacts: [CoworkArtifact]) -> [CoworkArtifact] {
        func rank(_ kind: CoworkArtifact.Kind) -> Int {
            switch kind {
            case .webPage: 0
            case .image: 1
            case .pdf: 2
            case .text: 3
            case .other: 4
            }
        }
        return artifacts.sorted {
            let (left, right) = (rank($0.kind), rank($1.kind))
            if left != right { return left < right }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    /// Which artifact the inspector shows after a reload.
    ///
    /// A file that appeared since the previous reload wins, so the preview
    /// follows the agent's latest work without the user hunting for it.
    /// Otherwise the user's choice is kept while it still exists, and the
    /// session's entry page is the fallback. `previous` is `nil` on the first
    /// load of a session, when nothing counts as new.
    static func selection(
        current: CoworkArtifact.ID?,
        previous: [CoworkArtifact]?,
        updated: [CoworkArtifact]
    ) -> CoworkArtifact? {
        if let previous {
            let known = Set(previous.map(\.id))
            let added = updated.filter { !known.contains($0.id) && $0.kind != .other }
            if let newest = preferred(in: added) { return newest }
        }
        return updated.first { $0.id == current } ?? preferred(in: updated)
    }

    /// The file on the Mac behind an artifact, or `nil` when the path would
    /// leave the outbox. The listing never produces such a path; the check
    /// keeps a stale or hand-built value from reading elsewhere.
    static func fileURL(for artifact: CoworkArtifact, in outbox: URL) -> URL? {
        let root = outbox.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(artifact.relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }
}

/// One Cowork session's artifacts as the library shows them: a titled group
/// that leads back to the session that made the files.
nonisolated struct CoworkArtifactGroup: Identifiable, Sendable, Equatable {
    let sessionID: String
    let sessionTitle: String
    let updatedAt: Date
    let outbox: URL
    let artifacts: [CoworkArtifact]

    var id: String { sessionID }

    /// The file that stands for the session in the library: the same entry
    /// the inspector opens first, so a web deliverable is shown by its page
    /// and not by its stylesheet, script, or icons.
    var primary: CoworkArtifact? { CoworkArtifactCatalog.preferred(in: artifacts) }

    /// Every file of the session in the order the library lets the user step
    /// through them: the primary first, then the inspector's display order.
    /// The library shows one card per session, so this list is what keeps the
    /// other files reachable.
    var browsingOrder: [CoworkArtifact] {
        guard let primary else { return [] }
        return [primary] + CoworkArtifactCatalog.displayOrdered(artifacts).filter { $0 != primary }
    }
}

/// The artifacts of the active Cowork session together with the folder they
/// live in, which previews need to resolve files and sibling resources.
nonisolated struct CoworkArtifactListing: Sendable, Equatable {
    let outbox: URL
    let artifacts: [CoworkArtifact]
}
