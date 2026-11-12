# Changelog

All notable changes to TurboCode are documented in this file.

The project follows Semantic Versioning while its public API and persisted
formats continue to evolve before 1.0.

## [0.65] - 2026-11-12

TurboCode 0.65 sets itself up on first launch, lets you follow and steer a
working model without interrupting it, gives Studio bundled skills for pages,
documents, and decks, and introduces a calmer visual language.

### Features

- Added a first-launch setup. It looks for a model server on the Mac
  (llama-server, LM Studio, Ollama, vLLM, Jan) or at an address you type for
  another machine, reads the context window and vision support from
  llama-server, checks tool calls in the background, and writes
  `~/.turbocode/models.json` only when you choose **Create and Start**.
  Servers other than llama-server ask for a context window.
- Asking how the work is going while a model is busy no longer reaches that
  model. The on-device model recognises a short progress question and
  answers it in a card above the composer from the live reasoning, text, and
  tool calls. Anything uncertain is queued as steering, and the card offers
  **Send to Model**.
- Steering sent during a turn now reaches native models between tool rounds
  instead of waiting for the turn to end. **Send Now** still interrupts.
  Codex and the on-device model keep end-of-turn delivery.
- The Transcript sheet has a **Live** view that shows tool calls while they
  stream, with their arguments split into fields, a warning after three
  identical calls in a row, and a **Stop Turn** button. It covers every
  chat-completions backend.
- The model is told the current date in the first message of a conversation
  and again when the day changes. Codex already receives it from its runtime.
- Studio sessions offer three bundled skills, loaded only when needed:
  `studio-web-design` for pages and HTML reports, `studio-documents` for
  printable documents, and `studio-presentations` for slide decks. Documents
  and decks are written as HTML and printed to PDF with the VM's Chromium. A
  user skill with the same name replaces the bundled one.
- Studio sessions have their own prompt principles: work from what was
  observed, answer in the chat when that is enough, and look at a deliverable
  before calling it finished.
- The Artifacts library shows one card per session, with the session's main
  file as thumbnail and every other file in the detail view. HTML artifacts
  are rendered for their thumbnails, so dark pages and single-page apps no
  longer appear as blank rectangles.
- The Coding composer names the active workspace beside the branch, or offers
  **Choose workspace…** when none is selected. In Studio the shared-folder
  menu moved from the toolbar into the composer as **Share a folder**, and
  **Review & Export** appears as a tinted button only while files are
  waiting.
- New visual language: a terracotta accent colour, serif display titles for
  empty states and page headers, shared surface tokens for the canvas,
  composer, and cards, and a choice between a translucent and a solid sidebar
  under **Settings → General → Appearance**.
- Sidebar chat titles wrap to two lines and show the full title as a tooltip.
  Studio lists ten chats before **Show More**, and the Coding section is
  called **Workspaces**.
- The steering queue is part of the composer, with compact rows and a header
  that says when queued messages will be delivered.

### Fixes

- Switching conversations quickly could save one conversation with another's
  blocks or rebuild the sessions out of order. Context changes now run one
  at a time.
- A send refused by the runtime vanished together with the draft. It is now
  reported and the text returns to the composer.
- Pressing Return twice while steering was being submitted queued the same
  message twice.
- A delegation to an unknown worker ended the turn and could print the
  coordinator's system prompt and skills into the chat. It now returns a
  readable refusal that lists the valid workers, and tool failures report
  only the tool name and reason.
- The app showed two **View** menus; its commands now join the system one.
- The Artifacts library drops its **Reload** button and refreshes after an
  export review as well as after each turn.

### Interventions

- On first launch `models.json` is no longer written with a default llama
  entry. Until setup completes the app uses the same in-memory defaults as
  before, and an existing catalog is never overwritten.
- The date note is added only to the model-facing text of a user message, so
  the system prompt and its cached prefix are unchanged and visible messages
  are not rewritten.
- The persisted steering delivery intent gains a `toolBoundary` case.
- HTML thumbnails are rendered in a web view that is never shown, one page at
  a time, with the same outbox-limited file access as the preview. Results
  are cached in memory only.
