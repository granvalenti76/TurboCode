# @granvalenti/turbocode-sdk

SDK for TypeScript plugins that run in TurboCode. A plugin is a normal Node.js
program: it defines tools, can optionally expose HTML widgets, and communicates
with TurboCode through the SDK runtime. The SDK requires Node.js 24 or newer
and uses ES modules.

If you want a working starting point, open [`examples/README.md`](examples/README.md)
and choose the smallest example that matches the plugin you are building.

## The plugin shape

A small plugin normally looks like this:

```text
my-plugin/
├── package.json
├── plugin.json
├── tsconfig.json
├── src/index.ts
└── dist/index.js
```

`plugin.json` describes the plugin to TurboCode before Node starts. The
compiled `dist/index.js` is the runtime entrypoint. A widget is an HTML file
declared in the manifest, for example `widget.html` at the project root or
`dist/widget.html` under the compiled output.

## Runtime API

The usual runtime uses four functions:

- `definePlugin` describes the plugin and its tools/widgets.
- `defineTool` describes one callable tool and its JSON Schema.
- `defineWidget` describes one HTML surface.
- `runPlugin` starts the JSON-RPC process owned by TurboCode.

The SDK also exports types and `manifestFor`. `manifestFor` is useful to a
build script that wants to produce `plugin.json`; it is not needed by the
running plugin. Keep the manifest available before TurboCode discovers the
plugin, then let the runtime only define the plugin and call `runPlugin`.

## A tool

This is the smallest useful `src/index.ts`:

```ts
import {
  definePlugin,
  defineTool,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const plugin = definePlugin({
  id: "workspace-helper",
  name: "Workspace Helper",
  version: "0.1.0",
  tools: [
    defineTool({
      name: "echo",
      description: "Echo one string.",
      inputSchema: {
        type: "object",
        properties: { value: { type: "string" } },
        required: ["value"],
        additionalProperties: false,
      },
      async handler(arguments_) {
        return String(arguments_.value ?? "");
      },
    }),
  ],
});

await runPlugin(plugin);
```

The handler receives the decoded tool arguments and a context. It may return a
string or an object such as:

```ts
return { text: "The operation completed." };
```

Set `isError: true` when the result should be presented as an error. The
context also provides an `AbortSignal` and a read-only session transcript:

```ts
async handler(_arguments, context) {
  const transcript = await context.session.transcript();
  return transcript?.entries.at(-1)?.text ?? "No active session.";
}
```

## A widget

Widgets are ordinary HTML/CSS/JavaScript files. Declare one with
`defineWidget`, include it in the plugin, and return its id from a tool:

```ts
const widget = defineWidget({
  id: "status-card",
  title: "Status Card",
  entrypoint: "widget.html",
});

const plugin = definePlugin({
  id: "status-plugin",
  name: "Status Plugin",
  version: "0.1.0",
  widgets: [widget],
  tools: [
    defineTool({
      name: "openStatus",
      description: "Open the status card.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
        additionalProperties: false,
      },
      async handler() {
        return {
          text: "Status card ready.",
          widget: { id: widget.id, props: { state: "ready" } },
        };
      },
    }),
  ],
});
```

TurboCode creates the WebView when a tool result contains a widget invocation.
The widget owns its HTML, CSS, JavaScript, layout, and local state. It can use
the host bridge exposed as `window.turbocode`:

```js
window.turbocode.emit({ type: "ready" });
window.turbocode.emit({ type: "action", action: "refresh" });
window.turbocode.resize({ width: 360, height: 220 });
```

The `turbocode-props` event carries the `props` object returned by the tool.
Widgets do not access Swift, SwiftUI, `ChatStore`, or provider sessions.

## Manifest

Keep `plugin.json` at the plugin root. A minimal manifest is:

```json
{
  "manifestVersion": 1,
  "id": "workspace-helper",
  "name": "Workspace Helper",
  "version": "0.1.0",
  "entrypoint": "dist/index.js",
  "runtime": { "kind": "node", "node": ">=24.0.0" },
  "tools": [
    {
      "name": "echo",
      "description": "Echo one string.",
      "inputSchema": {
        "type": "object",
        "properties": { "value": { "type": "string" } },
        "required": ["value"],
        "additionalProperties": false
      }
    }
  ],
  "widgets": []
}
```

Manifest entrypoints are relative to the installed plugin directory. The
manifest contains metadata only; tool handlers are registered by the compiled
runtime.

## Build and install

Inside a plugin project, the canonical SDK package is always installed at
`~/.turbocode/sdk/@granvalenti/turbocode-sdk`:

```sh
npm install --save "file:$HOME/.turbocode/sdk/@granvalenti/turbocode-sdk"
npm exec -- tsc --noEmit
npm run build
```

Install the resulting project under `~/.turbocode/plugins/<plugin-id>/` with
its `plugin.json`, `package.json`, compiled `dist/`, widget files, and any
runtime dependencies. After installation, reload TurboCode and enable
third-party plugins for the profile that should use it.

The plugin is a regular Node process, so it may use npm packages, the
filesystem, network access, and child processes. TurboCode owns JSONL framing,
protocol checks, timeouts, cancellation, and host-side presentation.

## Examples

The [`examples/`](examples/) directory contains complete projects and focused
single-file references. Start with [`examples/README.md`](examples/README.md),
then open the example source and its manifest/package files together.

All complete projects are intended to build as written. They use the same
SDK APIs shown above and keep their manifest and runtime entrypoint visible so
the relationship is easy to follow.
