# TypeScript plugins

TurboCode installs TypeScript plugins under one canonical root:

```text
~/.turbocode/plugins/<plugin-id>/
```

Each plugin is a normal Node/npm project with a `plugin.json`, a compiled
entrypoint, and any dependencies it owns. The current runtime contract is
Node 24.x and JSON-RPC 2.0 over JSONL on stdin/stdout. TurboCode starts Node
lazily when the plugin is activated; `/reload` only rediscovers metadata.

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
  "runtime": { "kind": "node", "node": "24.x" },
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

This slice provides the import/build service and its focused coverage. Provider
profile selection and native Enable/Cancel confirmation remain the next
integration boundary; `/reload` will consume the installed registry once that
boundary is wired.