- Studio prompt changes apply only to Studio sessions; Coding prompts are
  unchanged. The **Verify source changes** setting now governs Coding
  sessions only.
- The sidebar backdrop is a new persisted preference; translucent stays the
  default. An accent colour chosen in System Settings still takes precedence.
- The README has new screenshots and describes the first-launch setup, the
  on-device model's role, and the current release.
- New sources used by the `turbocode-acp` target are listed explicitly in
  `project.pbxproj`.
- Updated the application marketing version to 0.65.

## [0.64] - 2026-11-10

TurboCode 0.64 turns Cowork into Studio: a home view that says what the mode is
for, an Artifacts library with live previews of servers running in the VM,
image viewing inside the VM, and built-in connectors that let one session work
with another app on the Mac.

### Features

- Cowork is now called **Studio** in the sidebar switch, Settings, the composer
  badge, error messages, and the documentation. Existing sessions open
  unchanged.
- A new Studio session opens on a home view with four capability cards and up
  to three recent artifacts. A card writes a starter into the composer without
  replacing text already typed, and an artifact opens the session that made
  it. The home view never starts the VM.
- Studio models with vision can look at images inside the VM with the new
  `vm_view_image` tool, so they can check a screenshot they rendered or a
  picture they downloaded. PNG, JPEG, GIF, and WebP files up to 10 MB are
  accepted.
- Studio has an Artifacts library. The sidebar item opens a grid of the files
  each session placed in `/out`, with thumbnails and a full-size preview, and
  a toolbar button shows the active session's artifacts in the inspector
  beside the chat. Previews only read the session outbox; copying to the Mac
  still goes through Review & Export.
- The Artifacts inspector shows servers the agent left running in the VM as a
  live page, ahead of files. A server must listen on `0.0.0.0` on a port from
  1024 up to be reachable from the Mac. Opening the inspector never boots or
  restarts the VM.
- The inspector keeps one thin toolbar, a thumbnail strip, and the selected
  preview per session. It can expand over the chat without disturbing the
  session, reopens when you return from the library, and the library's detail
  offers **Show in Session**.
- Added built-in connectors. A connector lets a session use a named app's own
  MCP operations on `127.0.0.1`; it is enabled per session from the new
  **Connectors** page or the Studio home, and is off by default. Studio
  sessions may use connectors as well.
- Prassitele is the first connector. Its images reach models with vision, and
  it offers the `prassitele-sculpting` skill; a user skill of the same name
  takes precedence.

### Fixes

- The Studio prompt no longer tells the model to stop every server it starts;
  it points the user to the Artifacts panel and keeps pages worth saving in
  `/out`.

### Interventions

- Sessions store their enabled connectors in a new optional field. Older
  session files decode unchanged.
- Enabling a connector for a session is the consent for its calls; they are
  not approved one by one. Delegated workers and Codex never receive the
  `connector` gateway. Safari keeps its global switch and stays Coding-only.
- Images viewed with `vm_view_image` are dropped from tool output when a
  session is rebuilt.
- Source identifiers, the persisted `cowork` session domain, and the `vm_*`
  tool names keep the Cowork name; renaming them would need a session
  migration.
- The `turbocode-acp` target lists the new connector sources explicitly in
  `project.pbxproj`.
- Updated the application marketing version to 0.64.

## [0.63] - 2026-11-08

TurboCode 0.63 lets local models see images dropped on the main view, removes
the time limits that interrupted slow local models, and hardens how sessions are
saved, restored, and recovered.

### Features

- Added image input for Llama-server and Apple on-device models. Dropping PNG,
  JPEG, HEIC, WebP, GIF, or TIFF files on the main view adds thumbnails to the
  composer, up to four images of at most 20 MB each.
- When the active model has no vision support, a dropped image shows a brief
  notice instead of being added. Support is read from the new `supportsVision`
  key or, when it is absent, from the running llama-server. Other backends do
  not accept images.
- Image input also works in Cowork sessions. The image reaches only the model
  and is not copied into the VM.
- Sent images appear as thumbnails in the conversation.

### Fixes

- Removed the time limit from model requests. Slow local models no longer fail
  with "The request timed out." after a minute of silence during normal work.
