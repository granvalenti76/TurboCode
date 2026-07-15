import Foundation

nonisolated enum RepositoryMapDetail: String, Codable, Sendable, Hashable {
    case compact
    case enhanced

    func outputCharacterBudget(contextWindowTokens: Int) -> Int {
        let contextScaledBudget = max(6_000, contextWindowTokens * 3 / 8)
        switch self {
        case .compact: return min(12_000, contextScaledBudget)
        case .enhanced: return min(24_000, max(12_000, contextScaledBudget))
        }
    }
}

nonisolated enum RepositorySymbolKind: String, Codable, Sendable, Hashable {
    case actor
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case initializer
    case subscriptDeclaration
    case property

    var mapLabel: String {
        switch self {
        case .subscriptDeclaration: "subscript"
        case .initializer: "init"
        default: rawValue
        }
    }

    var isType: Bool {
        switch self {
        case .actor, .class, .struct, .enum, .protocol, .extension: true
        default: false
        }
    }
}

nonisolated struct RepositorySymbol: Codable, Sendable, Hashable, Identifiable {
    var id: String { "\(line):\(kind.rawValue):\(name)" }

    let name: String
    let kind: RepositorySymbolKind
    let signature: String
    let line: Int
    let documentation: String?
    let parent: String?
    let referencedTypes: [String]
}

nonisolated struct RepositoryFileFingerprint: Codable, Sendable, Hashable {
    let size: Int
    let modifiedAt: TimeInterval
}

nonisolated struct RepositoryFileMap: Codable, Sendable, Hashable, Identifiable {
    var id: String { path }

    let path: String
    let fingerprint: RepositoryFileFingerprint
    let imports: [String]
    let symbols: [RepositorySymbol]
}

nonisolated struct RepositoryProjectMarker: Codable, Sendable, Hashable {
    let kind: String
    let path: String
}

nonisolated struct RepositoryMapSnapshot: Codable, Sendable, Hashable {
    let formatVersion: Int
    let workspacePath: String
    let revision: String
    let generatedAt: Date
    let projectMarkers: [RepositoryProjectMarker]
    let files: [RepositoryFileMap]
    let wasTruncated: Bool

    var symbolCount: Int { files.reduce(0) { $0 + $1.symbols.count } }
}
