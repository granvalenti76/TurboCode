# Configure TurboCode as an Xcode ACP agent

TurboCode ships the native `turbocode-acp` helper inside the application
bundle. Build or install the **TurboCode** app target before registering the
agent; building only the command-line target leaves the helper in DerivedData
and is not a stable installation path.

## Add the agent in Xcode

In Xcode's Coding Intelligence settings, choose **Add an ACP Agent** and use:

- **Name:** `TurboCode`
- **Executable:** `/Applications/TurboCode.app/Contents/Helpers/turbocode-acp`
- **Interpreter:** leave empty

Replace `/Applications/TurboCode.app` with the actual location of the installed
app. The executable must be the helper inside the distributed app bundle, not
a path under `DerivedData` or the repository checkout. Xcode starts it over
stdio and supplies the active workspace as `cwd` when it creates an ACP
session.

The helper keeps stdout exclusively for ACP JSON-RPC messages. It does not
require command-line arguments, and it reads the configured provider/model from
the existing external TurboCode configuration. Do not put credentials in the
agent registration fields.

When Xcode creates a session, TurboCode returns an ACP `configOptions` model
selector built from enabled, credential-ready entries in `~/.turbocode/models.json`.
The option value is the stable TurboCode configuration ID; the provider model
name remains internal to the selected execution snapshot. A model change is
session-local and affects the next prompt, so a generation already in progress
cannot be moved to another provider. With the selection unchanged, consecutive
prompts reuse the same provider session and its cache; a rebuild is reserved for
an actual model change.

## First connection check

After saving the agent, open a project in Xcode and send at least three prompts
in the same session. A working registration performs the ACP `initialize`
handshake, creates a session, streams `session/update` messages, and asks Xcode
for permission before an operation that requires approval. Rejection,
cancellation, and provider errors release the active turn so a later prompt
can run. If Xcode renders the model selector, changing it must affect the next
prompt while preserving the session's workspace and transcript.

If Xcode cannot start the agent, verify that the app was rebuilt after an
update and that this path exists:

```shell
test -x /Applications/TurboCode.app/Contents/Helpers/turbocode-acp
```

See Apple's [coding intelligence setup](https://developer.apple.com/documentation/Xcode/setting-up-coding-intelligence)
and [external agent documentation](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents/)
for the Xcode-side settings and lifecycle.
