import Foundation

// MARK: - ChatBlock — a single message or event block in the timeline

public struct ChatBlock: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ChatBlockKind
    public let text: String
    public let createdAt: Date
    public var model: String?
    public var providerId: String?
    public var diffPatch: DiffPatchBlock?
    public var gitCommit: GitCommitBlock?
    public var productGuide: ProductGuideBlock?

    public init(
        id: String = UUID().uuidString,
        kind: ChatBlockKind,
        text: String,
        createdAt: Date = .now,
        model: String? = nil,
        providerId: String? = nil,
        diffPatch: DiffPatchBlock? = nil,
        gitCommit: GitCommitBlock? = nil,
        productGuide: ProductGuideBlock? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.model = model
        self.providerId = providerId
        self.diffPatch = diffPatch
        self.gitCommit = gitCommit
        self.productGuide = productGuide
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
    case diffPatch = "diff_patch"
    case gitCommit = "git_commit"
    case productGuide = "product_guide"
}

// MARK: - Git Commit Block

nonisolated public struct GitCommitBlock: Sendable, Hashable, Codable {
    public let workspaceRoot: String
    public let hash: String
    public let shortHash: String
    public let message: String
    public let branch: String
    public let files: [GitCommitFileChange]
    public var status: GitCommitStatus
    public var errorMessage: String?

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

nonisolated public struct GitCommitFileChange: Identifiable, Sendable, Hashable, Codable {
    public let path: String
    public let additions: Int
    public let deletions: Int

    public var id: String { path }
}

nonisolated public enum GitCommitStatus: String, Sendable, Hashable, Codable {
    case committed
    case undoing
    case undone
    case failed
}

// MARK: - Diff Patch Block

public struct DiffPatchBlock: Sendable, Hashable, Codable {
    public var workspaceRoot: String
    public var patch: String
    public var patches: [String]?
    public var files: [DiffPatchFileChange]
    public var status: DiffPatchStatus
    public var errorMessage: String?

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct DiffPatchFileChange: Identifiable, Sendable, Hashable, Codable {
    public let path: String
    public let additions: Int
    public let deletions: Int

    public var id: String { path }
}

public enum DiffPatchStatus: String, Sendable, Hashable, Codable {
    case awaitingApproval
    case running
    case applied
    case undoing
    case undone
    case failed
    case rejected
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
