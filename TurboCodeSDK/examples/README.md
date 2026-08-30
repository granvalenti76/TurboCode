# SDK examples

These examples show the SDK APIs in small, working projects. Read the example
that is closest to the plugin you want to build, then adapt the relevant code
to your own plugin.

## Complete projects

### `echo-tool/`

The smallest complete plugin. It defines one tool with a string argument and
returns a text result.

```sh
cd echo-tool
npm install
npm run build
```

### `status-card/`

A complete tool-plus-widget plugin. The tool receives status data, returns a
widget invocation, and the HTML surface renders the returned props.

```sh
cd status-card
npm install
npm run build
```

### `workspace-observatory/`

A larger example that combines a tool, a widget, widget props, and the active
session transcript.

```sh
cd workspace-observatory
npm install
npm run build
```

### `session-handoff/`

A practical continuity plugin inspired by session handoff and stateful todo
extensions. It saves structured work state, lists and reloads previous
handoffs, and renders a compact Continuity Card with the current step, next
step, risks, files, and transcript metadata.

```sh
cd session-handoff
npm install
npm run build
```

Each complete project contains its own `package.json`, `plugin.json`,
`tsconfig.json`, and source. The manifest points to the compiled runtime and
the widget entrypoint after the project is built.

## Focused API references

These files are short examples of individual SDK capabilities:

- `session-search.ts` reads the active session transcript.
- `local-planner.ts` uses Node filesystem APIs from a tool.
- `http-lookup.ts` uses `fetch` and the tool cancellation signal.

They are useful when a complete project already exists and only one API needs
to be added.
