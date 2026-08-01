# Changelog

All notable changes to TurboCode are documented in this file.

The project follows Semantic Versioning while its public API and persisted
formats continue to evolve before 1.0.

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
