# TypeScript plugins

TurboCode installs TypeScript plugins under one canonical root:

```text
~/.turbocode/plugins/<plugin-id>/
```

Each plugin is a normal Node/npm project with a `plugin.json`, a compiled
entrypoint, and any dependencies it owns. The current runtime contract is
Node 24 or newer and JSON-RPC 2.0 over JSONL on stdin/stdout. `/reload`
restarts active plugin processes, rediscovers manifests, and refreshes the
current session's tool snapshot without discarding the visible conversation.

## Create and install a plugin

Start with any Node/npm project in the active workspace. A practical project
layout is:

```text
my-plugin/
├── package.json
├── plugin.json
├── tsconfig.json
├── src/index.ts
└── dist/index.js
```

Use `@granvalenti/turbocode-sdk` from the installed SDK, define the plugin and
its tools/widgets in TypeScript, and set `entrypoint` in `plugin.json` to the
compiled runtime file. The manifest stays at the project root so TurboCode can
discover it directly.

When the project is opened in TurboCode, Bash discovers Node and exposes the SDK
and plugin locations as environment variables. They keep the workflow portable
across machines:

```sh
npm install --save "file:$TURBOCODE_SDK_PACKAGE"
npm exec -- tsc --noEmit
npm run build
mkdir -p "$TURBOCODE_PLUGIN_ROOT/<plugin-id>"
cp plugin.json package.json "$TURBOCODE_PLUGIN_ROOT/<plugin-id>/"
cp -R dist "$TURBOCODE_PLUGIN_ROOT/<plugin-id>/"
```

Copy the runtime files needed by the plugin, inspect the installed manifest and
entrypoint, then use `/reload`. TurboCode discovers metadata first and starts
the Node process when one of the plugin's tools is used. In Settings → Agents,
enable third-party plugins for the profile that should expose them. The SDK
package root is available as `TURBOCODE_SDK_ROOT`, the ready-to-use npm package
as `TURBOCODE_SDK_PACKAGE`, and the plugin installation location as
`TURBOCODE_PLUGIN_ROOT`.

Skills and TypeScript plugins are both useful extension mechanisms: a skill is
instructional content, while a TypeScript plugin contributes executable tools
and optional widgets. They have different project layouts and can coexist.

## Runtime model

The plugin is a full Node process. It may use npm packages, the filesystem,
network APIs, and child processes. The host boundary is for runtime integrity:
it validates the manifest and handshake, frames JSONL, bounds messages,
enforces request timeouts, and shuts down a crashed process. It is not a
capability allowlist or an OS security sandbox.

TurboCode does not pass Swift, SwiftUI, `ChatStore`, or provider-session
objects into Node. Host APIs are explicit and value-based. The first session
API is:

```ts
const transcript = await context.session.transcript();
```

It returns a read-only snapshot of the active session, including timeline
entries with their kind, text, timestamps, model, and provider identifiers.
The snapshot is available to Codex and native sessions because it is based on
the provider-neutral conversation timeline, not on Foundation Models' private
transcript type.

## Manifest

```json
{
  "manifestVersion": 1,
  "id": "session-search",
  "name": "Session Search",
  "version": "0.1.0",
  "entrypoint": "dist/index.js",
  "runtime": { "kind": "node", "node": ">=24.0.0" },
  "tools": [
    {
      "name": "findInSession",
      "description": "Find text in the active session.",
      "inputSchema": {
        "type": "object",
        "properties": { "query": { "type": "string" } },
        "required": ["query"]
      }
    }
  ]
}
```

The host preserves the declared JSON Schema. A provider adapter may support a
smaller representation, but a rich schema does not prevent the Node plugin
from activating or serving another provider.

## Real examples

The SDK directory contains complete tool implementations:

- `TypeScriptSDK/examples/session-search.ts` searches previous conversation
  entries through `context.session.transcript()`.
- `TypeScriptSDK/examples/local-planner.ts` writes a Markdown plan using
  `node:fs/promises` and `node:path`.
- `TypeScriptSDK/examples/http-lookup.ts` calls an HTTP JSON endpoint with
  the tool cancellation signal.

See `TypeScriptSDK/README.md` for build/install notes and the complete SDK
surface.

## Custom response widgets

A plugin can provide a fully custom HTML/JavaScript widget instead of using a
TurboCode-native presentation. Declare the widget in the SDK definition and
return its id from a tool. TurboCode creates a lazy WebKit surface inside the
response only for that result; it does not create a global WebView for the
application.

The widget entrypoint is loaded from the installed plugin directory and may
contain any bundled frontend code. The host injects a small bridge:

```js
window.turbocode.emit({ type: "action", action: "refresh" });
window.turbocode.resize(420);
window.addEventListener("turbocode-props", (event) => render(event.detail));
window.addEventListener("turbocode-host-event", (event) => {
  // event.detail contains type, action, accepted, and receivedAt.
});
```

This is a UI surface, not a SwiftUI extension point. The plugin owns its DOM,
CSS, JavaScript, framework, interactions, and local state. TurboCode owns the
WebView lifecycle, installed-file boundary, and the explicit host acknowledgement
bridge. `TypeScriptSDK/examples/workspace-observatory/` is the reference demo.

## Project validation and import

TurboCode treats the user project as the source of truth and builds a temporary
copy. The source directory is not rewritten while the build is running. The
project service performs these checks in order:

1. read `package.json` and `plugin.json`;
2. run `npm exec -- tsc --noEmit`;
3. run `npm run build`;
4. run `npm run --if-present lint`;
5. validate the compiled entrypoint and stage `dist/`, package metadata, and
   `node_modules` under the plugin root.

The temporary generation replaces `~/.turbocode/plugins/<plugin-id>/` only
after every step succeeds. A failed validation or build therefore leaves the
previous installed generation untouched. The SDK installer copies only
`package.json` and `dist/` to
`~/.turbocode/sdk/@granvalenti/turbocode-sdk/`, then exposes the same package
inside the build's `node_modules` tree.

The project validation/import service can perform the same build checks and
stage a validated generation atomically. The Bash workflow is useful when the
model is designing a plugin directly in the workspace and wants full control
over its source layout, build scripts, and installation files.
