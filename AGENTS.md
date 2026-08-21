# Repository Guidelines

## Working Environment

This repository is commonly driven by **local models with small context windows** (32K / 64K / 120K tokens). Treat context as a scarce resource:

- **Read targetedly.** Never dump whole files. Use `grep`/`rg`, `find`, and `head` to inspect just the symbols or regions you need before editing.
- **Prefer the compact repomap below** to locate code without opening files.
- **Read only what a change requires.** One small file, one grep result, or one declaration beats a full-file read every time.
- **Plan first, then act.** Before any refactor, new feature, or non-trivial edit, state a short plan (what, where, how, why) and get approval.
- **No unapproved interventions.** Do not create, modify, or delete files, run mutating commands, or start background work until the user approves the plan.
- **Git: extreme caution.** Never commit, merge, rebase, reset, force-push, or stash without explicit approval. Show the exact command and expected effect first. Prefer non-destructive inspection (`git status`, `git diff`, `git diff --check`).

## Project Structure & Module Organization

`TurboCode/` contains the Swift 6 macOS application. Keep UI in `Views/`, presentation state in `ViewModels/` and `Stores/`, data types in `Models/`, and integrations in `Services/` or `Tools/`. Product references live in `TurboCode/Documentation/`. `TurboCodeEvaluations/` contains Swift Testing suites and agent evaluations. Assets belong in `Media.xcassets`; project settings live in `TurboCode.xcodeproj`.

## Compact Repomap

Use this map to locate code without reading files. Add two directory levels to any path below.

```
TurboCode/ (macOS 27, Swift 6, ~18k LOC)
├── TurboCodeApp.swift          → @main, WindowGroup, injects ChatStore + SettingsStore
│
├── Models/                     → Data types (all Sendable)
│   ├── ChatBlock, ToolBlock, DiffPatchBlock, Conversation
│   ├── AgentTaskContract (Envelope, Outcome, Verification, DelegationBudget)
│   ├── AgentTuningConfig, OrchestratorPolicy, AgentPolicy, ExecutionPolicy
│   ├── ModelBackend, ModelRoutingPolicy, ModelToolCatalog (ToolCapabilityID)
│   ├── AgentActivity (phase, tools, runtime events)
│   ├── TurboCodeConfig (persisted sessions), StoredSession, StoredBlock
│   ├── RepositoryMap, XcodeProject
│   ├── AppNavigation (AppRoute, RightPanelMode), OrchestratorMode
│   └── ApprovalRequest, ReviewComment, UserDynamicProfile
│
├── Stores/                     → @Observable / @MainActor state
│   ├── ChatStore (shared singleton, onboarding, restore)
│   ├── ChatResponseCoordinator, ChatTimelineStore
│   ├── ConversationStore + ConversationRepository (Disk impl)
│   ├── ModelRuntimeStore, ModelSessionFactory (capabilities, profiles)
│   ├── CodexRuntimeStore, AgentActivityStore
│   ├── ReviewCoordinator, ReviewDraftStore, ReviewReceiptReducer
│   ├── SettingsStore (theme, fontSize), CredentialStore (Keychain)
│   ├── ToolInteractionStore, WorkbenchStore, WorkspaceStore
│   └── TurboCodeDynamicProfile (OrchestratorProfile)
│
├── Services/
│   ├── Chat/
│   │   ├── AgentTaskRunner (BoundedAgentTaskRunner, FoundationModelsTaskWorker)
│   │   ├── AgentTaskVerificationRunner (Xcode verifier, MutationJournal)
│   │   ├── NativeResponseRunner, OnDeviceStreamingGuard
│   │   ├── SessionRebuildHistory, TurboCodePersonality
│   │   ├── TurboCodeSystemPromptBuilder
│   │   └── AgentTaskPathScope
│   ├── Workspace/   GitRepositoryServicing, DiffPatchApplying, WorkspaceBrowsingService, WorkspaceInstructionsLoader
│   ├── Xcode/       XcodeCommandRunner (actor), XcodeProjectService, XcodeDiagnosticsParser, XcodeProjectDiscoveryService
│   ├── RepositoryMap/ RepositoryMapService, RepositoryMapCache (actor), SwiftDeclarationScanner
│   ├── Codex/       CodexAppServerClient (actor), CodexTurboCodeToolBridge
│   ├── Profiles/    DynamicProfileStore, DynamicProfileRuntimeSelection
│   ├── Documentation/ ProductDocumentationStore
│   ├── ToolPresentation/ ToolPresentationRouter, NativeToolEchoFilter, WorkspaceListingFollowUpContext
│   └── CodePresentation/ InspectorSyntaxHighlighter
│
├── Tools/                      → LanguageModelSession Tool conformances
│   ├── ApplyEditsTool + EditFileTool (actor ApplyEditsService)
│   ├── BashTool, ReadFileTool, RemoveFileTool, FileSystemTool
│   │   └── ToolApprovalRegistry (actor), WorkspacePathResolver
│   ├── GitTool, RipgrepTool, SwiftPackageManagerTool
│   ├── DiffPatchTool (actor DiffPatchService, DiffPatchParser)
│   ├── DelegateTaskTool, CallPowerfulModelTool
│   ├── CreateSkillTool, LoadSkillTool
│   ├── Profiles: OrchestratorProfile, DelegateProfile, StandaloneProfile
│   ├── OnDevice/: ListWorkspaceTool, TurboCodeGuideTool, WriteOnDeviceTool
│   ├── RepositoryMap/: SwiftWorkspaceMapTool
│   └── Xcode/: XcodeProjectTool
│
├── ViewModels/
│   ├── ComposerViewModel, GitDiffViewModel
│   ├── SessionSearchViewModel, SkillsViewModel, ToolsViewModel
│
├── Views/                      → SwiftUI
│   ├── WorkbenchSplitView (main layout)
│   ├── Workbench/: MainStageView, ChatContentView, InputFieldView,
│   │   TopBarView, RuntimeBannerView, EmbeddedTerminalView
│   ├── Chat/: ChatBlockView, MessageTimelineView, DiffPatchReviewSheet,
│   │   DiffPatchWidget, GitCommitWidget, GitStatusWidget,
│   │   ProductGuideWidget, WorkspaceListingWidget
│   ├── Sidebar/: SidebarView, ThreadRowView, SessionSearchView
│   ├── Inspector/: InspectorPanelView (FileInspectorView, DiffSectionView)
│   ├── Settings/: SettingsTabView (General/Provider/Agent/Shortcut)
│   ├── Skills/: SkillsView
│   ├── Tools/: ToolsView
│   └── Components/: ToolEntryView
│
├── Diagnostics/
│   ├── AgentBenchmark, AgentDiagnostics, OnDeviceStatisticsView
│
├── Intents/
│   ├── AskTurboCodeIntent, SessionSummaryIntent
│   └── TurboCodeShortcutsProvider
│
└── Vendor/foundation-models-utilities/  (SPM)
    ├── ChatCompletionsLanguageModel, ReasoningStreamRelay
    ├── RollingWindow, SummarizeHistory, DropCompletedToolCalls
    └── Skills/ (Skill, SkillBuilder, SkillActivations)
```

