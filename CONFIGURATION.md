# TurboCode Configuration

TurboCode keeps application data under `~/.turbocode/`. Agent behavior and
execution tuning live in `~/.turbocode/config.json`.

The file is created during onboarding with validated defaults. Common active
options are also available in **TurboCode > Settings > Agents**.

## Configuration Boundaries

- `config.json` controls agent, orchestrator, execution, skill, and Git policies.
- `models.json` defines model endpoints and capabilities.
- API keys and other secrets belong in the macOS Keychain.
- `SKILLS/**/SKILL.md` contains reusable on-demand instructions.

Never place credentials in a TurboCode JSON file.

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

`responseStyle` accepts `concise`, `balanced`, or `detailed`. It changes the
response guidance supplied to every model.

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
