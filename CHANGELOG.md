# Changelog

All notable changes to TurboCode are documented in this file.

The project follows Semantic Versioning while its public API and persisted
formats continue to evolve before 1.0.

## [0.4.0] - 2026-08-24

TurboCode 0.4.0 makes the app feel less like a closed workspace and more like a
real local coding environment. Bash can run the command the task requires; the
extra gate appears only when the command reaches outside the active workspace.
TypeScript plugins are now practical to build, install, and extend, including
by asking the model to create one. Smaller local models also have fewer
artificial rules to work around, so they have more room to find a useful path
through the task.

### Features

- Bash is no longer shaped by a model-facing list of permitted commands or
  extra path restrictions. It can be used as a normal command line for the
  task at hand. When a command leaves the active workspace, TurboCode shows the
  user what is about to run and waits for approval before continuing.
- The same approval boundary now covers tool access to files outside the
  workspace. TurboCode can read, edit, copy, move, or otherwise operate on
  local paths after the user approves the exact operation; the tool layer, not
  the model, owns the boundary and checks the target again before execution.
- Added a small TypeScript plugin workflow. A plugin is a normal Node project
  with a manifest and TypeScript tools: the user can write one, or ask the
  model to create the project, add a tool, build it, and reload it into the
  session.
- Added the `@granvalenti/turbocode-sdk` with session access, cancellation,
  tool definitions, and custom response widgets. The SDK ships with complete
  examples for session search, local planning, HTTP lookup, echo tools, and a
  status-card widget under
  `~/.turbocode/sdk/@granvalenti/turbocode-sdk/examples/`.
- Added automatic plugin discovery, profile activation, build validation,
  atomic installation, `/reload`, process timeouts, cancellation, and crash
  recovery. A failed build leaves the previously working plugin untouched.
- Plugin tools can now return custom cards/widgets in the conversation, while
  the main view shows a small activity entry for every tool call, even when a
  tool has no dedicated native presentation.
- Native and Codex sessions now share the same runtime lifecycle for turns,
  tools, approvals, cancellation, and completion. This keeps the interface
  responsive and prevents late results from an old request from appearing in a
  newer conversation state.
- Introduced `TurboCodeCore`, the provider- and UI-neutral core behind the
  application. It now gives turns, tool results, structured widgets,
  cancellation, and session persistence one shared ownership boundary instead
  of leaving them spread across SwiftUI stores. Existing JSON sessions remain
  compatible; the core is currently an in-app extraction boundary, not yet a
  public Swift package.

### Fixes

- Removed coordinator-authored path scopes, per-tool allowlists, callback gates,
  and other artificial model-facing choreography that could trap a model in
  loops or produce false `path_outside_scope` errors. Safety now comes from the
  host approval, review, revision, and destructive-operation flows instead of
  from extra instructions that limit the model's choices.
- Aligned the SDK README, TypeScript signatures, generated runtime package,
  examples, and Swift host contract. A plugin author now sees the same tool
  and widget API in the documentation, compiler surface, and running app.
- Fixed plugin reloads so updating a valid plugin refreshes its tools without
  throwing away the current conversation. Plugin process failures and slow
  requests no longer block the chat runtime indefinitely.
- Fixed widget results that did not include props: declaring a widget is enough
  for TurboCode to preserve and render it.
- Fixed the built-in profiles so they do not automatically load the oversized
  `turbocode` documentation skill. User-created skills are still available,
  and an explicit profile override can enable it when needed.

### Safari MCP

- Safari MCP was already introduced in 0.3.3, so it is not a new 0.4.0 feature.
  It remains available as an experimental, coordinator-only integration. It is
  disabled by default and can be enabled from **Settings > Agents >
  Experimental**; when it is off, TurboCode does not register the capability.

## [0.3.3] - 2026-08-21

This release improves the backend used by TurboCode's Local LLM profile,
especially the Llama integration. The goal is simple: a native SwiftUI harness
should remain responsive and useful with capable local models, including on
Macs with 16 GB of RAM. The work also puts clearer boundaries around model
capabilities and optional tools, laying the groundwork for a more modular
architecture in future releases without changing the current user workflow.

### Features

- Llama responses now show reasoning updates while the model is working and
  report useful runtime details such as response time, generated tokens, and
  context usage.
- Added manual context compaction for local Llama sessions. Compaction reduces
  older transcript content when the model is running out of room and records a
  visible event so the conversation remains understandable.