- Removed the 300-second limit from delegated and powerful-model workers, which
  could cancel a slow local model in the middle of correct work. Stop still
  cancels both requests and workers at once.
- One unreadable session file no longer empties the sidebar. Unreadable files
  are reported and never moved or rewritten, and an undecodable provider
  transcript no longer makes a conversation impossible to open.
- A background result arriving during a title, pin, or rename update is no
  longer lost.
- An unreadable session is no longer overwritten by an empty timeline after the
  active chat is deleted, and opening one now reports the problem.
- Switching threads during a save can no longer write one conversation's content
  into another's file.
- Deleting the active chat now opens the next chat in sidebar order within the
  same mode, skipping archived chats, so the sidebar no longer flips between
  Coding and Cowork.
- Resuming a failed steering request, or one left over from an earlier launch,
  now sends it instead of doing nothing.
- Steering requests no longer follow you into a new session or get saved into
  it. They stay with their own conversation and return when it is reopened.
  Requests already copied into a session must be removed by hand.
- Interrupting a turn no longer leaves tool calls without output in the history,
  which OpenAI-compatible servers rejected on the next request.
- Sessions written by a newer TurboCode are no longer decoded and rewritten with
  data loss; they are treated as unreadable and protected from writes.
- Appending a background result to a session without a file now reports an error
  instead of dropping the result while claiming success.
- Cowork sessions no longer rebuild the provider session on every send, which
  added latency and cleared the composer's context statistics.
- Large patches can no longer hang an edit once their output fills the pipe
  buffer.
- Servers that repeat tool-call ids and names in every stream chunk no longer
  produce corrupted values such as `call_xcall_x`.

### Interventions

- `models.json` entries gain an optional `supportsVision` key. Existing files
  decode unchanged; see `CONFIGURATION.md`.
- Image bytes are never written to disk. Stored sessions keep only an
  `[Image: name]` marker in the message text, and a rebuilt session replaces
  earlier images with a text placeholder.
- A provider host that disappears without closing its connection now waits until
  Stop, for both requests and workers.
- The vendored `foundation-models-utilities` package carries a tool-call delta
  patch, documented in its `README-TurboCode.md`.
- Updated the application marketing version to 0.63.

## [0.62]

TurboCode 0.62 introduces Cowork, a multi-purpose mode that runs builds,
scripts, documents, and web artifacts inside an isolated Linux virtual machine.
Coding remains unchanged: Cowork is a peer mode, activated once from Settings,
and its results reach the Mac only through a reviewed export.

### Features

- Added Cowork, backed by one persistent Debian 12 VM managed through Apple
  Containerization 0.49.0 with Node.js 24, Python 3.11, headless Chromium, and
  common command-line tools. The guest boots in about 0.4 seconds.
- Added **Settings › Cowork** to enable Cowork, install and verify the pinned
  guest with staged, cancellable progress, choose processors, memory, and
  network access, reset the VM, and remove Cowork.
- Added the **Coding | Cowork** switch to the sidebar. Sessions are created in
  the selected mode, lists never mix modes, and each session keeps its mode.
- Added per-session shared folders, mounted read-only at `/work` from a
  toolbar menu.
- Added the `vm_exec`, `vm_file`, and `vm_export` tools. Cowork sessions
  receive only these tools plus the product guide and Markdown skills.
- Added **Review & Export**: a per-file review of the session's `/out` folder
  with Skip, Replace, and Keep Both decisions, text diffs for conflicts, and a
  composer shortcut that appears when deliverables are waiting.
- Cowork file writes appear in the chat with the existing diff widget, without
  Undo or Git actions.
- Added a Cowork page to the built-in product guide.

### Safety

- Cowork commands never fall back to the Mac shell. Codex, which executes on
  the Mac, is not available in Cowork sessions.
- The VM sees only the shared folder (read-only) and its own outbox; sharing
  the disk root or home folder is refused.
- Exports re-verify every file before copying, never follow symbolic links,
  exclude build folders, report files that changed after review, strip execute
  permission, and set the macOS quarantine attribute.
