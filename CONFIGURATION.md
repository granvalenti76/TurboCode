# TurboCode Configuration

TurboCode keeps application data under `~/.turbocode/`. Agent behavior and
execution tuning live in `~/.turbocode/config.json`.

The file is created during onboarding with validated defaults. Common active
options are also available in **TurboCode > Settings > Agents**.

## Configuration Boundaries

- `config.json` controls agent, execution, skill, and Git policies.
- `models.json` defines model endpoints and capabilities.
- API keys and other secrets belong in the macOS Keychain.
- `SKILLS/**/SKILL.md` contains reusable on-demand instructions.

Never place credentials in a TurboCode JSON file.

## Schema Version 1

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
  "schemaVersion": 1,
  "skills": {
    "discoversUserSkills": true
  }
}
```

## Agent

`responseStyle` accepts `concise`, `balanced`, or `detailed`. It changes the
response guidance supplied to every model.

`verifiesChanges` tells the agent to run the most focused available build or test
after changing source code. It does not bypass execution permissions.

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
validation error. Correct the file and choose **Reload Configuration**.

Settings writes use atomic replacement. Manual changes are loaded on app launch
or when **Reload Configuration** is selected.