- Added a Llama-only context ring to the composer. It is updated after a turn
  completes and shows the used/total context values when hovered; other
  profiles keep their existing footer.
- Llama now reads its server URL from `models.json` when the session is first
  created, so custom hosts and ports work consistently from the start.
- Reasoning updates are tied to the active model request and grouped when they
  arrive in quick bursts. This keeps an old request from writing into a new
  transcript and avoids unnecessary UI work.
- Added optional Safari browsing through MCP. It is disabled by default because
  MCP tools, especially web browsing, can add a large amount of text to the
  context; a few turns can reach roughly 25k tokens. Enable it from
  `Settings > Agents > Experimental` when using a model with fast token
  generation, so the extra tool work does not make the interaction feel slow.

### Fixes

- The Changes Inspector now refreshes workspace diffs when it opens, so it
  reflects the current repository state.
- Chat text no longer shows through the macOS window toolbar or the top scroll
  edge. The fix keeps the existing workbench layout and sidebar alignment
  intact.

## [0.3.2] - 2026-08-13

### RELEASE

- Added an integrated project terminal directly inside the workbench.
- Added syntax-aware inline code review with review comments and draft
  management.
- Redesigned the Changes Inspector with improved diff presentation and code
  review workflows.
- Added visible activity states for file reads and ripgrep searches.
- Replaced the legacy `grep` tool with the bounded `ripgrep` tool.
- Refined Markdown presentation across chat messages, including typography
  and code rendering.
- Stabilized Llama prompt caching and model-switch behavior with regression
  coverage.

### FIX

- Improved scrolling while reviewing change patches.
- Simplified workspace listing guidance and its result presentation.
- Simplified the tool surface and bounded file reads to keep tool usage more
  predictable and safer.

## [0.3.1] - 2026-08-12

> **Compatibility warning:** This version works only with macOS 27 beta 5.
> For earlier macOS 27 beta versions, use TurboCode 0.3.0.

### Fixed

- Restored Xcode 27 beta 5 builds by temporarily using a documented local copy
  of Apple Foundation Models Utilities without the removed
  `Transcript.Segment.custom` case.
- Hardened ChatStore and profile transitions, including safer dynamic-profile
  restoration, capability validation, and regression coverage for profile
  changes.
- Restricted ChatStoreFacade mutations to their owning stores, keeping domain
  projections read-only while preserving the UI state that the facade owns.
- Hardened `file_system` mutations by blocking workspace-root changes, using
  suspending approvals for delete and move, revalidating targets before
  execution, and making file search lazy with accurate result truncation.

## [0.3.0] - 2026-08-10

### Added

- Workspace-local skill authoring through `create_skill`, including discovery
  of TurboCode skills and Codex `.agents/skills` entries.
- `delegate_task` as an explicit capability for custom profiles, including
  on-device overrides, with a configured worker and progressive disclosure of
  delegation settings. The built-in On-device profile remains direct.
- Codex as a selectable model for custom profiles, including its model and
  reasoning configuration.
- `/documentation` as an application-owned command that opens the native
  TurboCode documentation widget without requiring a model tool call.
- `/task <instructions>` as an application-owned command that runs the
  configured independent coding worker and writes its result into the current
  conversation.
- Per-override worker tool selection with an **All tools** default and an
  explicit empty selection for text-only workers.
- Versioned TurboCode tool-call documentation covering the available tools,
  profile availability, delegation behavior, and safety boundaries.

### Improved

- Custom profiles now use one model selection and one capability list. Adding
  `delegate_task` enables orchestration without a separate Direct Model versus
  Coordinator → Worker execution mode.
- Delegated work now has a small provider-facing contract: the coordinator
  supplies a goal and chooses `coding` or `text`. Coding workers receive the
  tool bundle configured by the active profile; text workers receive no session
  tools and return prose.
- Worker activity identifiers, runtime bookkeeping, workspace boundaries,
  review, approval, cancellation, and verification remain owned by TurboCode
  rather than being authored by the coordinator model.
- Delegation envelopes use schema version 2 with backward decoding for schema
  version 1, and the Foundation Models and Codex adapters share the same
  coding/text contract.
- On-device context is compacted before the ninth user turn for the on-device
  model and its overrides. The transcript keeps a concise handoff, shows a
  native compaction notice, and records the event in On-Device Statistics.
- Worker tool configuration is progressively disclosed beside the worker
  picker, grouped by category, and kept independent from coordinator tools.
