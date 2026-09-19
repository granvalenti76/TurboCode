# TurboCode Configuration

TurboCode keeps application data under `~/.turbocode/`. Agent behavior and
execution tuning live in `~/.turbocode/config.json`.

The file is created during onboarding with validated defaults. Common active
options are also available in **TurboCode > Settings > Agents**.

## Configuration Boundaries

- `config.json` controls agent, orchestrator, execution, skill, and Git policies.
- `models.json` defines model endpoints and capabilities.
- API keys and other secrets belong in the macOS Keychain.
- `SKILLS/**/SKILL.md` contains legacy user-level reusable instructions.

Never place credentials in a TurboCode JSON file.

## Composer profiles

The composer lists On-device, Codex, Llama, and DeepSeek, followed by custom
profiles. Each default opens a reasoning submenu for that destination; a
provider-managed configuration uses Automatic. Choosing an option selects the
profile and effort together. The retired On-Device Delegation entry is absent;
selecting a profile also exits that mode in older conversations.

In **Profiles > Llama > Display name**, Save updates only the model entry's
`name` in `models.json`. It preserves `id`, `modelName`, endpoint, and capability
settings. The visible name refreshes without rebuilding the conversation.
In **Profiles > Codex > Default model**, choose the direct profile's model;
custom Codex profiles retain their own model configuration.

### Experimental Dynamic routing (Llama and on-device)

Enable **Dynamic** below the composer to start without tools and select a native
tool package before each turn. The adjacent status opens a popover showing the
package, actual session tool names, routing duration, and classifier source.
The active Llama or Apple On-Device column in Tools follows this session snapshot. Custom profile
allowlists still apply; external plugin/MCP catalogs are excluded in this experiment.

The prototype loads `TextEncoder.aimodel` and `tokenizer/tokenizer.json` from a
user-provided external model directory lazily using CoreAI. The model asset is
deliberately not bundled with the repository; provision it separately before
enabling Dynamic routing. No Python conversion is needed at runtime. Missing or
failed assets, and similarity below `0.800`, restore the configured profile’s
default tools, with the reason visible in the popover. Similarity scores are not
confidence probabilities. The first request includes model loading; later
requests reuse the encoder and cached package embeddings. Repeated tool sets
keep the provider session; changed tool definitions can reduce KV-cache reuse.

Semantic routing uses one short description per category and selects the highest
cosine similarity when the score reaches `0.800`. There are no keyword gates or
capability penalties. The encoder's multilingual representations handle the
request language.
Both requests and category descriptions use the `query: ` prefix recommended by
E5 for semantic similarity. The local export accepts 512 tokens, including the
prefix and special tokens, so longer requests are truncated before inference.
Profile permissions and the backend's tool tier still constrain the installed tools.
Dynamic routing is available for standalone Llama and Apple on-device profiles.

To verify bilingual routing against the external encoder (rather than fallback),
run the focused suite with the test-runner environment variable:

```sh
TEST_RUNNER_TURBOCODE_EVALUATE_ANCHORSIGNAL=1 xcodebuild test -project TurboCode.xcodeproj -scheme TurboCodeEvaluations -destination 'platform=macOS' -only-testing:TurboCodeEvaluations/DynamicRoutingTests
```

## Repository map model capability

Each entry in `models.json` may declare the context budget and repository-map
level used by that backend:

```json
{
  "contextWindowTokens": 32768,
  "repositoryMap": "compact"
}
```

`repositoryMap` accepts `none`, `compact`, or `enhanced`. The default Llama and
Apple PCC profiles use `compact` with a conservative 32k context assumption.
DeepSeek uses `enhanced`, which adds imports and type relationships to focused
map queries. Apple on-device never receives the repository-map tool, including
when it is acting as orchestrator; the configured delegate maps the workspace.

## Remote reasoning control

Reasoning ownership is configured explicitly per compatible remote model under
**TurboCode > Settings > Reasoning**. TurboCode never infers the request format
from the model name.

