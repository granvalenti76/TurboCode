import Foundation
import FoundationModels

// MARK: - Stored Session

/// A full persisted session: metadata, structured timeline blocks, and the
/// optional semantic transcript required to rebuild a provider session.
///
/// Schema 1 is intentionally unchanged during the 0.3.7 extraction. Moving
/// ownership must remain rollback-safe and must not migrate a user's JSON.
nonisolated public struct StoredSession: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    /// Versioning lets new catalog metadata be added without making older
    /// session files unreadable during app upgrades.
    public var schemaVersion: Int
    public let id: String
    public var title: String
    public var projectName: String
    public var workspacePath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var mode: ConversationMode
    public var modelBackend: String
    public var blocks: [StoredBlock]
    /// Optional so sessions written before transcript persistence remain
    /// decodable and can still open as timeline-only history.
    public var transcript: Transcript?

    public init(id: String = UUID().uuidString, title: String,
                projectName: String, workspacePath: String? = nil,
                createdAt: Date = .now, updatedAt: Date = .now,
                isPinned: Bool = false, isArchived: Bool = false,
                mode: ConversationMode = .agent,
                modelBackend: String = "Llama-server",
                blocks: [StoredBlock] = [], transcript: Transcript? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.title = title; self.projectName = projectName
        self.workspacePath = workspacePath; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.modelBackend = modelBackend
        self.isPinned = isPinned; self.isArchived = isArchived; self.mode = mode
        self.blocks = blocks
        self.transcript = transcript
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, projectName, workspacePath
        case createdAt, updatedAt, isPinned, isArchived, mode
        case modelBackend, blocks, transcript
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        projectName = try values.decode(String.self, forKey: .projectName)
        workspacePath = try values.decodeIfPresent(String.self, forKey: .workspacePath)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        mode = try values.decodeIfPresent(ConversationMode.self, forKey: .mode) ?? .agent
        modelBackend = try values.decode(String.self, forKey: .modelBackend)
        blocks = try values.decodeIfPresent([StoredBlock].self, forKey: .blocks) ?? []
        transcript = try values.decodeIfPresent(Transcript.self, forKey: .transcript)
    }

    public func hash(into hasher: inout Hasher) {
        // The stable session identity is sufficient for collection hashing;
        // Transcript is Equatable and Codable but intentionally not Hashable.
        hasher.combine(id)
    }
}

// MARK: - Stored Block

/// Codable representation of a `ChatBlock`. Structured tool receipts remain
/// typed so hosts can recreate rich widgets instead of parsing display text.
nonisolated public struct StoredBlock: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let text: String
    public let createdAt: Date
    public var model: String?
    public var providerId: String?
    public var diffPatch: DiffPatchBlock?
    public var gitCommit: GitCommitBlock?
    public var gitStatus: GitStatusBlock?
    public var productGuide: ProductGuideBlock?
    public var workspaceListing: WorkspaceListingBlock?

    public init(id: String = UUID().uuidString, kind: String, text: String,
                createdAt: Date = .now, model: String? = nil, providerId: String? = nil,
                diffPatch: DiffPatchBlock? = nil, gitCommit: GitCommitBlock? = nil,
                gitStatus: GitStatusBlock? = nil,
                productGuide: ProductGuideBlock? = nil,
                workspaceListing: WorkspaceListingBlock? = nil) {
        self.id = id; self.kind = kind; self.text = text
        self.createdAt = createdAt; self.model = model; self.providerId = providerId
        self.diffPatch = diffPatch
        self.gitCommit = gitCommit
        self.gitStatus = gitStatus
        self.productGuide = productGuide
        self.workspaceListing = workspaceListing
    }
}
