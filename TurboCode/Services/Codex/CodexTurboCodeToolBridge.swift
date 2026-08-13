import Foundation

/// A function tool advertised to Codex App Server when TurboCode starts a
/// thread. App Server owns tool selection and the agent loop; TurboCode owns
/// execution, safety policy, and native presentation for these tools.
nonisolated struct CodexDynamicToolSpec: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: CodexJSONValue

    var jsonValue: CodexJSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

/// Retains the JSON-RPC request identifier so every client-side tool call can
/// be completed exactly once, including validation and execution failures.
nonisolated struct CodexDynamicToolCall: Sendable, Equatable {
    let rpcID: CodexRPCID
    let callID: String
    let tool: String
    let arguments: CodexJSONValue
}

nonisolated struct CodexDynamicToolResult: Sendable, Equatable {
    let text: String
    let succeeded: Bool

    static func success(_ text: String) -> Self {
        Self(text: text, succeeded: true)
    }

    static func failure(_ text: String) -> Self {
        Self(text: text, succeeded: false)
    }
}

/// Optional presentation returned alongside model-facing text. Edit and Git
/// tools already publish their own receipts through ChatStore, while directory
/// listings need this structured payload to drive WorkspaceListingWidget.
nonisolated enum CodexToolPresentation: Sendable, Equatable {
    case workspaceListing(WorkspaceListingBlock)
}

nonisolated struct CodexToolExecution: Sendable, Equatable {
    let result: CodexDynamicToolResult
    let presentation: CodexToolPresentation?
}

nonisolated enum CodexToolBridgeError: LocalizedError, Sendable, Equatable {
    case unsupportedTool(String)
    case invalidArguments(tool: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            "TurboCode does not expose the '\(name)' tool to Codex."
        case .invalidArguments(let tool, let detail):
            "Invalid arguments for \(tool): \(detail)"
        }
    }
}