`serverManaged` is the backward-compatible default. It adds no reasoning fields
to the request, leaving behavior to the endpoint's launch and template setup:

```json
{
  "reasoningConfiguration": {
    "mode": "serverManaged"
  }
}
```

`requestTokenBudget` sends the selected budget and thinking switch with each
request. A missing `maximumTokenBudget` means unlimited for the highest product
level:

```json
{
  "reasoningConfiguration": {
    "mode": "requestTokenBudget",
    "lowTokenBudget": 512,
    "mediumTokenBudget": 2048,
    "highTokenBudget": 8192
  }
}
```

Use request-level control only when the endpoint's chat template supports these
fields. Settings validates finite budgets before atomically updating
`models.json`; unrelated endpoint metadata is preserved.

## Xcode build and test execution

Capable standalone and delegated models receive the flat `xcode_project` tool.
It supports project inspection, builds, and tests; Apple on-device does not
receive it. Xcode command arguments are passed directly to `xcrun` without shell
interpolation. Structured results are read with `xcresulttool` and compacted
before they reach the model.

TurboCode leaves DerivedData under Xcode's normal management, so tool calls reuse
the same incremental build state as builds started in the Xcode application.
Individual result bundles are created in temporary storage and removed after
TurboCode extracts diagnostics. Xcode operations use
`execution.maximumCommandTimeoutSeconds`, up to the supported 600-second limit.

## Xcode MCP

`experimental.xcodeMCPEnabled` enables the opt-in `xcode_mcp` gateway. It
connects to the Xcode-provided service through `xcrun mcpbridge` over stdio,
discovers advertised tools with `tools/list`, and forwards calls with
`tools/call`. Xcode must be open on the intended project and **Allow external
agents to use Xcode tools** must be enabled in Xcode Intelligence settings.

The gateway preserves MCP JSON schemas and rich result content, including
`isError`, structured content, images, and resource references. It is separate
from TurboCode's local `xcode_project` wrapper and is never added to delegated
worker profiles.

## Xcode ACP agent

The `TurboCode` app target embeds the native ACP helper at
`TurboCode.app/Contents/Helpers/turbocode-acp`. Register that absolute path in
Xcode's **Add an ACP Agent** screen with the name `TurboCode` and no
interpreter. The helper receives the session workspace from Xcode and keeps
provider configuration in the external `~/.turbocode/models.json` file; the
registration does not accept or store credentials. During `session/new`, the
helper exposes enabled, credential-ready configurations through the ACP
`configOptions` model selector. `session/set_config_option` changes only that
ACP session and is snapshotted when the next turn is admitted; an in-flight
provider operation is never switched underneath. Consecutive turns with the
same selection keep the session and provider cache alive; changing the model
rebuilds only that ACP session before its next turn.

See [ACP_AGENT_SETUP.md](ACP_AGENT_SETUP.md) for the complete registration and
smoke-check procedure.

## Agent Tuning Schema Version 1

```json
{
  "agent": {
    "responseStyle": "balanced",
    "verifiesChanges": true
  },
  "execution": {
    "allowNetworkAccess": true,
    "defaultCommandTimeoutSeconds": 30,
    "maximumCommandTimeoutSeconds": 120,
    "maximumToolOutputCharacters": 12000
  },
  "git": {
    "allowsCommits": true,
    "allowsRemoteWrites": true,
    "confirmsDestructiveOperations": true
  },
  "orchestrator": {
    "delegateModelID": "llama"
  },
  "schemaVersion": 1,
  "skills": {
    "discoversUserSkills": true
  }
}
```

TurboCode also accepts the 0.1.0 form with `schemaVersion: 0`, or without a
schema marker, when all values are valid. Onboarding normalizes that file to
schema version 1. Unknown future schema versions and invalid values are left
untouched so the original file can be corrected or restored.

