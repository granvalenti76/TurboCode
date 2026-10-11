import Foundation

// MARK: - Thread — Sendable model for a conversation thread

/// Provider- and presentation-neutral metadata for one conversation.
/// Keeping this value free of UI frameworks lets the same contract cross the
/// future TurboCodeCore package boundary without actor or rendering concerns.

nonisolated public struct Conversation: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var workspace: String?
    public var mode: ConversationMode
    /// Fixed at creation. A session never changes domain, because the domain
    /// decides whether its tools may touch the Mac or only the Cowork VM.
    public let domain: SessionDomain

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        isArchived: Bool = false,
        workspace: String? = nil,
        mode: ConversationMode = .agent,
        domain: SessionDomain = .coding
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.workspace = workspace
        self.mode = mode
        self.domain = domain
    }
}

nonisolated public enum ConversationMode: String, Codable, Sendable, Hashable, CaseIterable {
    case agent
    case plan
}

/// Where a session's work is allowed to execute.
///
/// This axis is independent of `ConversationMode`: `agent`/`plan` describes
/// how the conversation proceeds, while the domain describes the execution
/// boundary. `coding` sessions use the host workspace tools; `cowork` sessions
/// execute only inside the managed Linux VM and reach the Mac only through an
/// approved export (see PRODUCT.md, Cowork Domain).
nonisolated public enum SessionDomain: String, Codable, Sendable, Hashable, CaseIterable {
    case coding
    case cowork
}