- The guest kernel, image, and init filesystem are pinned by digest and the
  kernel is verified by SHA-256 before installation.

### Interventions

- Added the `com.apple.security.virtualization` entitlement to the app target
  and linked `apple/containerization` pinned to exactly 0.49.0. The ACP helper
  does not link Containerization.
- Session files gain optional `domain` and `coworkFolder` keys; diff receipts
  gain an optional `location`. Older sessions decode unchanged.
- The guest image is built and published by
  [TurboCode-Cowork-Image](https://github.com/granvalenti76/TurboCode-Cowork-Image).
- Updated the application marketing version to 0.62.

## [0.61]

TurboCode 0.61 introduces AnchorSignal dynamic routing for local models. It
selects a bounded tool package for each request with a small on-device semantic
model, while keeping profile permissions authoritative and avoiding unnecessary
session rebuilds when the selected tools remain unchanged.

### Features

- Added AnchorSignal semantic routing for Apple on-device and supported local
  Llama conversations. Requests are matched against compact tool categories by
  cosine similarity, with a minimum similarity of `0.772` and the active
  profile's allowlist retained as the capability boundary.
- Added Profile and Auto tool-selection modes to the composer. A compact,
  transient routing receipt reports the selected package and tool count without
  occupying the inspector, and detailed status remains available from the
  adjacent package control.
- Added bounded tool packages for implementation, workspace inspection,
  search, Git, Xcode, guidance, and conversation workflows. The Conversation
  package can list the workspace and read or edit files when the active profile
  permits those capabilities.
- Added Dynamic Routing controls under Settings > Agents. TurboCode downloads
  the pinned AnchorSignal model archive, verifies its size and SHA-256 digest,
  installs it atomically under the TurboCode model directory, and prepares the
  device specialization through CoreAI's managed model cache.
- Added installation and readiness gating so Auto routing becomes available
  only after the model files and CoreAI specialization pass validation,
  including a real embedding smoke test.

### Fixes

- Fixed ACP client MCP setup and shutdown so standard environment entries are
  parsed correctly, failed setup cannot leave child processes running, slow
  requests do not block unrelated responses, and provider or permission work
  cannot outlive session shutdown.
- Kept composer layout stable when switching providers and now hides dynamic
  routing controls with a short native transition for unsupported DeepSeek and
  Codex conversations.
- Removed the permanent AnchorSignal inspector and obsolete Metal animation,
  which made the short routing step visually dominant.
- Standardized routing diagnostics on cosine similarity and kept the visible
  fallback threshold synchronized with the configured value.

### Interventions

- Centralized the Apple development-team setting at the project configuration
  level so application and helper targets inherit the same signing identity.
- Updated the application marketing version to 0.61.

## [0.6.0]

TurboCode 0.6 expands the application into a more connected desktop agent
surface. It adds Xcode MCP and ACP integration, richer workspace inspection
and review, clearer profile routing, and stronger lifecycle and safety
boundaries across native and headless sessions.

### Features

- Added a built-in Codex profile with explicit profile tool overrides. Codex
  capabilities are derived from its bridge, and server sessions rebuild when
  their selected tools change.
- Added configured profile workers for native and Codex delegation, including
  worker destinations, role guidance, independent capacity, and support for up
  to four concurrent workers.
- Added opt-in Xcode MCP integration with stdio JSON-RPC transport, paginated
  tool discovery, rich result preservation, and the `xcode_mcp` gateway for
  Foundation Models and Codex sessions.
- Added an ACP protocol boundary and a headless `turbocode-acp` helper for
  initialization, sessions, prompts, updates, cancellation, and negotiated
  permissions. The helper is embedded in the application bundle and reuses
  the shared runtime instead of introducing a second execution loop.
- Added session-local client MCP server discovery and tool routing for ACP
  sessions, while keeping approvals and provider ownership inside the host
  runtime.
- Unified `SKILL.md` selection across prompts, tools, slash activation, and
  Codex handoffs while keeping on-demand MCP integrations in their separate
  catalog.
- Added a desktop-blended translucent sidebar that preserves native
  activation, appearance, and accessibility behavior.
- Added bounded in-place previews for workspace Markdown and source files,
  persistent selection, partial reads, Swift syntax highlighting, and compact
  Editorial Desk identity markers.
- Added workspace-file review with line-scoped comments, comment re-anchoring,
  document-language prompts, and separation from Git diff comments.
- Added destination-specific composer profile and reasoning selection together
  with session-scoped `Context`, `Cache hit`, and `Session tokens` statistics
  backed by optional persistence.

### Fixes

- Fixed Bash approval detection when filesystem denials were hidden by
  redirects, truncated output, or a successful final shell command. Approval
  retries now rerun the complete command, while process groups and inherited
  children are cleaned up before replay.
- Fixed ACP session lifecycle and model caching by retaining one provider
  runtime per session, rebuilding only when the selected model changes, and
  serializing persistent stdio input.
- Fixed ACP permission and cancellation handling so rejected requests fail
  closed and cancelled tool updates remain valid ACP states.
- Fixed transcript duplication after stopping an interrupted turn by excluding
  profile-owned instructions from the portable history delta.
- Fixed plugin guidance so model-facing instructions point to the installed
  SDK package and its actual examples.

### Interventions

- Refined the shared system prompt around role, collaboration, follow-through,
  and delegation. Llama profiles now search through Bash with `rg`, while
  profiles with the dedicated capability continue to use it directly.
- Updated the Xcode project metadata, package integration, ACP helper setup,
  bundle configuration, and external model configuration guidance to match
  the new integration surfaces.
- Documented the boundary between the public `dev` branch and the private
  commercial CyberDeck package, including the intentional public teaser.

## [0.5.0] - Unreleased

TurboCode 0.5 focuses on controllable agent workflows: steering an active
turn, delegating work asynchronously, inspecting context and agent activity,
and making custom profiles easier to configure. The release also strengthens
the runtime boundary between providers, tools, receipts, and the UI.

### Features

- Added a runtime-owned steering queue and composer workflow so users can
  redirect, correct, or narrow an active turn without losing its context.
- Added opt-in asynchronous delegation for `/task` and `delegate_task`, with
  independently configured worker slots, profile capacity, terminal results,
  and typed tool receipts delivered back to the originating conversation.
- Redesigned custom profiles as a native Profiles / Agent Team / Inspector
  workspace, including configurable subagent workers and concurrent activity
  inspection.
- Added transcript context projection controls with semantic entries,
  approximate token sizing, and reversible exclusion of complete tool
  exchanges from future model requests.
- Added local reasoning prompt policy support and refined the remote reasoning
  and assistant prompt contract.
- Added an animated, Metal-backed cyberdeck-style agent activity inspector and
  restored native workbench toolbar proportions.
- Added TypeScript plugin observatory examples for dependency and repository
  inspection workflows.
- Strengthened the provider-neutral runtime with executor-independent streaming
  publication, typed tool receipt contracts, runtime-gated artifacts, and a
  dedicated application composition boundary.

### Fixes

- Fixed worker reasoning and assistant wire payloads so streamed and completed
  responses preserve the expected provider contract.
- Fixed local reasoning policy consistency across runtime paths.
- Preserved interrupted turns correctly while steering an active conversation.
- Fixed toolbar click-through behavior and multiline composer return-key
  handling.
- Prevented tool artifacts from bypassing the runtime ownership and receipt
  boundary during publication.

## [0.4.0] - 2026-08-30

TurboCode 0.4 turns the application into a broader native agent harness. The
release combines a shared runtime for native and Codex sessions, a controlled
TypeScript extension system, a more direct workspace and Git workflow, and a
larger set of native macOS surfaces for inspecting and managing work.

### Runtime and model workflows

- Added `TurboCodeCore`, the provider- and UI-neutral runtime boundary behind
  the application. Turns, tool results, structured widgets, cancellation, and
  session persistence now share one ownership model while existing JSON
  sessions remain compatible.
- Native and Codex sessions now share the same lifecycle for turns, tools,
  approvals, cancellation, and completion. Late results from an old request
  cannot be projected into a newer conversation state.
- Moved provider session ownership and lifecycle coordination behind runtime
  actors and backend adapters without changing the visible conversation flow.
- Added runtime diagnostics and baseline measurements for turn admission,
  provider execution, tool work, settlement, persistence, restore, and UI
  publication.
- Kept the model-facing workflow compact: profiles expose only the tools they
  need, while users can explicitly override those selections when a broader
  harness is required.

### Tools, workspaces, and safety

- Bash can run the command required by the task. When a command or file
  operation leaves the active workspace, TurboCode shows the exact operation
  and waits for explicit approval before continuing.
- The same host-owned boundary now covers reading, editing, copying, moving,
  and other file operations outside the workspace. Targets are validated again
  before execution.
- Removed unnecessary model-facing gates and coordinator-authored path scopes
  that could trap models in loops or produce false `path_outside_scope`
  failures. Safety remains enforced by the host approval, review, revision,
  timeout, and destructive-operation flows.
- Reduced the default profile tool surface, including optional guide and file
  search/removal capabilities. Explicit profile overrides can still enable the
  capabilities a user needs.
- Structured tool activity now appears in the conversation even when a tool
  has no dedicated native presentation. Tool results can render diffs, Git
  status, diagnostics, file listings, and custom widgets.

### TypeScript plugins

- Added the `@granvalenti/turbocode-sdk` with session access, cancellation,
  typed tool definitions, and custom response widgets.
- The SDK is bundled with the application and installed during onboarding at
  `~/.turbocode/sdk/@granvalenti/turbocode-sdk/`, together with complete
  examples for session search, local planning, HTTP lookup, echo tools, and
  widgets.
- Added automatic plugin discovery, profile activation, build validation,
  atomic installation, `/reload`, process timeouts, cancellation, and crash
  recovery. A failed build leaves the previous working plugin untouched.
- Plugin processes remain separate Node.js processes. TurboCode retains
  ownership of registration, workspace access, approvals, lifecycle, and
  presentation; plugins receive value-based session snapshots rather than
  access to application internals or provider credentials.
- Aligned the SDK documentation, TypeScript signatures, generated runtime
  package, examples, and Swift host contract.

### Editorial Desk

- Added an isolated Editorial Desk for writing and reviewing Markdown drafts.
- Drafts support titles, subtitles, sections, types, publication dates, and
  workspace-backed persistence.
- Added ground-truth source import, source selection, provenance tracking,
  editorial findings, proposed revisions, and review sidecars.
- Added controlled publication of validated drafts into the active workspace,
  with collision-safe filenames and recoverable metadata.
- Added draft discovery from workspace listings and a native editor/inspector
  workflow for writing, source management, review, and publication.

### Session and sidebar experience

- Added immediate animated deletion for workspace rows. Removing a workspace
  from TurboCode removes its metadata and associated sessions from the app but
  does not delete the underlying workspace directory.
- Kept workspace-bound sessions inside their workspace and reserved the global
  **Chats** section for sessions without a workspace.
- Added compact circular swipe actions for deleting and sharing workspaces and
  individual chats.
- Added native transcript sharing: a single transcript can be sent to Notes or
  saved as a JSON file, while multiple transcripts can be exported as a ZIP.
- Chat deletion removes the corresponding session from disk as well as from the
  sidebar.
- Refined the native macOS toolbar, action icons, hover behavior, and compact
  workspace/session presentation.

### Provider and compatibility changes

- Retired Apple Private Cloud Compute as a selectable default route. Legacy PCC
  records remain readable only through the migration compatibility path.
- Preserved support for Apple on-device models, local OpenAI-compatible Llama
  servers, OpenAI Codex through the official CLI App Server, and DeepSeek API.
- The 0.4 development line requires the latest macOS 27 beta, Xcode 27 beta,
  Swift 6, and Node.js 24 or later when TypeScript plugins are used.

### Experimental capabilities

- Safari MCP remains an optional, coordinator-only integration. It is disabled
  by default and can be enabled from **Settings > Agents > Experimental**.
- On-device orchestration can delegate complex work to a configured worker
  model while keeping the local model as the user-facing coordinator.
- Automatic conversation titles make restored sessions easier to scan.

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