## Profile Schema Version 2

`profiles.json` stores custom model profiles in a versioned envelope. Version 2
adds the coordinator/worker route fields used by structured delegation while
remaining compatible with version 1 profiles:

```json
{
  "version": 2,
  "profiles": [
    {
      "baseModelID": "codex",
      "workerModelID": "llama",
      "toolIDs": ["delegate_task"]
    }
  ]
}
```

Version 1 profile envelopes remain readable and are upgraded atomically during
onboarding. Missing worker or Codex selections retain their documented
fallback behavior.

## Agent

`responseStyle` accepts `concise`, `balanced`, or `detailed`. `balanced` is the
default and adds no fixed length or depth constraint: the shared personality
adapts the response to the request and its actual complexity. `concise` and
`detailed` remain explicit overrides supplied to every model.

`verifiesChanges` tells the agent to run the most focused available build or test
after changing source code. It does not bypass execution permissions.

## Orchestrator

`delegateModelID` selects the model used by `call_powerful_model` while the Apple
on-device model is running in orchestrator mode. The value must match an enabled
model ID from `~/.turbocode/models.json`, such as `llama`, `apple-pcc`, or
`deepseek`. Models that require credentials must also be configured in the macOS
Keychain. The same option is available under **TurboCode > Settings > Agents**.

If the selected model is missing, disabled, or lacks its required credential,
TurboCode falls back to the first configured local model and then to another
configured enabled model.

## Execution

`defaultCommandTimeoutSeconds` is used when a tool call does not request a
timeout. Valid values are 5 through 600 seconds.

`maximumCommandTimeoutSeconds` caps model-requested timeouts. It must be at least
the default timeout and no greater than 600 seconds.

`maximumToolOutputCharacters` caps combined command output returned to the model.
Valid values are 1,000 through 30,000 characters.

`allowNetworkAccess` controls network access for commands executed by the bounded
runner. It does not affect model-provider connections made by TurboCode itself.

## Skills

`discoversUserSkills` controls automatic discovery of user-created skills. The
built-in `turbocode` and `skill-creator` skills remain available when this option
is disabled.

TurboCode discovers valid `SKILL.md` files from these scopes:

- `~/.turbocode/SKILLS/**/SKILL.md` for legacy user-level skills;
- `~/.agents/skills/**/SKILL.md` for Codex-compatible user skills;
- `.agents/skills/**/SKILL.md` in the active workspace and its parent directories.

Every file starts with YAML front matter containing a lowercase kebab-case
`name` and a non-empty `description`, followed by a non-empty Markdown instruction
body. The model sees the catalog and loads a matching body on demand.
`/skill <name>` and `/<name>` explicitly select one skill for the current request.

The `Skill` type supplied by `foundation-models-utilities` is an internal adapter
for Foundation Models dynamic instructions. It does not discover or parse
`SKILL.md`; disk-backed skills remain TurboCode's provider-neutral product format.

## Git

`allowsCommits`, `allowsRemoteWrites`, and `confirmsDestructiveOperations` define
the policy contract for the structured Git service. The service supports init, status,
diff, history, branches, staging, commits, merge/rebase flows, remotes, fetch,
pull, and push without routing Git through the shell tool.

Commit and remote-write policies are enforced before process launch. Discard,
clean, hard reset, rebase, force-delete, and force-push operations require the
user's approval by default. Git arguments are passed directly to `/usr/bin/git`;
they are never interpolated into a shell command.

## Validation And Recovery

TurboCode decodes missing sections and fields with version-appropriate defaults.
Unknown additional fields are ignored.

TurboCode does not overwrite a malformed file, unsupported future schema, or
configuration containing invalid ranges. The Agents settings pane displays the
validation error together with the affected configuration field. Correct the
file and choose **Reload Configuration**.

Settings writes use atomic replacement. Manual changes are loaded on app launch
or when **Reload Configuration** is selected.
