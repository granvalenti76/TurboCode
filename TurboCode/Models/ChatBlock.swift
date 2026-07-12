import Foundation

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
