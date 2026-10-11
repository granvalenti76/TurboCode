import Foundation

// MARK: - Plan

/// Identity of a file at review time. Export copies an item only while both
/// its source and its destination still match what the user reviewed.
nonisolated struct CoworkFileFingerprint: Sendable, Equatable {
    let size: Int64
    let modificationDate: Date?
    let sha256: String

    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Self(
            size: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            sha256: try FileDigest.sha256(at: url)
        )
    }
}

nonisolated struct CoworkExportItem: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Nothing exists at the destination path.
        case new
        /// A different file exists at the destination path.
        case conflict(CoworkFileFingerprint)
        /// The destination already holds the same bytes.
        case identical
    }

    let relativePath: String
    let source: URL
    let destination: URL
    let size: Int64
    let kind: Kind
    let sourceFingerprint: CoworkFileFingerprint
    /// Whether both sides can be shown as a text diff.
    let isText: Bool

    var id: String { relativePath }
}

nonisolated struct CoworkExportSkip: Identifiable, Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case excluded
        case symbolicLink
        case notRegularFile
        case unsafeDestination
        case destinationIsDirectory
    }

    let relativePath: String
    let reason: Reason

    var id: String { relativePath }

    var explanation: String {
        switch reason {
        case .excluded: "excluded by default"
        case .symbolicLink: "symbolic links are never exported"
        case .notRegularFile: "not a regular file"
        case .unsafeDestination: "its destination would leave the chosen folder"
        case .destinationIsDirectory: "a folder with this name exists at the destination"
        }
    }
}

nonisolated struct CoworkExportPlan: Sendable, Equatable {
    static let maximumFiles = 2_000
    static let maximumBytes: Int64 = 500 * 1_024 * 1_024

    let outbox: URL
    let destination: URL
    let items: [CoworkExportItem]
    let skipped: [CoworkExportSkip]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    /// Large exports need an explicit confirmation in the review sheet.
    var exceedsLimits: Bool { items.count > Self.maximumFiles || totalBytes > Self.maximumBytes }
}

/// Reads a session outbox and describes what an export would do. Pure file
/// inspection: it never writes, and it never follows a symbolic link.
nonisolated enum CoworkExportPlanner {
    /// Build and environment folders the agent may leave behind; their
    /// contents are platform-specific (Linux binaries) or repository state.
    static let excludedNames: Set<String> = [
        "node_modules", ".venv", "venv", ".git", "__pycache__", ".DS_Store", ".pytest_cache",
    ]

    static func plan(outbox: URL, destination: URL) throws -> CoworkExportPlan {
        let fileManager = FileManager.default
        let outboxRoot = outbox.standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = destination.standardizedFileURL.resolvingSymlinksInPath()
        var items: [CoworkExportItem] = []
        var skipped: [CoworkExportSkip] = []

        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        // The enumerator does not descend into symbolic links; each one is
        // reported and skipped explicitly below.
        guard let enumerator = fileManager.enumerator(at: outboxRoot, includingPropertiesForKeys: keys) else {
            return CoworkExportPlan(outbox: outboxRoot, destination: destinationRoot, items: [], skipped: [])
        }
        for case let url as URL in enumerator {
            let relative = relativePath(of: url, in: outboxRoot)
            let values = try url.resourceValues(forKeys: Set(keys))
            if excludedNames.contains(url.lastPathComponent) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                skipped.append(.init(relativePath: relative, reason: .excluded))
                continue
            }
            if values.isSymbolicLink == true {
                skipped.append(.init(relativePath: relative, reason: .symbolicLink))
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                skipped.append(.init(relativePath: relative, reason: .notRegularFile))
                continue
            }

            let target = destinationRoot.appendingPathComponent(relative)
            // A symbolic link inside the destination must not redirect the copy
            // outside the folder the user chose.
            let resolvedParent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard resolvedParent == destinationRoot.path || resolvedParent.hasPrefix(destinationRoot.path + "/") else {
                skipped.append(.init(relativePath: relative, reason: .unsafeDestination))
                continue
            }

            let sourceFingerprint = try CoworkFileFingerprint.read(url)
            let kind: CoworkExportItem.Kind
            var isText = false
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    skipped.append(.init(relativePath: relative, reason: .destinationIsDirectory))
                    continue
                }
                let existing = try CoworkFileFingerprint.read(target)
                kind = existing.sha256 == sourceFingerprint.sha256 ? .identical : .conflict(existing)
                if case .conflict = kind {
                    isText = isReviewableText(url) && isReviewableText(target)
                }
            } else {
                kind = .new
                isText = isReviewableText(url)
            }
            items.append(CoworkExportItem(
                relativePath: relative,
                source: url,
                destination: target,
                size: sourceFingerprint.size,
                kind: kind,
                sourceFingerprint: sourceFingerprint,
                isText: isText
            ))
        }
        return CoworkExportPlan(
            outbox: outboxRoot,
            destination: destinationRoot,
            items: items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            skipped: skipped.sorted { $0.relativePath < $1.relativePath }
        )
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    private static func isReviewableText(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return UnifiedTextDiff.reviewableText(data) != nil
    }
}

