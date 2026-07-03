import Foundation

// MARK: - Thread — Sendable model for a conversation thread

public struct Thread: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var workspace: String?
    public var mode: ThreadMode

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        isArchived: Bool = false,
        workspace: String? = nil,
        mode: ThreadMode = .agent
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

public enum ThreadMode: String, Sendable, Hashable, CaseIterable {
    case agent
    case plan
}

// MARK: - ChatBlock — a single message or event block in the timeline

public struct ChatBlock: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ChatBlockKind
    public let text: String
    public let createdAt: Date
    public var model: String?
    public var providerId: String?

    public init(
        id: String = UUID().uuidString,
        kind: ChatBlockKind,
        text: String,
        createdAt: Date = .now,
        model: String? = nil,
        providerId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.model = model
        self.providerId = providerId
    }
}

public enum ChatBlockKind: String, Sendable, Hashable, CaseIterable {
    case user
    case assistant
    case reasoning
    case tool
    case approval
    case review
    case compaction
}

// MARK: - ToolBlock — tool call / execution result

public struct ToolBlock: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ToolBlockKind
    public var summary: String
    public var status: ToolBlockStatus
    public var detail: String?
    public var filePath: String?
    public var exitCode: Int?
    public var durationMs: Int?

    public init(
        id: String = UUID().uuidString,
        kind: ToolBlockKind,
        summary: String,
        status: ToolBlockStatus = .running,
        detail: String? = nil,
        filePath: String? = nil,
        exitCode: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.status = status
        self.detail = detail
        self.filePath = filePath
        self.exitCode = exitCode
        self.durationMs = durationMs
    }
}

public enum ToolBlockKind: String, Sendable, Hashable, CaseIterable {
    case toolCall = "tool_call"
    case commandExecution = "command_execution"
    case fileChange = "file_change"
    case backgroundShell = "background_shell"
    case delegateTask = "delegate_task"
}

public enum ToolBlockStatus: String, Sendable, Hashable {
    case running
    case success
    case error
}

// MARK: - App Route

public enum AppRoute: String, Sendable, Hashable, CaseIterable {
    case chat
    case write
    case settings
    case plugins
    case claw
    case schedule
    case workflow
}

// MARK: - Right Panel Mode

public enum RightPanelMode: String, Sendable, Hashable {
    case todo
    case changes
    case browser
    case file
    case plan
    case sddAI = "sdd-ai"
    case subagents
}

// MARK: - Settings Section

public enum SettingsSection: String, Sendable, Hashable, CaseIterable {
    case general
    case providers
    case write
    case mediaGeneration = "media-generation"
    case speechToText = "speech-to-text"
    case agents
    case archives
    case worktree
    case memory
    case shortcuts
    case claw
    case updates
    case terminal
    case debug
}
