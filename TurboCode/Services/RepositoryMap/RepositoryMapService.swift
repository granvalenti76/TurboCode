import Foundation

nonisolated enum RepositoryMapAction: String, Sendable {
    case overview
    case symbols
    case related
    case refresh
}

nonisolated enum RepositoryMapServiceError: LocalizedError {
    case unsupportedAction(String)
    case queryRequired(String)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let action):
            "Unsupported workspace map action '\(action)'. Use overview, symbols, related, or refresh."
        case .queryRequired(let action):
            "The \(action) action requires a symbol, type, file, or directory query."
        case .invalidPath(let path):
            "The workspace map path must stay inside the active workspace: \(path)"
        }
    }
}

struct RepositoryMapService: Sendable {
    let workspaceRoot: String
    let detail: RepositoryMapDetail
    let outputCharacterBudget: Int

    func response(action rawAction: String, query: String?, path: String?) async throws -> String {
        guard let action = RepositoryMapAction(rawValue: rawAction) else {
            throw RepositoryMapServiceError.unsupportedAction(rawAction)
        }
        let snapshot = try await RepositoryMapCache.shared.snapshot(
            workspaceRoot: workspaceRoot,
            detail: detail,
            forceRefresh: action == .refresh
        )
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = try normalizedWorkspacePath(path)

        switch action {
        case .overview, .refresh:
            return renderOverview(snapshot, path: normalizedPath)
        case .symbols:
            guard let normalizedQuery, !normalizedQuery.isEmpty else {
                throw RepositoryMapServiceError.queryRequired(action.rawValue)
            }
            return renderSymbols(snapshot, query: normalizedQuery, path: normalizedPath)
        case .related:
            guard let normalizedQuery, !normalizedQuery.isEmpty else {
                throw RepositoryMapServiceError.queryRequired(action.rawValue)
            }
            return renderRelated(snapshot, query: normalizedQuery)
        }
    }

    private func renderOverview(
        _ snapshot: RepositoryMapSnapshot,
        path: String?
    ) -> String {
        let files = scopedFiles(snapshot.files, path: path)
            .sorted {
                let lhs = relevance(of: $0)
                let rhs = relevance(of: $1)
                return lhs == rhs ? $0.path < $1.path : lhs > rhs
            }
        var output = header(snapshot, selectedFileCount: files.count)
        if !snapshot.projectMarkers.isEmpty {
            output += "\nPROJECTS\n"
            for marker in snapshot.projectMarkers {
                output += "- \(marker.kind): \(marker.path)\n"
            }
        }
        let areas = repositoryAreas(in: files)
        if !areas.isEmpty {
            output += "\nAREAS\n"
            for area in areas.prefix(24) {
                output += "- \(area.name): \(area.fileCount) files, \(area.symbolCount) declarations\n"
            }
        }
        output += "\nSWIFT SYMBOLS\n"
        appendFiles(
            files,
            to: &output,
            budget: outputCharacterBudget,
            maximumSymbolsPerFile: detail == .compact ? 18 : 36
        )
        return finalize(output, snapshot: snapshot)
    }

    private func renderSymbols(
        _ snapshot: RepositoryMapSnapshot,
        query: String,
        path: String?
    ) -> String {
        let needle = query.lowercased()
        let files = scopedFiles(snapshot.files, path: path).compactMap { file -> RepositoryFileMap? in
            let matches = file.symbols.filter { symbol in
                symbol.name.lowercased().contains(needle)
                    || symbol.signature.lowercased().contains(needle)
                    || symbol.documentation?.lowercased().contains(needle) == true
                    || symbol.parent?.lowercased().contains(needle) == true
            }
            guard !matches.isEmpty else { return nil }
            return RepositoryFileMap(
                path: file.path,
                fingerprint: file.fingerprint,
                imports: file.imports,
                symbols: matches
            )
        }
        var output = header(snapshot, selectedFileCount: files.count)
        output += "\nMATCHING SYMBOLS: \(query)\n"
        appendFiles(files, to: &output, budget: outputCharacterBudget)
        if files.isEmpty { output += "No matching Swift declarations.\n" }
        return finalize(output, snapshot: snapshot)
    }

    private func renderRelated(_ snapshot: RepositoryMapSnapshot, query: String) -> String {
        let needle = query.lowercased()
        let declarations = snapshot.files.flatMap(\.symbols).filter {
            $0.name.lowercased() == needle
        }
        let relatedNames = Set(declarations.flatMap(\.referencedTypes).map { $0.lowercased() })
            .union([needle])
        let files = snapshot.files.compactMap { file -> RepositoryFileMap? in
            let matches = file.symbols.filter { symbol in
                relatedNames.contains(symbol.name.lowercased())
                    || symbol.signature.lowercased().contains(needle)
                    || symbol.referencedTypes.contains(where: { $0.lowercased() == needle })
            }
            guard !matches.isEmpty else { return nil }
            return RepositoryFileMap(
                path: file.path,
                fingerprint: file.fingerprint,
                imports: file.imports,
                symbols: matches
            )
        }
        var output = header(snapshot, selectedFileCount: files.count)
        output += "\nRELATED DECLARATIONS: \(query)\n"
        appendFiles(files, to: &output, budget: outputCharacterBudget)
        if files.isEmpty { output += "No related declarations found. Try symbols with a broader query.\n" }
        return finalize(output, snapshot: snapshot)
    }

