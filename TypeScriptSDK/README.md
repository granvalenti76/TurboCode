# @granvalenti/turbocode-sdk

SDK for TurboCode TypeScript plugins. It targets Node 24.x and does not
depend on React. A plugin is a normal Node program: it can use npm packages,
the filesystem, network access, and child processes. TurboCode-specific
objects are not injected into Node; the stable APIs cross the JSON-RPC host
boundary.

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
