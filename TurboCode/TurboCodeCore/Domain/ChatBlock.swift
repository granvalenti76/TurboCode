import Foundation

// MARK: - ChatBlock — a single message or event block in the timeline

/// Immutable timeline data emitted by the core and rendered by an arbitrary
/// client. Structured receipts stay values rather than views so third-party
/// hosts can choose their own presentation without losing tool semantics.

nonisolated public struct ChatBlock: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ChatBlockKind
    public let text: String
    public let createdAt: Date
    public var model: String?
    public var providerId: String?
    public var diffPatch: DiffPatchBlock?
    public var gitCommit: GitCommitBlock?
    public var gitStatus: GitStatusBlock?
    public var productGuide: ProductGuideBlock?
    public var workspaceListing: WorkspaceListingBlock?
    public var pluginWidget: TypeScriptPluginWidgetReceipt?
    public var editorialPublication: EditorialPublicationBlock?
    var steeringDelivery: SteeringDeliveryMetadata?

    public init(
        id: String = UUID().uuidString,
        kind: ChatBlockKind,
        text: String,
        createdAt: Date = .now,
        model: String? = nil,
        providerId: String? = nil,
        diffPatch: DiffPatchBlock? = nil,
        gitCommit: GitCommitBlock? = nil,
        gitStatus: GitStatusBlock? = nil,
        productGuide: ProductGuideBlock? = nil,
        workspaceListing: WorkspaceListingBlock? = nil,
        pluginWidget: TypeScriptPluginWidgetReceipt? = nil,
        editorialPublication: EditorialPublicationBlock? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.model = model
        self.providerId = providerId
        self.diffPatch = diffPatch
        self.gitCommit = gitCommit
        self.gitStatus = gitStatus
        self.productGuide = productGuide
        self.workspaceListing = workspaceListing
        self.pluginWidget = pluginWidget
        self.editorialPublication = editorialPublication
        self.steeringDelivery = nil
    }
}

nonisolated public enum ChatBlockKind: String, Sendable, Hashable, CaseIterable {
    case user
    case assistant
    case reasoning
    case tool
    case approval
    case review
    case compaction
    case diffPatch = "diff_patch"
    case gitCommit = "git_commit"
    case gitStatus = "git_status"
    case productGuide = "product_guide"
    case workspaceListing = "workspace_listing"
    case pluginWidget = "plugin_widget"
    case editorialPublication = "editorial_publication"
}

// MARK: - Editorial Publication Block

/// Immutable receipt for a Markdown draft created by Editorial Desk. The
/// timeline stores only the filesystem result; publishing never implies a
/// follow-up model turn or copies live editor state into the conversation.
nonisolated public struct EditorialPublicationBlock: Sendable, Hashable, Codable {
    public let draftID: UUID
    public let workspaceRoot: String
    public let relativePath: String
    public let fileName: String
    public let wordCount: Int
    public let publishedAt: Date

    public init(
        draftID: UUID,
        workspaceRoot: String,
        relativePath: String,
        fileName: String,
        wordCount: Int,
        publishedAt: Date = .now
    ) {
        self.draftID = draftID
        self.workspaceRoot = workspaceRoot
        self.relativePath = relativePath
        self.fileName = fileName
        self.wordCount = wordCount
        self.publishedAt = publishedAt
    }
}

// MARK: - Git Status Block

/// Immutable working-tree statistics captured when the model explicitly asks
/// Git for status. Persisting the snapshot keeps historical charts stable.
nonisolated public struct GitStatusBlock: Sendable, Hashable, Codable {
    public let workspaceRoot: String
    public let branch: String
    public let files: [GitStatusFileChange]
    public let changedFilesCount: Int
    public let isClean: Bool
    public let capturedAt: Date
    public let errorMessage: String?

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// Keeps the compact timeline chart deterministic: meaningful line
    /// changes rank first, with paths breaking ties across repeated snapshots.
    public func mostModifiedFiles(limit: Int = 5) -> [GitStatusFileChange] {
        guard limit > 0 else { return [] }
        return Array(
            files
                .filter { $0.totalChanges > 0 }
                .sorted {
                    if $0.totalChanges == $1.totalChanges {
                        return $0.path < $1.path
                    }
                    return $0.totalChanges > $1.totalChanges
                }
                .prefix(limit)
        )
    }
}

nonisolated public struct GitStatusFileChange: Identifiable, Sendable, Hashable, Codable {
    public let path: String
    public let additions: Int
    public let deletions: Int

    public var id: String { path }
    public var totalChanges: Int { additions + deletions }
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

nonisolated public struct DiffPatchBlock: Sendable, Hashable, Codable {
    public var workspaceRoot: String
    public var patch: String
    public var patches: [String]?
    public var files: [DiffPatchFileChange]
    /// Immutable before/after text captured by structured edit tools. Optional
    /// so historical receipts and raw patch tools remain decodable.
    public var reviewFiles: [DiffReviewFileSnapshot]?
    public var status: DiffPatchStatus
    public var errorMessage: String?

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

/// Full text snapshots used by the native document-modal review. Keeping both
/// sides prevents later workspace edits from changing historical evidence.
nonisolated public struct DiffReviewFileSnapshot: Identifiable, Sendable, Hashable, Codable {
    public let path: String
    public let originalText: String?
    public let modifiedText: String?

    public var id: String { path }

    public init(path: String, originalText: String?, modifiedText: String?) {
        self.path = path
        self.originalText = originalText
        self.modifiedText = modifiedText
    }
}

nonisolated public struct DiffPatchFileChange: Identifiable, Sendable, Hashable, Codable {
    public let path: String
    public let additions: Int
    public let deletions: Int

    public var id: String { path }
}

nonisolated public enum DiffPatchStatus: String, Sendable, Hashable, Codable {
    case awaitingApproval
    case running
    case applied
    case undoing
    case undone
    case failed
    case rejected
}

// MARK: - ToolBlock — tool call / execution result

nonisolated public struct ToolBlock: Identifiable, Sendable, Hashable {
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

nonisolated public enum ToolBlockKind: String, Sendable, Hashable, CaseIterable {
    case toolCall = "tool_call"
    case commandExecution = "command_execution"
    case fileChange = "file_change"
    case backgroundShell = "background_shell"
    case delegateTask = "delegate_task"
}

nonisolated public enum ToolBlockStatus: String, Sendable, Hashable {
    case running
    case success
    case error
}
