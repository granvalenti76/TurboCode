# TurboCode Tool Calls

TurboCode gives each model only the tools supported by its runtime profile and
the current workspace. The exact set therefore varies with the selected model,
custom profile, installed skills, configured worker, repository-map support,
and whether a workspace is open. The Tools screen shows the resolved set for
the current configuration.

Profiles are the only authority that enables runtime tools: every resolved
tool is registered directly. Skills never reveal, hide, activate, or deactivate
tool capabilities; `load_skill` only adds a selected instruction body to the
current task.

Custom profile overrides keep one model selection and one explicit capability
list. Including `delegate_task` is the profile's only orchestration signal: it
enables delegation to the configured worker and progressively reveals the
worker settings in the profile editor. Custom On-device, Llama, DeepSeek, and
Codex profiles can act as coordinators; Apple PCC, Llama, and DeepSeek can act
as workers. The built-in On-device profile remains direct and does not include
the capability by default.

## Product and discovery

### `turbocode_guide`

Searches this official, versioned TurboCode documentation. It is intended for
questions about the product, supported workflows, models, settings, safety, and
available tools; it does not inspect the user's source code.

The composer also provides `/documentation`. This application command opens the
same native guide widget locally, using the overview documentation, so it works
even when a custom profile does not expose `turbocode_guide` to its model.

The composer also provides `/task <instructions>`. This application command
starts one independent coding worker through the configured delegate runtime,
without asking the active model to emit `delegate_task`. The typed worker result
is added to the current conversation and remains available to the next turn.

### `list_workspace`

Lists one workspace-relative directory with structured file metadata and a
native timeline presentation. It is the preferred tool for directory browsing.

### `swift_workspace_map`

Builds or queries a compact map of Swift declarations without reading complete
files. Its `overview`, `symbols`, `related`, and `refresh` actions help models
locate types, functions, signatures, and likely related files while conserving
context. It is available only when the selected profile supports a repository
map.

### `ripgrep`

Uses ripgrep for flexible, read-only workspace exploration. Its `files` action
discovers paths, while `search` finds literal text or regular-expression
patterns with optional path, glob, case, hidden-file, context-line, and
files-only controls. Ripgrep respects repository ignore files by default and
returns workspace-relative evidence without choosing an exploration strategy
for the model. The persisted capability identifier remains `grep` so existing
custom profiles automatically receive the replacement tool.

Ripgrep is an external prerequisite and is not bundled with TurboCode. Install
it with `brew install ripgrep`, then relaunch the app. TurboCode resolves `rg`
from common Homebrew locations or `PATH`; `TURBOCODE_RG_PATH` supports a
nonstandard executable location.

## Reading and changing files

### `read_file`

Reads a focused, numbered UTF-8 range from a workspace file and returns a
revision token. Output is capped by the shared execution policy, stops on a
source-line boundary, estimates its token cost, and reports the exact next
range when more requested lines remain. Models use the revision to avoid
applying edits to stale file contents.

### `edit_file`

Applies one or more revision-bound line edits for Foundation Models-compatible
profiles. It supports creating files, replacing or deleting ranges, inserting
before or after a line, and replacing a complete file. Related changes are
validated atomically and produce Review and Undo receipts.

### `apply_edits`

Provides Codex with the same atomic, revision-bound editing service used by
`edit_file`, using a Codex-compatible multi-file schema. It produces the same
Review and Undo receipts and preserves the same workspace safety checks.

### `write_ondevice`

Uses a deliberately small schema for Apple on-device models to create or
replace one root-level workspace text file. The write still passes through the
normal atomic Review and Undo path.

### `file_system`

Performs bounded workspace file operations. Supported operations are `info`,
`find`, `createDirectory`, `write`, `append`, `copy`, `move`, and `delete`;
`list` remains for compatibility, while `list_workspace` is preferred.
Text writes use the change-review transaction, and permanent deletion requires
approval.

### `remove_file`

Removes one workspace file through an explicit approval request. It is separate
from general editing so destructive intent stays visible and reviewable.

### `safari_mcp`

Controls Safari through TurboCode's experimental Safari MCP integration. It is
available only after enabling Safari MCP in **Agents > Experimental** and while
the current Safari browsing context remains valid. TurboCode keeps the
capability disabled by default, does not register it when the opt-in is off,
and reports lost or unavailable browsing contexts as bounded tool failures.

Safari MCP is a coordinator-only capability. It is never passed to delegated
workers, whose tool surface remains restricted to the configured workspace and
worker profile boundaries.

### `xcode_mcp`