    private func appendFiles(
        _ files: [RepositoryFileMap],
        to output: inout String,
        budget: Int,
        maximumSymbolsPerFile: Int? = nil
    ) {
        for file in files {
            let fileHeader = "\n\(file.path)"
            guard output.count + fileHeader.count < budget else { break }
            output += fileHeader
            if detail == .enhanced, !file.imports.isEmpty {
                output += " [imports: \(file.imports.joined(separator: ", "))]"
            }
            output += "\n"
            let symbols = overviewSymbols(
                file.symbols,
                maximum: maximumSymbolsPerFile
            )
            for symbol in symbols {
                let indent = symbol.parent == nil ? "  " : "    "
                var line = "\(indent)L\(symbol.line) \(symbol.signature)"
                if detail == .enhanced, !symbol.referencedTypes.isEmpty {
                    line += "  → \(symbol.referencedTypes.joined(separator: ", "))"
                }
                line += "\n"
                if let documentation = symbol.documentation {
                    line += "\(indent)  /// \(documentation)\n"
                }
                guard output.count + line.count <= budget else {
                    output += "… output budget reached; refine with symbols or path.\n"
                    return
                }
                output += line
            }
            if symbols.count < file.symbols.count {
                output += "    … +\(file.symbols.count - symbols.count) declarations; refine with symbols or path.\n"
            }
        }
    }

    private func overviewSymbols(
        _ symbols: [RepositorySymbol],
        maximum: Int?
    ) -> [RepositorySymbol] {
        guard let maximum, symbols.count > maximum else { return symbols }
        return symbols.sorted { lhs, rhs in
            let lhsScore = symbolRelevance(lhs)
            let rhsScore = symbolRelevance(rhs)
            return lhsScore == rhsScore ? lhs.line < rhs.line : lhsScore > rhsScore
        }
        .prefix(maximum)
        .sorted { $0.line < $1.line }
    }

    private func symbolRelevance(_ symbol: RepositorySymbol) -> Int {
        var score = symbol.kind.isType ? 100 : 0
        if symbol.signature.contains("@main") { score += 100 }
        if symbol.signature.contains(" public ") || symbol.signature.hasPrefix("public ") { score += 30 }
        if symbol.documentation != nil { score += 15 }
        if ["body", "init", "sendMessage", "call"].contains(symbol.name) { score += 10 }
        return score
    }

    private func repositoryAreas(
        in files: [RepositoryFileMap]
    ) -> [(name: String, fileCount: Int, symbolCount: Int)] {
        var values: [String: (files: Int, symbols: Int)] = [:]
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            let directoryComponents = components.dropLast()
            let name: String
            if directoryComponents.count >= 2 {
                name = directoryComponents.prefix(2).joined(separator: "/")
            } else {
                name = directoryComponents.first ?? "Workspace root"
            }
            values[name, default: (0, 0)].files += 1
            values[name, default: (0, 0)].symbols += file.symbols.count
        }
        return values.map { key, value in
            (name: key, fileCount: value.files, symbolCount: value.symbols)
        }.sorted { lhs, rhs in
            if lhs.fileCount != rhs.fileCount { return lhs.fileCount > rhs.fileCount }
            return lhs.name < rhs.name
        }
    }

    private func header(
        _ snapshot: RepositoryMapSnapshot,
        selectedFileCount: Int
    ) -> String {
        "SWIFT WORKSPACE MAP \(detail.rawValue.uppercased())\n"
            + "revision: \(snapshot.revision)\n"
            + "workspace: \(URL(fileURLWithPath: snapshot.workspacePath).lastPathComponent)\n"
            + "indexed: \(snapshot.files.count) Swift files, \(snapshot.symbolCount) declarations\n"
            + "selected: \(selectedFileCount) files\n"
    }

    private func finalize(
        _ output: String,
        snapshot: RepositoryMapSnapshot
    ) -> String {
        var value = String(output.prefix(outputCharacterBudget))
        if snapshot.wasTruncated {
            value += "\nWarning: source discovery reached its 2,500-file safety limit.\n"
        }
        value += "\nUse read_file only for the focused line ranges needed after this map."
        return value
    }

    private func scopedFiles(
        _ files: [RepositoryFileMap],
        path: String?
    ) -> [RepositoryFileMap] {
        guard let path, path != "." else { return files }
        return files.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
    }

    private func normalizedWorkspacePath(_ path: String?) throws -> String? {
        guard let value = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let normalized = NSString(string: value).standardizingPath
        guard normalized != "..", !normalized.hasPrefix("../"), !normalized.hasPrefix("/") else {
            throw RepositoryMapServiceError.invalidPath(value)
        }
        return normalized
    }

    private func relevance(of file: RepositoryFileMap) -> Int {
        var score = file.symbols.filter(\.kind.isType).count * 5 + file.symbols.count
        let name = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        if file.symbols.contains(where: { $0.signature.contains("@main") }) { score += 100 }
        if ["App", "Store", "Service", "Model", "View", "Coordinator"].contains(where: {
            name.contains($0)
        }) {
            score += 15
        }
        if file.path.contains("Tests/") || file.path.contains("Test/") { score -= 8 }
        return score
    }
}