- Local commands use the existing timeline, persistence, activity, and
  cancellation paths, so they remain useful even when the corresponding
  model-facing capability is excluded from the active override.
- Profile, skill, routing, and delegation evaluations were expanded to cover
  the new capability and compatibility rules.

### Fixed

- Removed coordinator-authored path scopes, per-tool allowlists, and callback
  gates that caused provider loops and false `path_outside_scope` failures.
- Simplified the worker runner so coding and text tasks follow the same runtime
  path without fragile model-facing capability bookkeeping.

## [0.2.0] - 2026-08-01

### Added

- Structured coordinator-to-worker task envelopes with bounded tools,
  verification, cancellation, recovery, and revision-aware results.
- Native Activity inspection for coordinator, worker, tool, verification, and
  terminal task state.
- Coordinator routes for Codex, DeepSeek, and Llama, with configurable Apple
  PCC, Llama, and DeepSeek workers.
- Codex coordinator routes with Luna, Terra, and Sol model selection,
  configurable reasoning, and TurboCode tool bridging.
- On-device file reading and workspace `AGENTS.md` instruction discovery.
- Progressive disclosure for workspace file listings and conversation history.
- A native AppKit Inspector with responsive resizing and improved workspace
  navigation.

### Improved

- Reorganized the sidebar so conversations are grouped inside their workspace.
- Workspace removal from the sidebar no longer removes the underlying
  directory.
- The sidebar initially shows the five most recent sessions, with the
  remaining sessions available through **More**.
- Refined chat typography and Markdown rendering with SF Pro for prose and
  SF Mono for inline and fenced code.
- Improved paragraph spacing, headings, lists, blockquotes, code blocks, and
  progressive disclosure in the main conversation view.
- Refined `@Generable` data widgets, dark-mode sidebar materials, and
  workspace listing presentation.
- Broadened the coordinator-to-worker workflow so delegation can be automatic
  or explicitly requested, with visible progress and verification results.
- Configuration and dynamic profiles migrate compatibly from the 0.1.0
  schema.

### Fixed

- Provider credentials are no longer read from the Keychain during startup;
  they are accessed only when the provider is used or its settings are opened.
- Hardened configuration migration and profile restoration from 0.1.0.
- Improved consistency between sidebar, workspace, and Inspector navigation.
- Corrected workspace listing disclosure and Inspector presentation.
- Corrected the sidebar appearance in dark mode.
- Restored the native macOS window-title layout and reduced resize-related
  Inspector glitches.

### Backend notes

- Apple PCC currently does not expose OpenAI-compatible tool calls correctly
  through `fm serve`. PCC tool calling is deferred until Apple stabilizes the
  protocol; PCC remains fast and suitable for medium-complexity tasks within
  its approximately 32K context window.

### Distribution

- An ad-hoc signed binary is available for users who want to try TurboCode
  without building it from Xcode.
- Because the binary is not notarized by Apple, Gatekeeper may require manual
  approval before the application can be opened.

### Release direction

- This alpha establishes TurboCode's core priorities: a clean user experience,
  low-latency interaction, local-model support, and transparent orchestration
  across models with different capabilities.

## [0.1.0] - 2026-07-29

Initial public preview.

### Added

- Native Codex profile backed by the official Codex App Server, including
  ChatGPT sign-in, model and reasoning selection, TurboCode tool bridging,
  approvals, token usage, and context handoff.
- On-device model statistics for latency, tokens, tool calls, and outcomes.
- Workspace `AGENTS.md` instruction discovery for repository-specific guidance.
- Structured Git status widget for staged, modified, and untracked files.
- Unified Swift Package Manager tool for package initialization, dependency
  management, resolution, updates, builds, tests, runs, cleanup, and inspection.
- Session Summary App Shortcut powered by the Apple on-device model.

### Improved

- Split the former monolithic chat store into focused conversation, workspace,
  timeline, runtime, review, and tool-interaction domains with regression tests.
- Refined remote-model guidance and product-scope instructions.
- Stabilized DeepSeek prompt-cache prefixes and added cache diagnostics.
- Expanded deterministic coverage for first launch, Codex, Swift Package
  Manager, Git presentation, workspace instructions, and chat architecture.

### Fixed

- Apply-edits patches now support workspace paths containing spaces.

### Notes

- TurboCode 0.1.0 targets macOS 27, Xcode 27, and Swift 6.
- Golden model evaluations remain experimental signals and are not release
  gates for this preview.
