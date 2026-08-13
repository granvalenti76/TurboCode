import Foundation

/// Semantic categories used by the lightweight diff renderer. The lexer owns
/// Swift syntax only; color remains a view/theme decision so dark mode and
/// accessibility can adapt without re-tokenizing source text.
nonisolated enum InspectorSyntaxTokenKind: Sendable, Hashable {
    case plain
    case keyword
    case type
    case attribute
    case number
    case string
    case comment
}

nonisolated struct InspectorSyntaxToken: Sendable, Hashable {
    let text: String
    let kind: InspectorSyntaxTokenKind
}

/// Provides extension-level presentation without claiming broad IDE language
/// support. Swift receives its native symbol and lexical color; adjacent
/// project files continue to render faithfully as plain monospaced text.
nonisolated enum InspectorFilePresentation {
    static func symbolName(for path: String) -> String {
        fileExtension(path) == "swift" ? "swift" : "doc.text"
    }

    static func supportsSyntaxHighlighting(_ path: String) -> Bool {
        fileExtension(path) == "swift"
    }

    private static func fileExtension(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }
}

/// Builds token streams for both sides of a unified diff. Maintaining an old
/// and a current lexer state is essential for block comments and multiline
/// strings: removed text must not change how an added/current line is colored.
nonisolated enum InspectorSyntaxHighlighter {
    static func tokens(
        for lines: [DiffLine],
        filePath: String
    ) -> [UUID: [InspectorSyntaxToken]] {
        guard InspectorFilePresentation.supportsSyntaxHighlighting(filePath) else {
            return Dictionary(uniqueKeysWithValues: lines.map {
                ($0.id, [InspectorSyntaxToken(text: $0.content, kind: .plain)])
            })
        }

        var originalLexer = SwiftLineLexer()
        var currentLexer = SwiftLineLexer()
        var result: [UUID: [InspectorSyntaxToken]] = [:]
        result.reserveCapacity(lines.count)

        for line in lines {
            switch line.type {
            case .context:
                _ = originalLexer.tokenize(line.content)
                result[line.id] = currentLexer.tokenize(line.content)
            case .added:
                result[line.id] = currentLexer.tokenize(line.content)
            case .removed:
                result[line.id] = originalLexer.tokenize(line.content)
            }
        }
        return result
    }

    static func swiftTokens(for lines: [String]) -> [[InspectorSyntaxToken]] {
        var lexer = SwiftLineLexer()
        return lines.map { lexer.tokenize($0) }
    }
}