/// Executes the bounded TurboCode tool surface requested by Codex. The bridge
/// intentionally uses the same concrete tool implementations as
/// FoundationModels profiles, preserving path validation, revision checks,
/// approval gates, execution limits, and existing visual receipts.
nonisolated enum CodexTurboCodeToolBridge {
    static func developerInstructions(
        workspaceRoot: String,
        agentTuning: AgentTuningConfig,
        dynamicTools: [CodexDynamicToolSpec],
        availableSkills: [TurboCodeSkillDefinition],
        workspaceInstructions: WorkspaceInstructions?
    ) -> String {
        // Codex owns its agent loop, but receives the same product identity,
        // safety rules, and optional project instructions as native sessions.
        TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: .codex,
                backend: .codex,
                workspaceRoot: workspaceRoot,
                agentTuning: agentTuning,
                toolIDs: [
                    .listWorkspace,
                    .swiftWorkspaceMap,
                    .readFile,
                    .searchWorkspace,
                    .editFile,
                    .swiftPackageManager,
                    .xcodeProject,
                    .git
                ] + (availableSkills.isEmpty ? [] : [.loadSkill])
                + (dynamicTools.contains(where: {
                    $0.name == ToolCapabilityID.createSkill.rawValue
                }) ? [.createSkill] : [])
                + (dynamicTools.contains(where: {
                    $0.name == ToolCapabilityID.delegateTask.rawValue
                }) ? [.delegateTask] : []),
                toolNames: dynamicTools.map(\.name),
                availableSkills: availableSkills,
                workspaceInstructions: workspaceInstructions
            )
        )
    }

    static func specifications(
        workspaceRoot: String,
        agentTuning: AgentTuningConfig,
        includesDelegation: Bool = false,
        availableSkills: [TurboCodeSkillDefinition] = []
    ) -> [CodexDynamicToolSpec] {
        let listTool = ListWorkspaceTool(workspaceRoot: workspaceRoot)
        let mapTool = SwiftWorkspaceMapTool(
            workspaceRoot: workspaceRoot,
            detail: .compact,
            contextWindowTokens: 32_768
        )
        let readTool = ReadFileTool(workspaceRoot: workspaceRoot)
        let ripgrepTool = RipgrepTool(
            workspaceRoot: workspaceRoot,
            executionPolicy: agentTuning.execution
        )
        let editTool = ApplyEditsTool(workspaceRoot: workspaceRoot)
        let swiftPackageTool = SwiftPackageManagerTool(
            workspaceRoot: workspaceRoot,
            executionPolicy: agentTuning.execution
        )
        let xcodeTool = XcodeProjectTool(
            workspaceRoot: workspaceRoot,
            executionPolicy: agentTuning.execution,
            enhancedOutput: true
        )
        let gitTool = GitTool(
            workspaceRoot: workspaceRoot,
            policy: agentTuning.git,
            executionPolicy: agentTuning.execution
        )

        var specifications: [CodexDynamicToolSpec] = [
            .init(
                name: listTool.name,
                description: listTool.description,
                inputSchema: objectSchema(
                    properties: [
                        "path": stringSchema(
                            "Workspace-relative directory path; use . for the root."
                        )
                    ],
                    required: ["path"]
                )
            ),
            .init(
                name: mapTool.name,
                description: mapTool.description,
                inputSchema: objectSchema(
                    properties: [
                        "action": enumSchema(["overview", "symbols", "related", "refresh"]),
                        "query": nullableStringSchema(),
                        "path": nullableStringSchema()
                    ],
                    required: ["action"]
                )
            ),
            .init(
                name: readTool.name,
                description: readTool.description,
                inputSchema: objectSchema(
                    properties: [
                        "filePath": stringSchema("Workspace-relative file path."),
                        "startLine": nullableIntegerSchema(),
                        "endLine": nullableIntegerSchema(),
                        "limit": nullableIntegerSchema()
                    ],
                    required: ["filePath"]
                )
            ),
            .init(
                name: ripgrepTool.name,
                description: ripgrepTool.description,
                inputSchema: objectSchema(
                    properties: [
                        "action": enumSchema(["files", "search"]),
                        "pattern": nullableStringSchema(),
                        "path": nullableStringSchema(),
                        "filePattern": nullableStringSchema(),
                        "excludePattern": nullableStringSchema(),
                        "literal": nullableBooleanSchema(),
                        "caseSensitive": nullableBooleanSchema(),
                        "contextLines": nullableIntegerSchema(),
                        "filesOnly": nullableBooleanSchema(),
                        "hidden": nullableBooleanSchema(),
                        "maxResults": nullableIntegerSchema()
                    ],
                    required: ["action"]
                )
            ),
            .init(
                name: editTool.name,
                description: editTool.description,
                inputSchema: applyEditsSchema
            ),
            .init(
                name: swiftPackageTool.name,
                description: swiftPackageTool.description,
                inputSchema: swiftPackageManagerSchema
            ),
            .init(
                name: xcodeTool.name,
                description: xcodeTool.description,
                inputSchema: objectSchema(
                    properties: [
                        "action": enumSchema(["inspect", "build", "test"]),
                        "containerPath": nullableStringSchema(),
                        "scheme": nullableStringSchema(),
                        "configuration": nullableStringSchema(),
                        "destination": nullableStringSchema(),
                        "timeoutSeconds": nullableIntegerSchema()
                    ],
                    required: ["action"]
                )
            ),
            .init(
                name: gitTool.name,
                description: gitTool.description,
                inputSchema: gitSchema
            )
        ]
        if includesDelegation {
            // Delegation is profile-scoped: direct Codex threads must not
            // advertise a tool without a configured bounded worker invoker.
            specifications.append(delegateTaskSpecification)
        }
        if !availableSkills.isEmpty {
            specifications.append(loadSkillSpecification)
        }
        if !workspaceRoot.isEmpty {
            specifications.append(createSkillSpecification)
        }
        return specifications
    }

    static func activitySummary(for tool: String) -> String {
        switch tool {
        case "list_workspace": "Browsing workspace"
        case "swift_workspace_map": "Mapping Swift workspace"
        case "read_file": "Reading file"
        case "ripgrep": "Searching workspace"
        case "apply_edits": "Editing files"
        case "swift_package_manager": "Working with Swift package"
        case "xcode_project": "Working with Xcode project"
        case "git": "Working with Git"
        case "delegate_task": "Delegating task to worker"
        case "create_skill": "Creating workspace skill"
        default: "Running \(tool)"
        }
    }

    static func execute(
        _ call: CodexDynamicToolCall,
        workspaceRoot: String,
        workspaceName: String?,
        agentTuning: AgentTuningConfig,
        availableSkills: [TurboCodeSkillDefinition] = [],
        delegationInvoker: (any AgentTaskInvoking)? = nil
    ) async throws -> CodexToolExecution {
        switch call.tool {
        case "list_workspace":
            let output = try await ListWorkspaceTool(
                workspaceRoot: workspaceRoot
            ).call(arguments: ListWorkspaceArguments(
                path: try requiredString("path", in: call)
            ))
            let listing = workspaceListing(
                output,
                callID: call.callID,
                workspaceName: workspaceName
            )
            return CodexToolExecution(
                result: .success(listingResultText(output)),
                presentation: .workspaceListing(listing)
            )
        case "swift_workspace_map":
            let text = try await SwiftWorkspaceMapTool(
                workspaceRoot: workspaceRoot,
                detail: .compact,
                contextWindowTokens: 32_768
            ).call(arguments: SwiftWorkspaceMapArguments(
                action: try requiredString("action", in: call),
                query: optionalString("query", in: call),
                path: optionalString("path", in: call)
            ))
            return .init(result: .success(text), presentation: nil)
        case "read_file":
            let text = try await ReadFileTool(workspaceRoot: workspaceRoot)
                .call(arguments: ReadFileArguments(
                    filePath: try requiredString("filePath", in: call),
                    startLine: optionalInteger("startLine", in: call),
                    endLine: optionalInteger("endLine", in: call),
                    limit: optionalInteger("limit", in: call)
                ))
            return .init(result: .success(text), presentation: nil)
        case "ripgrep":
            let text = try await RipgrepTool(
                workspaceRoot: workspaceRoot,
                executionPolicy: agentTuning.execution
            ).call(arguments: RipgrepArguments(
                    action: try requiredString("action", in: call),
                    pattern: optionalString("pattern", in: call),
                    path: optionalString("path", in: call),
                    filePattern: optionalString("filePattern", in: call),
                    excludePattern: optionalString("excludePattern", in: call),
                    literal: optionalBoolean("literal", in: call),
                    caseSensitive: optionalBoolean("caseSensitive", in: call),
                    contextLines: optionalInteger("contextLines", in: call),
                    filesOnly: optionalBoolean("filesOnly", in: call),
                    hidden: optionalBoolean("hidden", in: call),
                    maxResults: optionalInteger("maxResults", in: call)
                ))
            return .init(result: .success(text), presentation: nil)
        case "apply_edits":
            let text = try await ApplyEditsTool(workspaceRoot: workspaceRoot)
                .call(arguments: try applyEditsArguments(call))
            return .init(result: .success(text), presentation: nil)
        case "swift_package_manager":
            let text = try await SwiftPackageManagerTool(
                workspaceRoot: workspaceRoot,
                executionPolicy: agentTuning.execution
            ).call(arguments: SwiftPackageManagerArguments(
                action: try requiredString("action", in: call),
                packageName: optionalString("packageName", in: call),
                packageType: optionalString("packageType", in: call),
                dependency: optionalString("dependency", in: call),
                dependencyType: optionalString("dependencyType", in: call),
                requirement: optionalString("requirement", in: call),
                requirementValue: optionalString("requirementValue", in: call),
                dependencyName: optionalString("dependencyName", in: call),
                target: optionalString("target", in: call),
                package: optionalString("package", in: call),
                configuration: optionalString("configuration", in: call),
                product: optionalString("product", in: call),
                filter: optionalString("filter", in: call),
                timeoutSeconds: optionalInteger("timeoutSeconds", in: call)
            ))
            return .init(result: .success(text), presentation: nil)
        case "xcode_project":
            let text = try await XcodeProjectTool(
                workspaceRoot: workspaceRoot,
                executionPolicy: agentTuning.execution,
                enhancedOutput: true
            ).call(arguments: XcodeProjectArguments(
                action: try requiredString("action", in: call),
                containerPath: optionalString("containerPath", in: call),
                scheme: optionalString("scheme", in: call),
                configuration: optionalString("configuration", in: call),
                destination: optionalString("destination", in: call),
                timeoutSeconds: optionalInteger("timeoutSeconds", in: call)
            ))
            return .init(result: .success(text), presentation: nil)
        case "git":
            let text = try await GitTool(
                workspaceRoot: workspaceRoot,
                policy: agentTuning.git,
                executionPolicy: agentTuning.execution
            ).call(arguments: GitArguments(
                operation: try requiredString("operation", in: call),
                paths: call.arguments["paths"]?.arrayValue?.compactMap(\.stringValue),
                branch: optionalString("branch", in: call),
                message: optionalString("message", in: call),
                remote: optionalString("remote", in: call),
                limit: optionalInteger("limit", in: call)
            ))
            return .init(result: .success(text), presentation: nil)
        case "delegate_task":
            guard let delegationInvoker else {
                throw CodexToolBridgeError.unsupportedTool(call.tool)
            }
            let arguments = try delegateTaskArguments(call)
            let result = await delegationInvoker.invoke(try arguments.envelope())
            let data = try JSONEncoder().encode(result)
            guard let json = String(data: data, encoding: .utf8) else {
                throw AgentTaskWorkerError.invalidEnvelopeEncoding
            }
            return .init(result: .success(json), presentation: nil)
        case "load_skill":
            let text = try await LoadSkillTool(skills: availableSkills).call(
                arguments: LoadSkillArguments(
                    name: try requiredString("name", in: call)
                )
            )
            return .init(result: .success(text), presentation: nil)
        case "create_skill":
            let text = try await CreateSkillTool(workspaceRoot: workspaceRoot).call(
                arguments: CreateSkillArguments(
                    name: try requiredString("name", in: call),
                    description: try requiredString("description", in: call),
                    instructions: try requiredString("instructions", in: call)
                )
            )
            return .init(result: .success(text), presentation: nil)
        default:
            throw CodexToolBridgeError.unsupportedTool(call.tool)
        }
    }

    private static func applyEditsArguments(
        _ call: CodexDynamicToolCall
    ) throws -> ApplyEditsArguments {
        guard let files = call.arguments["files"]?.arrayValue else {
            throw invalid(call, "'files' must be an array")
        }
        let requests = try files.enumerated().map { fileIndex, value in
            guard value.objectValue != nil else {
                throw invalid(call, "files[\(fileIndex)] must be an object")
            }
            guard let filePath = value["filePath"]?.stringValue else {
                throw invalid(call, "files[\(fileIndex)].filePath is required")
            }
            guard let operations = value["operations"]?.arrayValue else {
                throw invalid(call, "files[\(fileIndex)].operations must be an array")
            }
            let parsedOperations = try operations.enumerated().map {
                operationIndex, operation in
                guard let operationName = operation["operation"]?.stringValue else {
                    throw invalid(
                        call,
                        "files[\(fileIndex)].operations[\(operationIndex)].operation is required"
                    )
                }
                return LineEditOperation(
                    operation: operationName,
                    startLine: operation["startLine"]?.integerValue,
                    endLine: operation["endLine"]?.integerValue,
                    content: operation["content"]?.stringValue
                )
            }
            return FileEditRequest(
                filePath: filePath,
                revision: value["revision"]?.stringValue,
                operations: parsedOperations
            )
        }
        return ApplyEditsArguments(files: requests)
    }

    private static func delegateTaskArguments(
        _ call: CodexDynamicToolCall
    ) throws -> DelegateTaskArguments {
        return DelegateTaskArguments(
            mode: optionalString("mode", in: call) ?? "coding",
            goal: try requiredString("goal", in: call)
        )
    }

    private static func requiredString(
        _ key: String,
        in call: CodexDynamicToolCall
    ) throws -> String {
        guard let value = call.arguments[key]?.stringValue, !value.isEmpty else {
            throw invalid(call, "'\(key)' must be a non-empty string")
        }
        return value
    }

    private static func optionalString(
        _ key: String,
        in call: CodexDynamicToolCall
    ) -> String? {
        call.arguments[key]?.stringValue
    }

    private static func optionalInteger(
        _ key: String,
        in call: CodexDynamicToolCall
    ) -> Int? {
        call.arguments[key]?.integerValue
    }

    private static func optionalBoolean(
        _ key: String,
        in call: CodexDynamicToolCall
    ) -> Bool? {
        call.arguments[key]?.boolValue
    }

    private static func invalid(
        _ call: CodexDynamicToolCall,
        _ detail: String
    ) -> CodexToolBridgeError {
        .invalidArguments(tool: call.tool, detail: detail)
    }

    private static func workspaceListing(
        _ output: WorkspaceListingToolOutput,
        callID: String,
        workspaceName: String?
    ) -> WorkspaceListingBlock {
        WorkspaceListingBlock(
            toolCallID: callID,
            path: output.path,
            entries: output.entries.compactMap { entry in
                guard let kind = WorkspaceListingEntryKind(
                    rawValue: entry.kind
                ) else { return nil }
                return WorkspaceListingEntry(
                    name: entry.name,
                    relativePath: entry.relativePath,
                    kind: kind,
                    sizeBytes: entry.sizeBytes,
                    modifiedAt: entry.modifiedAt,
                    fileExtension: entry.fileExtension
                )
            },
            totalCount: output.totalCount,
            isTruncated: output.isTruncated,
            errorMessage: output.errorMessage,
            capturedAt: .now,
            workspaceName: workspaceName
        )
    }

    private static func listingResultText(
        _ output: WorkspaceListingToolOutput
    ) -> String {
        let entries: [CodexJSONValue] = output.entries.map { entry in
            .object([
                "name": .string(entry.name),
                "relativePath": .string(entry.relativePath),
                "kind": .string(entry.kind),
                "sizeBytes": entry.sizeBytes.map(CodexJSONValue.integer) ?? .null,
                "modifiedAt": entry.modifiedAt.map(CodexJSONValue.string) ?? .null,
                "fileExtension": entry.fileExtension.map(CodexJSONValue.string) ?? .null
            ])
        }
        return CodexJSONValue.object([
            "path": .string(output.path),
            "entries": .array(entries),
            "totalCount": .integer(output.totalCount),
            "isTruncated": .bool(output.isTruncated),
            "errorMessage": output.errorMessage.map(CodexJSONValue.string) ?? .null
        ]).jsonString
    }

    private static let applyEditsSchema = objectSchema(
        properties: [
            "files": .object([
                "type": .string("array"),
                "items": objectSchema(
                    properties: [
                        "filePath": stringSchema("Workspace-relative file path."),
                        "revision": nullableStringSchema(),
                        "operations": .object([
                            "type": .string("array"),
                            "items": objectSchema(
                                properties: [
                                    "operation": enumSchema([
                                        "replace_lines",
                                        "insert_before",
                                        "insert_after",
                                        "delete_lines",
                                        "replace_file",
                                        "create"
                                    ]),
                                    "startLine": nullableIntegerSchema(),
                                    "endLine": nullableIntegerSchema(),
                                    "content": nullableStringSchema()
                                ],
                                required: ["operation"]
                            )
                        ])
                    ],
                    required: ["filePath", "operations"]
                )
            ])
        ],
        required: ["files"]
    )

    /// Keep Codex's JSON schema aligned with the flat Foundation Models
    /// arguments so every provider sees the same SwiftPM capability surface.
    private static let swiftPackageManagerSchema = objectSchema(
        properties: [
            "action": enumSchema([
                "initialize", "addDependency", "addTargetDependency", "resolve",
                "update", "build", "test", "run", "clean", "reset", "describe",
                "showDependencies", "dumpPackage"
            ]),
            "packageName": nullableStringSchema(),
            "packageType": nullableStringSchema(),
            "dependency": nullableStringSchema(),
            "dependencyType": nullableStringSchema(),
            "requirement": nullableStringSchema(),
            "requirementValue": nullableStringSchema(),
            "dependencyName": nullableStringSchema(),
            "target": nullableStringSchema(),
            "package": nullableStringSchema(),
            "configuration": nullableStringSchema(),
            "product": nullableStringSchema(),
            "filter": nullableStringSchema(),
            "timeoutSeconds": nullableIntegerSchema()
        ],
        required: ["action"]
    )

    private static let gitSchema = objectSchema(
        properties: [
            "operation": enumSchema([
                "init", "status", "diff", "stagedDiff", "log", "branches",
                "remotes", "createBranch", "switchBranch", "stage", "stageAll",
                "unstage", "unstageAll", "commit", "fetch", "pull", "push",
                "merge", "rebase", "mergeAbort", "rebaseAbort", "discard",
                "clean", "resetHard", "deleteBranch", "forceDeleteBranch",
                "forcePush"
            ]),
            "paths": .object([
                "type": .array([.string("array"), .string("null")]),
                "items": .object(["type": .string("string")])
            ]),
            "branch": nullableStringSchema(),
            "message": nullableStringSchema(),
            "remote": nullableStringSchema(),
            "limit": nullableIntegerSchema()
        ],
        required: ["operation"]
    )

    private static let loadSkillSpecification = CodexDynamicToolSpec(
        name: "load_skill",
        description: "Load the full instructions for one reusable TurboCode skill when the user's request matches its catalog description.",
        inputSchema: objectSchema(
            properties: [
                "name": stringSchema("Exact skill name from the available skills catalog.")
            ],
            required: ["name"]
        )
    )

    private static let createSkillSpecification = CodexDynamicToolSpec(
        name: "create_skill",
        description: "Create one reusable Codex-compatible skill at .agents/skills/<name>/SKILL.md in the active workspace.",
        inputSchema: objectSchema(
            properties: [
                "name": stringSchema("Lowercase kebab-case skill identifier."),
                "description": stringSchema("Concise trigger description used for implicit activation."),
                "instructions": stringSchema("Complete procedural instructions for the skill body.")
            ],
            required: ["name", "description", "instructions"]
        )
    )

    /// Mirrors the intentionally small DelegateTaskArguments surface so both
    /// coordinator transports only choose between a tool-using worker and a
    /// text-only worker. Runtime policy remains application-owned.
    private static let delegateTaskSpecification = CodexDynamicToolSpec(
        name: "delegate_task",
        description: "Delegate one goal to the configured worker. Use coding for workspace work with the profile-configured worker tools, or text for a tool-free prose response.",
        inputSchema: objectSchema(
            properties: [
                "mode": enumSchema(["coding", "text"]),
                "goal": stringSchema("Complete task to send to the worker.")
            ],
            required: ["mode", "goal"]
        )
    )

    private static let stringArraySchema = CodexJSONValue.object([
        "type": .string("array"),
        "items": .object(["type": .string("string")])
    ])

    private static func objectSchema(
        properties: [String: CodexJSONValue],
        required: [String]
    ) -> CodexJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(CodexJSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static func stringSchema(_ description: String) -> CodexJSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    private static func nullableStringSchema() -> CodexJSONValue {
        .object(["type": .array([.string("string"), .string("null")])])
    }

    private static func nullableIntegerSchema() -> CodexJSONValue {
        .object(["type": .array([.string("integer"), .string("null")])])
    }

    private static func nullableBooleanSchema() -> CodexJSONValue {
        .object(["type": .array([.string("boolean"), .string("null")])])
    }

    private static func enumSchema(_ values: [String]) -> CodexJSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(CodexJSONValue.string))
        ])
    }
}

extension CodexJSONValue {
    nonisolated var objectValue: [String: CodexJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    nonisolated var arrayValue: [CodexJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    nonisolated var integerValue: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value) where value.rounded() == value: Int(value)
        default: nil
        }
    }

    nonisolated var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