**Main flow:** `TurboCodeApp` → `ChatStore` → `ChatResponseCoordinator` → `AgentTaskRunner` (Bounded) → `FoundationModelsTaskWorker` → tools → `ChatTimelineStore` → SwiftUI views

**Key patterns:**
- Actor-based services for I/O, git, xcode, approval registry
- `nonisolated struct/enum` for pure logic (testable off the main actor)
- Tool pattern: `struct X: Tool` with arguments + execute
- Profile pattern: `DynamicProfile` for orchestrator/standalone/delegate
- RepositoryMap: scan Swift declarations → cache → map per model

## Product Direction

Treat `PRODUCT.md` as the contract. Preserve safety and reviewability while minimizing latency and context. Follow Apple's macOS Human Interface Guidelines with native, accessible SwiftUI or AppKit conventions. Avoid desktop automation, broad multi-language IDE features, and unrestricted shell behavior.

## Build, Test, and Development Commands

- `open TurboCode.xcodeproj` opens the project in Xcode. Select the `TurboCode` scheme to run the app.
- `xcodebuild -project TurboCode.xcodeproj -scheme TurboCode -configuration Debug build` builds the debug app and resolves Swift packages.
- `xcodebuild test -project TurboCode.xcodeproj -scheme TurboCodeEvaluations -destination 'platform=macOS'` runs the evaluation and unit-test target.
- `git diff --check` detects whitespace errors before a commit.

The project requires macOS 27, Xcode 27, and Swift 6.

## Workflow: Approval & Planning

Follow this sequence for any refactor, new feature, or non-trivial change:

1. **Read the targetted surface** (repomap + relevant declarations only).
2. **Present a short plan**: files to touch, changes, why, and any build/test impact.
3. **Wait for approval before editing.**
4. **Implement in small, reviewable increments**; after each, summarize what changed.
5. **Ask before any Git mutation** or any command with side effects (builds that fail, deletions, etc.).

## Coding Style & Naming Conventions

Follow Swift API design: four-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for methods, properties, and enum cases. Match filenames to their primary type, such as `SessionSearchViewModel.swift`. Prefer focused SwiftUI views and keep workspace, Git, Xcode, and provider behavior behind existing service/tool boundaries. Use `@MainActor` for UI-owned mutable state and preserve explicit concurrency annotations. No separate formatter or linter is configured; use Xcode formatting and keep warnings clean.

## Code Comments & Documentation

Every code change must add or update comments that make the modified behavior easy to review and maintain. Document the intent behind non-obvious logic, invariants, provider-specific workarounds, concurrency or safety constraints, and important tradeoffs. Keep public types and APIs documented with concise Swift documentation comments where their purpose is not already self-evident. When behavior changes, update nearby comments so they remain accurate. Prefer comments that explain why the code exists and what must remain true; avoid comments that merely repeat the syntax or narrate an obvious statement.

## Testing Guidelines

Tests use Apple's Swift Testing framework (`import Testing`), with descriptive `@Suite` and `@Test` labels and `#expect` assertions. Name test methods by observable behavior, for example `recentSessionsAreLimitedAndOrdered()`. Add focused coverage in `TurboCodeEvaluations/` for changed logic; update golden evaluations only when intended agent behavior changes. Run the shared evaluation scheme before opening a pull request.

## Commit & Pull Request Guidelines

History uses short, imperative subjects such as `Add native session search` and `Fix DeepSeek edit argument parsing`. Keep commits scoped to one coherent change. Pull requests should explain the user-visible outcome, note build/test results, link relevant issues, and include screenshots for SwiftUI changes. Call out changes to entitlements, signing, model configuration, or persisted data.

## Security & Configuration

Never commit credentials or local `~/.turbocode` data. Store API keys in macOS Keychain, and document configuration changes in `CONFIGURATION.md`. Preserve workspace path validation, revision checks, and confirmation gates around destructive Git or shell operations.
