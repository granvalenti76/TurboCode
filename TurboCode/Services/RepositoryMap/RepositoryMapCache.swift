import CryptoKit
import Foundation

nonisolated struct RepositoryMapSourceFile: Sendable {
    let url: URL
    let relativePath: String
    let fingerprint: RepositoryFileFingerprint
}

/// Owns discovery, incremental rescanning and the privacy-safe on-disk cache.
/// Cached entries contain declarations and paths, never source bodies.
actor RepositoryMapCache {
    static let shared = RepositoryMapCache()

    private let formatVersion = 1
    private var memory: [String: RepositoryMapSnapshot] = [:]

    func snapshot(
        workspaceRoot: String,
        detail: RepositoryMapDetail,
        forceRefresh: Bool = false
    ) throws -> RepositoryMapSnapshot {
        let root = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        let sources = discoverSources(root: root)
        let cacheKey = "\(root.path)|\(detail.rawValue)"
        var previous = forceRefresh ? nil : memory[cacheKey]
        if previous == nil, !forceRefresh {
            previous = try? loadSnapshot(root: root, detail: detail)
        }

        let previousFiles = Dictionary(
            uniqueKeysWithValues: (previous?.files ?? []).map { ($0.path, $0) }
        )
        let scanner = SwiftDeclarationScanner()
        var files: [RepositoryFileMap] = []
        files.reserveCapacity(sources.files.count)
        for source in sources.files {
            if let cached = previousFiles[source.relativePath],
               cached.fingerprint == source.fingerprint {
                files.append(cached)
                continue
            }
            guard let contents = try? String(contentsOf: source.url, encoding: .utf8) else {
                continue
            }
            files.append(
                scanner.scan(
                    source: contents,
                    relativePath: source.relativePath,
                    fingerprint: source.fingerprint,
                    detail: detail
                )
            )
        }

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let snapshot = RepositoryMapSnapshot(
            formatVersion: formatVersion,
            workspacePath: root.path,
            revision: revision(for: files),
            generatedAt: .now,
            projectMarkers: discoverProjectMarkers(root: root),
            files: files,
            wasTruncated: sources.wasTruncated
        )
        memory[cacheKey] = snapshot
        try? save(snapshot, root: root, detail: detail)
        return snapshot
    }

    private func discoverSources(
        root: URL,
        maximumFiles: Int = 2_500,
        maximumFileSize: Int = 1_500_000
    ) -> (files: [RepositoryMapSourceFile], wasTruncated: Bool) {
        let excludedDirectories: Set<String> = [
            ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
            "SourcePackages", "xcuserdata", "node_modules"
        ]
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return ([], false) }

        var files: [RepositoryMapSourceFile] = []
        var wasTruncated = false
        let allowedPrefix = root.path + "/"
        while let candidate = enumerator.nextObject() as? URL {
            guard let values = try? candidate.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true,
               excludedDirectories.contains(candidate.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  candidate.pathExtension.lowercased() == "swift",
                  (values.fileSize ?? 0) <= maximumFileSize else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(allowedPrefix) else { continue }
            guard files.count < maximumFiles else {
                wasTruncated = true
                break
            }
            files.append(
                RepositoryMapSourceFile(
                    url: resolved,
                    relativePath: String(resolved.path.dropFirst(allowedPrefix.count)),
                    fingerprint: RepositoryFileFingerprint(
                        size: values.fileSize ?? 0,
                        modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    )
                )
            )
        }
        return (files, wasTruncated)
    }

    private func discoverProjectMarkers(root: URL) -> [RepositoryProjectMarker] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let allowedPrefix = root.path + "/"
        var markers: [RepositoryProjectMarker] = []
        while let candidate = enumerator.nextObject() as? URL, markers.count < 30 {
            let name = candidate.lastPathComponent
            let kind: String?
            if name == "Package.swift" {
                kind = "Swift package"
            } else if candidate.pathExtension == "xcworkspace" {
                kind = "Xcode workspace"
                enumerator.skipDescendants()
            } else if candidate.pathExtension == "xcodeproj" {
                kind = "Xcode project"
                enumerator.skipDescendants()
            } else {
                kind = nil
            }
            if let kind {
                markers.append(
                    RepositoryProjectMarker(
                        kind: kind,
                        path: candidate.path.hasPrefix(allowedPrefix)
                            ? String(candidate.path.dropFirst(allowedPrefix.count))
                            : candidate.lastPathComponent
                    )
                )
            }
        }
        return markers.sorted { $0.path < $1.path }
    }

    private func revision(for files: [RepositoryFileMap]) -> String {
        let source = files.map {
            "\($0.path):\($0.fingerprint.size):\($0.fingerprint.modifiedAt)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(root: URL, detail: RepositoryMapDetail) -> URL {
        let digest = SHA256.hash(data: Data(root.path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectoryURL
            .appendingPathComponent("\(digest)-\(detail.rawValue).json")
    }

    private func loadSnapshot(
        root: URL,
        detail: RepositoryMapDetail
    ) throws -> RepositoryMapSnapshot {
        let data = try Data(contentsOf: cacheURL(root: root, detail: detail))
        let value = try JSONDecoder().decode(RepositoryMapSnapshot.self, from: data)
        guard value.formatVersion == formatVersion, value.workspacePath == root.path else {
            throw RepositoryMapCacheError.incompatible
        }
        return value
    }

    private func save(
        _ snapshot: RepositoryMapSnapshot,
        root: URL,
        detail: RepositoryMapDetail
    ) throws {
        let directory = cacheDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(
            to: cacheURL(root: root, detail: detail),
            options: .atomic
        )
    }

    private var cacheDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/cache/repository-maps", isDirectory: true)
    }
}

private nonisolated enum RepositoryMapCacheError: Error {
    case incompatible
}
