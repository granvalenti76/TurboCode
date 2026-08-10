# Changelog

All notable changes to TurboCode are documented in this file.

The project follows Semantic Versioning while its public API and persisted
formats continue to evolve before 1.0.

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
