import Foundation

/// Finds Xcode containers without interpreting build settings or invoking a shell.
nonisolated struct XcodeProjectDiscoveryService: Sendable {
    let workspaceRoot: String

    func resolveContainer(path: String?) throws -> XcodeContainer {
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return try container(at: path)
        }

        let root = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        let candidates = discoverContainers(in: root)
        guard let selected = candidates.sorted(by: preferredContainer).first else {
            throw XcodeProjectError.noContainer
        }
        return selected
    }

    private func container(at path: String) throws -> XcodeContainer {
        let url = try WorkspacePathResolver.resolve(path, within: workspaceRoot)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let kind = kind(for: url) else {
            throw XcodeProjectError.invalidContainer(path)
        }
        return XcodeContainer(relativePath: relativePath(for: url), url: url, kind: kind)
    }

    private func discoverContainers(in root: URL) -> [XcodeContainer] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var containers: [XcodeContainer] = []
        for case let url as URL in enumerator {
            let relative = relativePath(for: url)
            let depth = relative.split(separator: "/").count
            if shouldSkip(url: url, relativePath: relative, depth: depth) {
                enumerator.skipDescendants()
                continue
            }
            guard let kind = kind(for: url) else { continue }
            containers.append(XcodeContainer(relativePath: relative, url: url, kind: kind))
            enumerator.skipDescendants()
        }
        return containers
    }

    private func shouldSkip(url: URL, relativePath: String, depth: Int) -> Bool {
        if depth > 3 { return true }
        let excluded = Set([
            ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
            "SourcePackages", "node_modules", "xcuserdata"
        ])
        return relativePath.split(separator: "/").contains { excluded.contains(String($0)) }
            || url.pathExtension == "xcodeproj" && url.lastPathComponent == "project.xcworkspace"
    }

    private func kind(for url: URL) -> XcodeContainerKind? {
        switch url.pathExtension.lowercased() {
        case "xcworkspace": .workspace
        case "xcodeproj": .project
        default: nil
        }
    }

    private func relativePath(for url: URL) -> String {
        let root = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path != root.path else { return "." }
        return String(resolved.path.dropFirst(root.path.count + 1))
    }

    private func preferredContainer(_ lhs: XcodeContainer, _ rhs: XcodeContainer) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .workspace }
        let lhsDepth = lhs.relativePath.split(separator: "/").count
        let rhsDepth = rhs.relativePath.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}