/// A small stateful Swift lexer tailored to presentation. It deliberately does
/// not attempt parsing or semantic name resolution, but correctly preserves
/// nested block comments and raw/multiline string boundaries across lines.
nonisolated private struct SwiftLineLexer {
    private var blockCommentDepth = 0
    private var multilineStringHashCount: Int?

    private static let keywords: Set<String> = [
        "actor", "any", "associatedtype", "as", "async", "await", "borrowing",
        "break", "case", "catch", "class", "consume", "consuming", "continue",
        "convenience", "copy", "default", "defer", "deinit", "didSet", "distributed",
        "do", "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "final", "for", "func", "get", "guard", "if", "import", "indirect", "infix", "init",
        "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating", "nil",
        "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package",
        "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat",
        "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct",
        "subscript", "super", "switch", "throws", "throw", "true", "try", "typealias",
        "unowned", "var", "weak", "where", "while", "willSet", "with", "yield"
    ]

    mutating func tokenize(_ line: String) -> [InspectorSyntaxToken] {
        guard !line.isEmpty else {
            return [InspectorSyntaxToken(text: "", kind: .plain)]
        }
        var tokens: [InspectorSyntaxToken] = []
        var index = line.startIndex

        while index < line.endIndex {
            if blockCommentDepth > 0 {
                consumeBlockComment(in: line, from: &index, into: &tokens)
                continue
            }
            if let hashCount = multilineStringHashCount {
                consumeMultilineString(
                    in: line,
                    from: &index,
                    hashCount: hashCount,
                    into: &tokens
                )
                continue
            }
            if line[index...].hasPrefix("//") {
                append(String(line[index...]), kind: .comment, to: &tokens)
                break
            }
            if line[index...].hasPrefix("/*") {
                consumeBlockComment(in: line, from: &index, into: &tokens)
                continue
            }
            if let opening = stringOpening(in: line, at: index) {
                consumeString(
                    in: line,
                    from: &index,
                    opening: opening,
                    into: &tokens
                )
                continue
            }

            let character = line[index]
            if character == "@" || character == "#" {
                let start = index
                index = line.index(after: index)
                while index < line.endIndex, isIdentifierContinuation(line[index]) {
                    index = line.index(after: index)
                }
                let text = String(line[start..<index])
                append(text, kind: character == "@" ? .attribute : .keyword, to: &tokens)
                continue
            }
            if isIdentifierStart(character) {
                let start = index
                index = line.index(after: index)
                while index < line.endIndex, isIdentifierContinuation(line[index]) {
                    index = line.index(after: index)
                }
                let text = String(line[start..<index])
                let kind: InspectorSyntaxTokenKind
                if Self.keywords.contains(text) {
                    kind = .keyword
                } else if text.first?.isUppercase == true {
                    kind = .type
                } else {
                    kind = .plain
                }
                append(text, kind: kind, to: &tokens)
                continue
            }
            if character.isNumber {
                let start = index
                index = line.index(after: index)
                while index < line.endIndex,
                      line[index].isNumber || "._xXabcdefABCDEF".contains(line[index]) {
                    index = line.index(after: index)
                }
                append(String(line[start..<index]), kind: .number, to: &tokens)
                continue
            }

            let next = line.index(after: index)
            append(String(line[index..<next]), kind: .plain, to: &tokens)
            index = next
        }
        return tokens
    }

    private mutating func consumeBlockComment(
        in line: String,
        from index: inout String.Index,
        into tokens: inout [InspectorSyntaxToken]
    ) {
        let start = index
        while index < line.endIndex {
            if line[index...].hasPrefix("/*") {
                blockCommentDepth += 1
                index = line.index(index, offsetBy: 2)
            } else if line[index...].hasPrefix("*/") {
                blockCommentDepth -= 1
                index = line.index(index, offsetBy: 2)
                if blockCommentDepth == 0 { break }
            } else {
                index = line.index(after: index)
            }
        }
        append(String(line[start..<index]), kind: .comment, to: &tokens)
    }

    private mutating func consumeMultilineString(
        in line: String,
        from index: inout String.Index,
        hashCount: Int,
        into tokens: inout [InspectorSyntaxToken]
    ) {
        let start = index
        let delimiter = "\"\"\"" + String(repeating: "#", count: hashCount)
        if let closing = line.range(of: delimiter, range: index..<line.endIndex) {
            index = closing.upperBound
            multilineStringHashCount = nil
        } else {
            index = line.endIndex
        }
        append(String(line[start..<index]), kind: .string, to: &tokens)
    }

    private mutating func consumeString(
        in line: String,
        from index: inout String.Index,
        opening: StringOpening,
        into tokens: inout [InspectorSyntaxToken]
    ) {
        let start = index
        index = opening.contentStart
        if opening.isMultiline {
            let delimiter = "\"\"\"" + String(repeating: "#", count: opening.hashCount)
            if let closing = line.range(of: delimiter, range: index..<line.endIndex) {
                index = closing.upperBound
                multilineStringHashCount = nil
            } else {
                index = line.endIndex
                multilineStringHashCount = opening.hashCount
            }
            append(String(line[start..<index]), kind: .string, to: &tokens)
            return
        }

        let closing = "\"" + String(repeating: "#", count: opening.hashCount)
        while index < line.endIndex {
            if opening.hashCount == 0, line[index] == "\\" {
                index = line.index(after: index)
                if index < line.endIndex { index = line.index(after: index) }
                continue
            }
            if line[index...].hasPrefix(closing) {
                index = line.index(index, offsetBy: closing.count)
                break
            }
            index = line.index(after: index)
        }
        append(String(line[start..<index]), kind: .string, to: &tokens)
    }

    private func stringOpening(in line: String, at index: String.Index) -> StringOpening? {
        var cursor = index
        var hashCount = 0
        while cursor < line.endIndex, line[cursor] == "#" {
            hashCount += 1
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == "\"" else { return nil }
        let triple = line[cursor...].hasPrefix("\"\"\"")
        let quoteCount = triple ? 3 : 1
        return StringOpening(
            hashCount: hashCount,
            isMultiline: triple,
            contentStart: line.index(cursor, offsetBy: quoteCount)
        )
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func append(
        _ text: String,
        kind: InspectorSyntaxTokenKind,
        to tokens: inout [InspectorSyntaxToken]
    ) {
        guard !text.isEmpty else { return }
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1] = InspectorSyntaxToken(
                text: last.text + text,
                kind: kind
            )
        } else {
            tokens.append(InspectorSyntaxToken(text: text, kind: kind))
        }
    }

    private struct StringOpening {
        let hashCount: Int
        let isMultiline: Bool
        let contentStart: String.Index
    }
}
