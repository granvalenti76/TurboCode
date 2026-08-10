import Foundation

// MARK: - Thread — Sendable model for a conversation thread

public struct Conversation: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var workspace: String?
    public var mode: ConversationMode

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        isArchived: Bool = false,
        workspace: String? = nil,
        mode: ConversationMode = .agent
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.workspace = workspace
        self.mode = mode
    }
}

public enum ConversationMode: String, Codable, Sendable, Hashable, CaseIterable {
    case agent
    case plan
}
