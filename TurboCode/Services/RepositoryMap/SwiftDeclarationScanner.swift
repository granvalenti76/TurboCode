import Foundation

/// Extracts navigation-grade Swift declarations without evaluating or building
/// the workspace. It deliberately returns signatures, locations and short doc
/// comments, never declaration bodies.
nonisolated struct SwiftDeclarationScanner: Sendable {
    func scan(
        source: String,
        relativePath: String,
        fingerprint: RepositoryFileFingerprint,
        detail: RepositoryMapDetail
    ) -> RepositoryFileMap {
        let lines = source.components(separatedBy: .newlines)
        var imports: [String] = []
        var symbols: [RepositorySymbol] = []
        var documentation: [String] = []
        var blockDocumentation: [String] = []
        var insideBlockDocumentation = false
        var attributes: [String] = []
        var braceDepth = 0
        var typeStack: [(name: String, bodyDepth: Int)] = []

        for index in lines.indices {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            while let last = typeStack.last, braceDepth < last.bodyDepth {
                typeStack.removeLast()
            }

            if insideBlockDocumentation {
                let cleaned = cleanBlockDocLine(trimmed)
                if !cleaned.isEmpty { blockDocumentation.append(cleaned) }
                if trimmed.contains("*/") {
                    insideBlockDocumentation = false
                    documentation = blockDocumentation
                    blockDocumentation.removeAll(keepingCapacity: true)
                }
                continue
            }
            if trimmed.hasPrefix("/**") {
                insideBlockDocumentation = !trimmed.contains("*/")
                let cleaned = cleanBlockDocLine(trimmed)
                if !cleaned.isEmpty { blockDocumentation.append(cleaned) }
                if !insideBlockDocumentation {
                    documentation = blockDocumentation
                    blockDocumentation.removeAll(keepingCapacity: true)
                }
                continue
            }
            if trimmed.hasPrefix("///") {
                documentation.append(
                    String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                )
                continue
            }
            if trimmed.isEmpty {
                documentation.removeAll(keepingCapacity: true)
                attributes.removeAll(keepingCapacity: true)
                continue
            }

            let code = codePortion(of: rawLine)
            let codeTrimmed = code.trimmingCharacters(in: .whitespaces)
            if codeTrimmed.hasPrefix("@"), !looksLikeDeclaration(codeTrimmed) {
                attributes.append(normalizeSignature(codeTrimmed))
                continue
            }
            if let imported = importName(in: codeTrimmed) {
                imports.append(imported)
            }

            let declaration = declarationSignature(lines: lines, startingAt: index)
            let signature = (attributes + [declaration]).joined(separator: " ")
            let parent = typeStack.last?.name
            if let match = typeDeclaration(in: signature) {
                let symbol = RepositorySymbol(
                    name: match.name,
                    kind: match.kind,
                    signature: signature,
                    line: index + 1,
                    documentation: summarizedDocumentation(documentation),
                    parent: parent,
                    referencedTypes: detail == .enhanced
                        ? referencedTypes(in: signature, excluding: match.name)
                        : []
                )
                symbols.append(symbol)
                if code.contains("{") || signature.contains("{") {
                    typeStack.append((qualifiedName(parent: parent, name: match.name), braceDepth + 1))
                }
                documentation.removeAll(keepingCapacity: true)
                attributes.removeAll(keepingCapacity: true)
            } else if let match = callableDeclaration(in: signature) {
                symbols.append(
                    RepositorySymbol(
                        name: match.name,
                        kind: match.kind,
                        signature: signature,
                        line: index + 1,
                        documentation: summarizedDocumentation(documentation),
                        parent: parent,
                        referencedTypes: detail == .enhanced
                            ? referencedTypes(in: signature, excluding: match.name)
                            : []
                    )
                )
                documentation.removeAll(keepingCapacity: true)
                attributes.removeAll(keepingCapacity: true)
            } else if isMemberOrTopLevel(braceDepth: braceDepth, typeStack: typeStack),
                      shouldIncludeProperty(signature, detail: detail),
                      let property = propertyDeclaration(in: signature) {
                symbols.append(
                    RepositorySymbol(
                        name: property,
                        kind: .property,
                        signature: signature,
                        line: index + 1,
                        documentation: summarizedDocumentation(documentation),
                        parent: parent,
                        referencedTypes: detail == .enhanced
                            ? referencedTypes(in: signature, excluding: property)
                            : []
                    )
                )
                documentation.removeAll(keepingCapacity: true)
                attributes.removeAll(keepingCapacity: true)
            } else if !codeTrimmed.isEmpty,
                      !codeTrimmed.hasPrefix("//") {
                documentation.removeAll(keepingCapacity: true)
                attributes.removeAll(keepingCapacity: true)
            }

            braceDepth += braceDelta(in: code)
            braceDepth = max(0, braceDepth)
        }

        return RepositoryFileMap(
            path: relativePath,
            fingerprint: fingerprint,
            imports: Array(Set(imports)).sorted(),
            symbols: deduplicated(symbols)
        )
    }

    private func typeDeclaration(
        in signature: String
    ) -> (kind: RepositorySymbolKind, name: String)? {
        let pattern = #"\b(actor|class|struct|enum|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_\.]*)"#
        guard let groups = captures(pattern: pattern, in: signature), groups.count == 2,
              let kind = RepositorySymbolKind(rawValue: groups[0]) else { return nil }
        return (kind, groups[1])
    }

    private func callableDeclaration(
        in signature: String
    ) -> (kind: RepositorySymbolKind, name: String)? {
        let pattern = #"(?:^|\s)(func|init|subscript)\s*([A-Za-z_][A-Za-z0-9_]*)?\s*[<(]"#
        guard let groups = captures(pattern: pattern, in: signature), !groups.isEmpty else {
            return nil
        }
        switch groups[0] {
        case "init": return (.initializer, "init")
        case "subscript": return (.subscriptDeclaration, "subscript")
        default:
            guard groups.count > 1, !groups[1].isEmpty else { return nil }
            return (.function, groups[1])
        }
    }

    private func propertyDeclaration(in signature: String) -> String? {
        let pattern = #"\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        return captures(pattern: pattern, in: signature)?.first
    }

    private func shouldIncludeProperty(
        _ signature: String,
        detail: RepositoryMapDetail
    ) -> Bool {
        guard signature.range(of: #"\b(var|let)\s+[A-Za-z_]"#, options: .regularExpression) != nil else {
            return false
        }
        if detail == .enhanced { return true }
        return signature.contains(" var body")
            || signature.hasPrefix("var body")
            || signature.contains("@Published")
            || signature.contains("@Observable")
            || signature.contains("@Environment")
            || signature.contains(" static let shared")
    }

    private func declarationSignature(lines: [String], startingAt index: Int) -> String {
        let first = codePortion(of: lines[index]).trimmingCharacters(in: .whitespaces)
        guard looksLikeDeclaration(first) else { return first }

        var pieces: [String] = [first]
        var parentheses = delimiterDelta(in: first, open: "(", close: ")")
        var angles = delimiterDelta(in: first, open: "<", close: ">")
        var cursor = index
        while cursor + 1 < lines.count,
              pieces.count < 8,
              !signatureIsComplete(pieces.joined(separator: " "), parentheses: parentheses, angles: angles) {
            cursor += 1
            let next = codePortion(of: lines[cursor]).trimmingCharacters(in: .whitespaces)
            guard !next.isEmpty else { break }
            pieces.append(next)
            parentheses += delimiterDelta(in: next, open: "(", close: ")")
            angles += delimiterDelta(in: next, open: "<", close: ">")
        }
        return normalizeSignature(pieces.joined(separator: " "))
    }

    private func looksLikeDeclaration(_ value: String) -> Bool {
        value.range(
            of: #"\b(actor|class|struct|enum|protocol|extension|func|init|subscript|var|let)\b"#,
            options: .regularExpression
        ) != nil
    }

    private func signatureIsComplete(_ value: String, parentheses: Int, angles: Int) -> Bool {
        guard parentheses <= 0, angles <= 0 else { return false }
        if value.contains("{") || value.contains("=") { return true }
        let isProperty = value.range(
            of: #"\b(var|let)\s+[A-Za-z_]"#,
            options: .regularExpression
        ) != nil
        if isProperty { return !value.hasSuffix(",") }
        let isType = value.range(
            of: #"\b(actor|class|struct|enum|protocol|extension)\b"#,
            options: .regularExpression
        ) != nil
        if isType {
            return !value.hasSuffix(":") && !value.hasSuffix(",")
        }
        let isCallable = value.range(
            of: #"(?:^|\s)(func|init|subscript)\b"#,
            options: .regularExpression
        ) != nil
        if isCallable, value.contains(")"), !value.hasSuffix(",") { return true }
        return value.contains("->")
    }

    private func normalizeSignature(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if let brace = result.firstIndex(of: "{") {
            result = String(result[..<brace]).trimmingCharacters(in: .whitespaces)
        }
        let isProperty = result.range(
            of: #"\b(var|let)\s+[A-Za-z_]"#,
            options: .regularExpression
        ) != nil
        if isProperty, let equals = result.firstIndex(of: "=") {
            result = String(result[..<equals]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func importName(in line: String) -> String? {
        guard line.hasPrefix("import ") || line.hasPrefix("@testable import ") else { return nil }
        return line.split(separator: " ").last.map(String.init)
    }

    private func codePortion(of line: String) -> String {
        var result = ""
        var insideString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if !insideString, character == "/", next < line.endIndex, line[next] == "/" {
                break
            }
            if character == "\"", !escaped {
                insideString.toggle()
                result.append(character)
                index = next
                continue
            }
            if !insideString { result.append(character) }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
            index = next
        }
        return result
    }

    private func braceDelta(in line: String) -> Int {
        delimiterDelta(in: line, open: "{", close: "}")
    }

    private func delimiterDelta(in value: String, open: Character, close: Character) -> Int {
        value.reduce(into: 0) { result, character in
            if character == open { result += 1 }
            if character == close { result -= 1 }
        }
    }

    private func summarizedDocumentation(_ lines: [String]) -> String? {
        guard let first = lines.first(where: { !$0.isEmpty }) else { return nil }
        let summary = first
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : String(summary.prefix(180))
    }

    private func cleanBlockDocLine(_ line: String) -> String {
        line.replacingOccurrences(of: "/**", with: "")
            .replacingOccurrences(of: "*/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
    }

    private func referencedTypes(in signature: String, excluding name: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#) else {
            return []
        }
        let range = NSRange(signature.startIndex..., in: signature)
        let ignored: Set<String> = [
            name, "String", "Int", "Double", "Bool", "Void", "Self", "Any",
            "Codable", "Hashable", "Sendable", "Identifiable", "CaseIterable",
            "MainActor", "Observable", "State", "Environment", "AppStorage"
        ]
        let values = regex.matches(in: signature, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: signature) else { return nil }
            return String(signature[range])
        }
        return Array(Set(values).subtracting(ignored)).sorted()
    }

    private func captures(pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private func qualifiedName(parent: String?, name: String) -> String {
        parent.map { "\($0).\(name)" } ?? name
    }

    private func isMemberOrTopLevel(
        braceDepth: Int,
        typeStack: [(name: String, bodyDepth: Int)]
    ) -> Bool {
        if braceDepth == 0 { return true }
        return typeStack.last?.bodyDepth == braceDepth
    }

    private func deduplicated(_ symbols: [RepositorySymbol]) -> [RepositorySymbol] {
        var seen: Set<String> = []
        return symbols.filter { seen.insert($0.id).inserted }
    }
}
