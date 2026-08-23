# @granvalenti/turbocode-sdk

SDK for TurboCode TypeScript plugins. It requires Node 24 or newer and does not
depend on React. A plugin is a normal Node program: it can use npm packages,
the filesystem, network access, and child processes. TurboCode-specific
objects are not injected into Node; the stable APIs cross the JSON-RPC host
boundary.

## Create a plugin in a workspace

Create a regular Node/npm project wherever the active workspace calls for it.
Keep `plugin.json` at the project root, place the TypeScript entrypoint under
`src/`, and compile the runtime to the path declared by the manifest:

```text
my-plugin/
├── package.json
├── plugin.json
├── tsconfig.json
├── src/index.ts
└── dist/index.js
```

The plugin can be shaped freely: add the tools, schemas, session APIs, widgets,
packages, and frontend files that fit the product you are building. Use the
installed SDK package `@granvalenti/turbocode-sdk` in the project dependencies.
When Bash runs inside TurboCode, it discovers the supported Node runtime and
provides `TURBOCODE_SDK_PACKAGE` for npm and `TURBOCODE_PLUGIN_ROOT` for the
discovery root. The shell resolves the package path before npm stores it, so the
same commands work across machines:

```sh
npm install --save "file:$TURBOCODE_SDK_PACKAGE"
npm exec -- tsc --noEmit
npm run build
mkdir -p "$TURBOCODE_PLUGIN_ROOT/<plugin-id>"
cp plugin.json package.json "$TURBOCODE_PLUGIN_ROOT/<plugin-id>/"
cp -R dist "$TURBOCODE_PLUGIN_ROOT/<plugin-id>/"
```

After copying the built runtime, inspect the installed files and reload
TurboCode. Enable third-party plugins in Settings → Agents for the profile that
should use the plugin. A TypeScript plugin contributes executable tools and
optional widgets; a skill contributes reusable instructions. They can live in
the same workspace with their own layouts.

## Minimal plugin

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

## Session transcript

The tool context exposes a typed, read-only snapshot of the active session:

```ts
async handler(_arguments, context) {
  const transcript = await context.session.transcript();
  return transcript?.entries.at(-1)?.text ?? "No active session.";
}
```

The snapshot includes `sessionID`, `title`, `updatedAt`, and timeline entries
with `id`, `kind`, `text`, `createdAt`, `model`, and `providerID`. A plugin can
read it while its tool is running; the host takes a value snapshot and never
hands out a mutable session or `ChatStore` reference.

## Custom widgets

Plugins may declare their own HTML/JavaScript surfaces. TurboCode creates a
WebView only when a tool returns a widget invocation; ordinary tool results
remain text-only.

```ts
const widget = defineWidget({
  id: "dashboard",
  title: "Project Dashboard",
  entrypoint: "dist/dashboard.html",
});

const plugin = definePlugin({
  id: "project-tools",
  name: "Project Tools",
  version: "0.1.0",
  widgets: [widget],
  tools: [
    defineTool({
      name: "openDashboard",
      description: "Open the project dashboard.",
      inputSchema: { type: "object", properties: {}, required: [] },
      async handler() {
        return {
          text: "Dashboard ready.",
          widget: { id: widget.id, props: { theme: "dark" } },
        };
      },
    }),
  ],
});
```

The widget owns its HTML, CSS, JavaScript, framework, layout, and local state.
The host exposes `window.turbocode.emit(...)`, `resize(...)`, and the
`turbocode-props` event. An action such as
`window.turbocode.emit({ type: "action", action: "pulse" })` receives a
`turbocode-host-event` acknowledgement with the action, acceptance, and receipt
time; the widget remains responsible for rendering the result. A widget cannot
access Swift, SwiftUI, `ChatStore`, or provider sessions.

## Installing a plugin

Build the project and install the resulting directory at:

```text
~/.turbocode/plugins/<plugin-id>/
```

That directory contains `plugin.json`, the compiled entrypoint, and the
plugin's normal `package.json`/`node_modules` when it has dependencies. A
reload discovers metadata without starting Node. Activation starts one lazy
Node process for the selected plugin.

## Robustness boundary

The host owns JSONL framing, protocol/version checks, Node version checks,
timeouts, process termination, and malformed-response handling. These are
runtime integrity guarantees, not a capability allowlist. The plugin remains
an ordinary Node process and is responsible for its own application-level
permissions and error handling.

See `examples/` for three usable plugins: session search, a local planning
file, and an HTTP-backed lookup.
