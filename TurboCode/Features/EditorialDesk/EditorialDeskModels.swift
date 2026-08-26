import Foundation

/// The entry point used to create the working document inside the editorial
/// desk. These are content-ingestion modes, not model profiles or chat routes.
nonisolated enum EditorialDeskTab: String, CaseIterable, Identifiable, Sendable {
    case write = "Write"
    case paste = "Paste"
    case notes = "From Notes"
    case transcript = "From Transcript"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .write: "square.and.pencil"
        case .paste: "doc.on.clipboard"
        case .notes: "note.text"
        case .transcript: "waveform"
        }
    }
}

/// User-configurable editorial grouping shown by the desk metadata bar.
/// Sections intentionally store only presentation data so a newsroom can
/// define its own taxonomy without changing the editorial workflow.
nonisolated public struct EditorialDeskSection: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var systemImage: String

    public init(
        id: UUID = UUID(),
        name: String,
        systemImage: String
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
    }
}

/// User-configurable article type. The color is stored as a hex string so the
/// catalog stays platform-neutral and can be persisted without archiving
/// SwiftUI or AppKit color objects.
nonisolated public struct EditorialDeskType: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var systemImage: String
    public var colorHex: String

    public init(
        id: UUID = UUID(),
        name: String,
        systemImage: String,
        colorHex: String
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.colorHex = colorHex
    }
}

/// The complete user-owned editorial taxonomy persisted by Settings.
nonisolated public struct EditorialDeskCatalog: Codable, Hashable, Sendable {
    public var sections: [EditorialDeskSection]
    public var types: [EditorialDeskType]

    public init(
        sections: [EditorialDeskSection],
        types: [EditorialDeskType]
    ) {
        self.sections = sections
        self.types = types
    }

    /// An empty catalog keeps the harness domain-neutral. Teams populate the
    /// newsroom taxonomy from Settings instead of inheriting mockup values.
    public static let `default` = EditorialDeskCatalog(sections: [], types: [])
}

/// Metadata selected for one draft. The complete catalog entries are carried
/// through publishing so the Markdown front matter preserves their symbols
/// and type color alongside the human-readable labels.
nonisolated public struct EditorialDeskMetadata: Codable, Hashable, Sendable {
    public var section: EditorialDeskSection?
    public var type: EditorialDeskType?

    public init(
        section: EditorialDeskSection?,
        type: EditorialDeskType?
    ) {
        self.section = section
        self.type = type
    }

    public static let empty = EditorialDeskMetadata(section: nil, type: nil)

    public var isEmpty: Bool { section == nil && type == nil }
}

/// Describes where an editorial ground-truth source came from without
/// restricting the material to a fixed file-name or document-type catalog.
nonisolated enum EditorialSourceOrigin: Hashable, Sendable {
    case importedFile(path: String)
    case pasted
    case notes
    case transcript

    var label: String {
        switch self {
        case .importedFile(let path): path
        case .pasted: "Pasted text"
        case .notes: "Notes"
        case .transcript: "Transcript"
        }
    }
}

/// User-named material that the editorial model must treat as authoritative.
nonisolated struct EditorialSource: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let origin: EditorialSourceOrigin
    let content: String

    init(
        id: UUID = UUID(),
        name: String,
        origin: EditorialSourceOrigin,
        content: String
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.content = content
    }
}

/// Operations exposed by the editorial action menu. The raw value is the
/// stable model-facing action label; UI may localize its presentation later.
nonisolated enum EditorialAction: String, CaseIterable, Codable, Hashable, Sendable {
    case verifyFacts = "Verify facts"
    case makeNeutral = "Make neutral"
    case tightenLead = "Tighten the lead"
    case checkCitations = "Check citations"
    case deskSummary = "Desk summary"

    var instruction: String {
        switch self {
        case .verifyFacts:
            "Check every material claim against the ground-truth sources and report discrepancies."
        case .makeNeutral:
            "Rewrite the document in a neutral editorial voice without changing supported facts."
        case .tightenLead:
            "Rewrite the title, deck, and opening so the lead is concise and supported by the sources."
        case .checkCitations:
            "Check whether material claims have support in the sources and identify missing or weak citations."
        case .deskSummary:
            "Prepare a concise desk summary while preserving source-supported facts and flagging uncertainty."
        }
    }
}

/// Provider-neutral payload for one editorial operation. Sources are kept
/// separate from the user request so an adapter cannot confuse ground truth
/// with an instruction to the model.
nonisolated struct EditorialRequest: Sendable {
    let userInstruction: String
    let document: String
    let sources: [EditorialSource]
    let action: EditorialAction
}

/// A source-backed discrepancy returned by the future editorial model client.
nonisolated struct EditorialFinding: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceName: String
    let documentExcerpt: String
    let sourceExcerpt: String
    let explanation: String
    let severity: Severity

    enum Severity: String, Codable, Hashable, Sendable {
        case note
        case warning
        case critical
    }
}

/// Structured result boundary for the isolated feature. Keeping this contract
/// here prevents provider details from leaking into the modal or the main chat
/// timeline.
nonisolated struct EditorialResult: Codable, Hashable, Sendable {
    let id: UUID
    let revisedDocument: String?
    let findings: [EditorialFinding]
    let summary: String

    init(
        id: UUID = UUID(),
        revisedDocument: String?,
        findings: [EditorialFinding],
        summary: String
    ) {
        self.id = id
        self.revisedDocument = revisedDocument
        self.findings = findings
        self.summary = summary
    }

    /// Models may wrap JSON in a Markdown fence despite the response contract.
    /// Strip only that transport decoration; malformed structured output stays
    /// an error instead of being silently treated as an editorial success.
    static func decode(from response: String) throws -> Self {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```"), let firstNewline = trimmed.firstIndex(of: "\n") {
            let bodyStart = trimmed.index(after: firstNewline)
            let body = String(trimmed[bodyStart...])
            json = body.hasSuffix("```")
                ? String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                : body
        } else {
            json = trimmed
        }

        guard let data = json.data(using: .utf8) else {
            throw EditorialResponseError.invalidUTF8
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

nonisolated enum EditorialResponseError: LocalizedError, Sendable {
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: "The editorial model returned invalid UTF-8 output."
        }
    }
}

protocol EditorialModelClient: Sendable {
    func perform(_ request: EditorialRequest) async throws -> EditorialResult
    func cancel() async
}