Discovers and calls the tools exposed by Xcode's official MCP service through
`xcrun mcpbridge`. It is disabled by default and requires **Agents >
Experimental > Xcode MCP**, plus Xcode's **Allow external agents to use Xcode
tools** permission. Use `list_tools` first, then `call` with an exact advertised
tool name and a JSON object. This gateway is distinct from `xcode_project`:
the latter is TurboCode's local compact build/test wrapper, while this tool
uses Xcode's live MCP service. It is coordinator-only and is never delegated.

## Build, test, packages, and Git

### `xcode_project`

Inspects Xcode projects or workspaces, builds a scheme, or runs its tests. Its
`inspect`, `build`, and `test` actions invoke the selected Xcode toolchain and
return compact structured diagnostics from the result bundle. It is unavailable
to tool tiers that cannot safely operate Xcode.

### `swift_package_manager`

Manages Swift packages through a structured wrapper. It can `initialize`,
`addDependency`, `addTargetDependency`, `resolve`, `update`, `build`, `test`,
`run`, `clean`, `reset`, `describe`, `showDependencies`, and `dumpPackage`.
Manifest changes are reviewable, while execution, network access, output, and
filesystem writes remain bounded by Agent Settings.

### `git`

Inspects and manages the workspace repository. Supported operations include
`init`, `status`, `diff`, `stagedDiff`, `log`, `branches`, `remotes`, branch
creation and switching, staging and unstaging, commits, `fetch`, `pull`, `push`,
`merge`, `rebase`, abort and recovery operations, discard, clean, reset, and
branch deletion. Destructive operations and history rewrites use the configured
approval gates; remote writes also respect Agent Tuning and network policy.

### `bash`

Runs bounded non-Xcode commands inside the active workspace when no dedicated
structured tool covers the operation. Time, output, network access, and writable
paths follow Agent Settings. TurboCode prefers its Xcode, SwiftPM, Git, search,
and file tools whenever they apply.

## Markdown skills and orchestration

TurboCode's product-level Markdown skills are provider-neutral `SKILL.md`
instruction files. Their name and description form the active profile's session
catalog; their body is loaded only when relevant. A user-created skill belongs at
`.agents/skills/<name>/SKILL.md` in the active workspace. Keep its instructions
self-contained and use clear workspace-relative paths for any supporting project
files.

Foundation on-demand integrations are a separate catalog. In the current
implementation, `/mcp` asks the model to list integrations registered through
Foundation Models' `Skills` mechanism, such as Safari MCP. This internal
implementation detail does not change the Markdown `SKILL.md` format. Plugin
tools and ordinary tools are not members of either catalog.

### `load_skill`

Loads the instructions of one installed skill on demand. The tool is registered
only when the active profile has access to at least one skill. `/skill <name>` and
`/<name>` are explicit host-side selections and do not depend on the model first
choosing the tool itself.

`/skills` lists only the Markdown skills available to the active profile. It does
not list Foundation on-demand integrations, MCP tools, plugin tools, or ordinary
tools. `/mcp` is the model-facing request for the separate Foundation catalog.

### `create_skill`

Creates a reusable Codex-compatible skill under the active workspace's
`.agents/skills` directory. It validates the skill name and content, refuses to
overwrite an existing skill, and presents the created file through Review and
Undo.

### `delegate_task`

Sends one goal to a worker with optional `worker_id` and a coarse execution mode:
`coding` or `text`. Coding workers receive the complete worker tool bundle
configured by the active profile and can use those tools throughout the active
workspace. Text workers receive no session tools and return prose to the
coordinator. TurboCode creates activity identifiers and runtime bookkeeping
internally, keeps each tool's workspace, review, and approval boundaries, and
returns a structured result. The coordinator remains responsible for the final
user-facing response.

The coordinator does not invent per-file scopes, per-tool allowlists, tool-call
budgets, or verification policies during a model turn. Any future granular
worker restrictions must be explicit profile configuration, while the current
contract exposes only the goal, coding/text choice, and optional destination.

Use the exact `worker_id` from the active profile catalog to select a worker
by role and tools. Without it, the harness chooses a free slot. Unknown or busy
targets are reported without substituting another worker. Retry a busy target
after completion, without polling. Background acceptance records the requested
destination; terminal results include the actual worker ID and name. Keep
planning and integration with the coordinator, parallelize independent file
scopes within profile capacity, and run final QA after integration.

### `call_powerful_model`

Provides the older free-text delegation path used by the experimental
on-device orchestrator. It remains implemented for compatibility, but new
custom profiles that include **Delegate Task** should use the safer, structured
route.

## Why a tool may be unavailable

A tool can be absent because no workspace is selected, the current model has no
tool-calling support, its tool tier is intentionally constrained, no matching
skill is installed, no worker is configured, or the custom profile did not
include that capability. A tool being implemented by TurboCode does not mean it
is automatically exposed to every model session.
