# TurboCode Tool Calls

TurboCode gives each model only the tools supported by its runtime profile and
the current workspace. The exact set therefore varies with the selected model,
custom profile, installed skills, configured worker, repository-map support,
and whether a workspace is open. The Tools screen shows the resolved set for
the current configuration.

Custom profile overrides can include compatible tools explicitly. Selecting
`delegate_task` also changes the override into a Coordinator → Worker profile
and requires a configured worker. Llama, DeepSeek, and Codex can act as the
coordinator; Apple PCC, Llama, and DeepSeek can act as workers.

## Product and discovery

### `turbocode_guide`

Searches this official, versioned TurboCode documentation. It is intended for
questions about the product, supported workflows, models, settings, safety, and
available tools; it does not inspect the user's source code.

### `list_workspace`

Lists one workspace-relative directory with structured file metadata and a
native timeline presentation. It is the preferred tool for directory browsing.

### `swift_workspace_map`

Builds or queries a compact map of Swift declarations without reading complete
files. Its `overview`, `symbols`, `related`, and `refresh` actions help models
locate types, functions, signatures, and likely related files while conserving
context. It is available only when the selected profile supports a repository
map.

### `grep`

Searches for text or regular-expression patterns in a workspace file or
directory and returns matching lines with line numbers.

## Reading and changing files

### `read_file`

Reads a focused, numbered UTF-8 range from a workspace file and returns a
revision token. Models use that revision to avoid applying edits to stale file
contents.

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

## Skills and orchestration

### `load_skill`

Loads the instructions of one installed skill on demand. The tool is registered
only when the active profile has access to at least one skill.

### `create_skill`

Creates a reusable Codex-compatible skill under the active workspace's
`.agents/skills` directory. It validates the skill name and content, refuses to
overwrite an existing skill, and presents the created file through Review and
Undo.

### `delegate_task`

Assigns one bounded, typed coding task to the configured worker. The coordinator
must supply stable task and attempt identifiers, an explicit goal and acceptance
criteria, a narrow workspace scope, allowed TurboCode tools, an optional build
or test verification request, a timeout, and a maximum tool-call count. TurboCode
enforces the envelope and returns a structured result; the coordinator remains
responsible for the final user-facing response.

### `call_powerful_model`

Provides the older free-text delegation path used by the experimental
on-device orchestrator. It remains implemented for compatibility, but new
custom coordinator profiles should use the safer, structured `delegate_task`
route.

## Why a tool may be unavailable

A tool can be absent because no workspace is selected, the current model has no
tool-calling support, its tool tier is intentionally constrained, no matching
skill is installed, no worker is configured, or the custom profile did not
include that capability. A tool being implemented by TurboCode does not mean it
is automatically exposed to every model session.
