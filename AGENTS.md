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

## Resuming Work in a New Session

When continuing an in-progress release or refactor, begin with a targeted
handoff check before editing:

1. Read `git status --short`, the current branch, the latest commits, and the
   unstaged diff. Treat existing changes as intentional until their ownership
   is clear; do not discard or reset them.
2. Read the relevant milestone sections in `TODO.md` and `FUTURE.md`, then
   inspect only the declarations and tests touched by the next slice. Keep
   `TODO.md` updates limited to the active release scope.
3. Treat the 0.3.7 runtime/UI execution boundary at commit `a99e3e5` as the
   completed code checkpoint. The remaining release gate is the fresh PCC
   measurement recorded in `TODO.md`; do not invent another runtime refactor
   or move that work into the product/UX scope of 0.4.0.
4. Keep provider configuration external. `~/.turbocode/models.json` is the
   ground truth for endpoint and model selection; never modify it as part of
   tests, never hardcode a model name into production or evaluation code, and
   do not use the aesthetic model name as a session-behavior assertion. Record
   only the provider/backend needed to explain a diagnostic result.
5. If a real interactive validation is required, ask the user to run the app
   or Xcode session and capture the resulting diagnostics; do not substitute a
   synthetic model configuration for that validation.

Every coherent slice should leave a recoverable checkpoint: focused tests,
`git diff --check`, and a commit message that states the problem, the design
decision, and the verification performed. This makes the repository itself the
handoff record when conversational context is unavailable.

## Coding Style & Naming Conventions

Follow Swift API design: four-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for methods, properties, and enum cases. Match filenames to their primary type, such as `SessionSearchViewModel.swift`. Prefer focused SwiftUI views and keep workspace, Git, Xcode, and provider behavior behind existing service/tool boundaries. Use `@MainActor` for UI-owned mutable state and preserve explicit concurrency annotations. No separate formatter or linter is configured; use Xcode formatting and keep warnings clean.

`ChatStore` is the established application facade for SwiftUI views and
UI-facing view models. Its broad use by the UI is intentional and must not be
treated as a defect based only on file size or reference count. Keep executable
tools and low-level services independent from `ChatStore`; route them through
narrow stores, services, coordinators, or output ports. Refactor the facade only
when ownership, coupling, or testability measurably improves.

## Code Comments & Documentation

Comments are part of the implementation deliverable, not optional polish. Every code change must add or update the nearby comment when the modified behavior has non-obvious intent, an invariant, a provider-specific workaround, a concurrency or safety constraint, or an important tradeoff. Before finishing, inspect the diff and explicitly check that the changed behavior is explainable to the next maintainer without reconstructing the entire investigation. Keep public types and APIs documented with concise Swift documentation comments where their purpose is not already self-evident. When behavior changes, update nearby comments so they remain accurate. Prefer comments that explain why the code exists and what must remain true; avoid comments that merely repeat the syntax or narrate an obvious statement.

## Testing Guidelines

Tests use Apple's Swift Testing framework (`import Testing`), with descriptive
`@Suite` and `@Test` labels and `#expect` assertions. Name test methods by
observable behavior, for example `recentSessionsAreLimitedAndOrdered()`. Add
focused coverage in `TurboCodeEvaluations/` for changed logic; update golden
evaluations only when intended agent behavior changes.

During implementation, run only the focused suites that exercise the files,
contracts, or behavior changed by the current slice. Do not run the complete
evaluation scheme after every slice. Run it only when the user explicitly asks
for it or at an explicitly approved final release/pull-request gate. Pure
documentation changes do not require a test run unless they alter generated or
validated documentation behavior.

## Commit & Pull Request Guidelines

Use a short, imperative subject, but do not confuse a concise subject with an incomplete commit. Every feature, fix, refactor, or architectural slice must have a meaningful commit body that records the problem or observed symptom, the relevant context or investigation, the chosen solution and its boundary, and the verification performed. A useful shape is:

```text
Fix runtime contract documentation tests

The custom-profile test expected an implicitly added capability even though
explicit selections are authoritative. The tools guide also omitted the
experimental Safari capability from the searchable reference.

Keep explicit custom-profile boundaries and document the opt-in capability.
Focused evaluation tests pass; the provider runtime is unchanged.
```

Keep each commit scoped to one coherent, reviewable change; "substantial" means complete context and rationale, not unrelated files or artificial size. Subject-only commits are reserved for genuinely trivial mechanical changes. Before committing, review the staged diff, run `git diff --check`, and include relevant test/build results in the body. Pull requests should explain the user-visible outcome, note build/test results, link relevant issues, and include screenshots for SwiftUI changes. Call out changes to entitlements, signing, model configuration, or persisted data.

## Security & Configuration

Never commit credentials or local `~/.turbocode` data. Store API keys in macOS Keychain, and document configuration changes in `CONFIGURATION.md`. Preserve workspace path validation, revision checks, and confirmation gates around destructive Git or shell operations.
