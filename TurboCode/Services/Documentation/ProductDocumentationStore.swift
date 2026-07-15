import Foundation

nonisolated struct ProductDocumentationManifest: Codable, Sendable {
    let version: String
    let documents: [ProductDocumentationDescriptor]
}

nonisolated struct ProductDocumentationDescriptor: Codable, Sendable {
    let id: String
    let title: String
    let summary: String
    let file: String
    let keywords: [String]
}

nonisolated struct ProductDocumentationDocument: Sendable {
    let descriptor: ProductDocumentationDescriptor
    let content: String
}

nonisolated struct ProductDocumentationSearchResult: Sendable {
    let version: String
    let documents: [ProductDocumentationDocument]
}

nonisolated enum ProductDocumentationError: LocalizedError {
    case bundledManifestMissing
    case installedManifestMissing
    case documentMissing(String)

    var errorDescription: String? {
        switch self {
        case .bundledManifestMissing:
            "Bundled TurboCode documentation manifest is missing."
        case .installedManifestMissing:
            "TurboCode documentation is not installed."
        case .documentMissing(let file):
            "TurboCode documentation file is missing: \(file)"
        }
    }
}

/// Installs and searches the official, versioned product documentation. The
/// store knows nothing about model tools or SwiftUI presentation.
nonisolated struct ProductDocumentationStore: Sendable {
    @MainActor
    static var live: ProductDocumentationStore {
        ProductDocumentationStore(
            officialDirectoryURL: TurboCodeConfig.shared.officialDocumentationDirectoryURL,
            bundleResourceURL: Bundle.main.resourceURL
        )
    }

    private let officialDirectoryURL: URL
    private let bundleResourceURL: URL?
    private let manifestFilename = "turbocode-documentation-manifest.json"

    init(officialDirectoryURL: URL, bundleResourceURL: URL?) {
        self.officialDirectoryURL = officialDirectoryURL
        self.bundleResourceURL = bundleResourceURL
    }

    func installBundledDocumentation() throws {
        guard let bundledManifestURL = bundledResourceURL(for: manifestFilename) else {
            throw ProductDocumentationError.bundledManifestMissing
        }
        let manifestData = try Data(contentsOf: bundledManifestURL)
        let manifest = try JSONDecoder().decode(ProductDocumentationManifest.self, from: manifestData)
        let installedManifestURL = officialDirectoryURL.appendingPathComponent(manifestFilename)

        if let currentData = try? Data(contentsOf: installedManifestURL),
           let current = try? JSONDecoder().decode(ProductDocumentationManifest.self, from: currentData),
           current.version == manifest.version,
           manifest.documents.allSatisfy({
               FileManager.default.fileExists(
                   atPath: officialDirectoryURL.appendingPathComponent($0.file).path
               )
           }) {
            return
        }

        try FileManager.default.createDirectory(
            at: officialDirectoryURL,
            withIntermediateDirectories: true
        )
        for document in manifest.documents {
            guard let sourceURL = bundledResourceURL(for: document.file) else {
                throw ProductDocumentationError.documentMissing(document.file)
            }
            let data = try Data(contentsOf: sourceURL)
            try data.write(
                to: officialDirectoryURL.appendingPathComponent(document.file),
                options: .atomic
            )
        }
        try manifestData.write(to: installedManifestURL, options: .atomic)
    }

    func search(_ query: String, limit: Int = 3) throws -> ProductDocumentationSearchResult {
        let manifestURL = officialDirectoryURL.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ProductDocumentationError.installedManifestMissing
        }
        let manifest = try JSONDecoder().decode(
            ProductDocumentationManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let queryTokens = tokens(in: query)
        let ranked = manifest.documents
            .map { descriptor in
                (descriptor, score(descriptor, queryTokens: queryTokens))
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.id < $1.0.id
            }

        let selectedDescriptors: [ProductDocumentationDescriptor]
        if ranked.isEmpty {
            selectedDescriptors = Array(
                manifest.documents.filter { $0.id == "capabilities" }.prefix(1)
            )
        } else {
            selectedDescriptors = ranked
                .prefix(max(1, min(limit, 3)))
                .map(\.0)
        }
        let documents = try selectedDescriptors.map { descriptor in
            let url = officialDirectoryURL.appendingPathComponent(descriptor.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProductDocumentationError.documentMissing(descriptor.file)
            }
            return ProductDocumentationDocument(
                descriptor: descriptor,
                content: try String(contentsOf: url, encoding: .utf8)
            )
        }
        return ProductDocumentationSearchResult(version: manifest.version, documents: documents)
    }

    private func bundledResourceURL(for filename: String) -> URL? {
        guard let bundleResourceURL else { return nil }
        let nested = bundleResourceURL
            .appendingPathComponent("Documentation", isDirectory: true)
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        let flat = bundleResourceURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: flat.path) ? flat : nil
    }

    private func score(
        _ descriptor: ProductDocumentationDescriptor,
        queryTokens: Set<String>
    ) -> Int {
        guard !queryTokens.isEmpty else { return descriptor.id == "capabilities" ? 1 : 0 }
        let idTokens = tokens(in: descriptor.id)
        let titleTokens = tokens(in: descriptor.title)
        let summaryTokens = tokens(in: descriptor.summary)
        let keywordTokens = tokens(in: descriptor.keywords.joined(separator: " "))
        return queryTokens.reduce(into: 0) { total, token in
            if idTokens.contains(token) { total += 8 }
            if titleTokens.contains(token) { total += 6 }
            if keywordTokens.contains(token) { total += 4 }
            if summaryTokens.contains(token) { total += 2 }
        }
    }

    private func tokens(in text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }
}