// MARK: - Decisions and report

nonisolated enum CoworkExportDecision: String, Sendable, Equatable, CaseIterable {
    case skip
    case copy
    case replace
    case keepBoth

    /// New files are copied; conflicts and identical files are skipped until
    /// the user chooses otherwise. Nothing is overwritten by default.
    static func `default`(for item: CoworkExportItem) -> Self {
        if case .new = item.kind { return .copy }
        return .skip
    }
}

nonisolated struct CoworkExportReport: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case copied(to: String)
        case skipped
        case changedSinceReview
        case failed(String)
    }

    var outcomes: [(path: String, outcome: Outcome)] = []

    var copiedCount: Int { outcomes.filter { if case .copied = $0.outcome { true } else { false } }.count }
    var changedCount: Int { outcomes.filter { $0.outcome == .changedSinceReview }.count }
    var failedCount: Int { outcomes.filter { if case .failed = $0.outcome { true } else { false } }.count }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.outcomes.map(\.path) == rhs.outcomes.map(\.path)
            && lhs.outcomes.map(\.outcome) == rhs.outcomes.map(\.outcome)
    }
}

// MARK: - Service

/// Copies approved deliverables from a session outbox to a Mac folder.
///
/// Every file is re-verified against the reviewed plan immediately before it
/// is copied, staged next to its destination, stripped of execute permission,
/// marked with the macOS quarantine attribute (so Gatekeeper treats it like a
/// download), and moved into place. A changed source or destination is
/// skipped and reported, never overwritten.
actor CoworkExportService {
    static let quarantineAttribute = "com.apple.quarantine"

    func export(
        plan: CoworkExportPlan,
        decisions: [String: CoworkExportDecision]
    ) async -> CoworkExportReport {
        var report = CoworkExportReport()
        let fileManager = FileManager.default
        let staging = plan.destination.appendingPathComponent(
            ".turbocode-export-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        for item in plan.items {
            let decision = decisions[item.id] ?? CoworkExportDecision.default(for: item)
            guard decision != .skip, !Task.isCancelled else {
                report.outcomes.append((item.relativePath, .skipped))
                continue
            }
            do {
                let outcome = try copy(item, decision: decision, staging: staging, root: plan.destination)
                report.outcomes.append((item.relativePath, outcome))
            } catch {
                report.outcomes.append((item.relativePath, .failed(error.localizedDescription)))
            }
        }
        return report
    }

    private func copy(
        _ item: CoworkExportItem,
        decision: CoworkExportDecision,
        staging: URL,
        root: URL
    ) throws -> CoworkExportReport.Outcome {
        let fileManager = FileManager.default
        // The VM may still be writing to the outbox while the sheet is open.
        guard (try? CoworkFileFingerprint.read(item.source)) == item.sourceFingerprint else {
            return .changedSinceReview
        }

        let target: URL
        switch (decision, item.kind) {
        case (.replace, .conflict(let reviewed)):
            guard (try? CoworkFileFingerprint.read(item.destination)) == reviewed else {
                return .changedSinceReview
            }
            target = item.destination
        case (.keepBoth, _):
            target = Self.availableURL(near: item.destination)
        case (.copy, .new):
            guard !fileManager.fileExists(atPath: item.destination.path) else { return .changedSinceReview }
            target = item.destination
        default:
            return .skipped
        }

        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let resolvedParent = parent.resolvingSymlinksInPath().path
        guard resolvedParent == root.path || resolvedParent.hasPrefix(root.path + "/") else {
            return .failed("The destination would leave the chosen folder.")
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(UUID().uuidString)
        try fileManager.copyItem(at: item.source, to: staged)
        try Self.neutralize(staged)
        if decision == .replace {
            _ = try fileManager.replaceItemAt(target, withItemAt: staged)
        } else {
            // moveItem fails instead of overwriting if something appeared.
            try fileManager.moveItem(at: staged, to: target)
        }
        return .copied(to: target.path)
    }

    /// Files from the VM are never executable on arrival and carry the
    /// quarantine attribute, so opening them goes through Gatekeeper.
    static func neutralize(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions & ~0o111)],
            ofItemAtPath: url.path
        )
        let value = String(format: "0081;%08x;TurboCode Cowork;", Int(Date().timeIntervalSince1970))
        let result = value.withCString { pointer in
            setxattr(url.path, quarantineAttribute, pointer, strlen(pointer), 0, 0)
        }
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// "name 2.ext", "name 3.ext", … the Finder convention for keeping both.
    static func availableURL(near url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
