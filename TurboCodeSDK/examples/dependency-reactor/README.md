# Dependency Reactor — TurboCode 0.5

An interactive orbital Swift import atlas. Cyan nodes are source folders;
violet nodes are imported module names. Links are backed by file/line evidence.

## Try

Installed at `~/.turbocode/plugins/dependency-reactor`. Enable third-party
plugins and this plugin in the active profile, then send `/reload`.

Ask: **“Apri Dependency Reactor sul workspace corrente.”**

Tool: `dependency_reactor`, argument `{"path":"/absolute/workspace/path"}`.

- Click a node to illuminate related nodes and open its inspector.
- Double-click, or use **Bring to center**, to re-center the graph.
- Click an inspector connection to view source paths and line numbers.
- Drag to pan; scroll or use +/− to zoom.
- Search highlights matches; Enter centers the first matching node.
- **Isolate links** hides unrelated nodes; **Reset view** restores the scene.
- **Pause motion** stops decoration. Reduce Motion is respected.
- A subtle procedural galaxy sits behind stationary nodes and rings. Only up
  to three link trails animate, including during hover and keyboard inspection.
  Trails pause offscreen, on explicit pause, hidden documents and Reduce Motion.
  Selecting a node preserves its layout; explicit centering/isolation changes
  the layout instantly. No remote image or per-frame JavaScript is used.
  Host resize messages are sent only when height changes.
- Open `dist/widget.html` in a browser and launch the explicitly labelled demo
  to explore the design without source data. Host snapshots never use demo data.

## Build

Inside the SDK repository:

```sh
../../node_modules/.bin/tsc -p tsconfig.json
node build.mjs
npm test
```

In a standalone installed copy, first install the SDK via
`npm install --save "file:$TURBOCODE_SDK_PACKAGE"` and run
`npm install --save-dev typescript @types/node`, then `npm run build`.

The manifest and tool definition in src/index.ts must remain aligned.
Source: src/scan.ts (bounded filesystem scan), src/index.ts (SDK adapter),
widget.html (dependency-free responsive SVG scene).

## What the graph means

This version extracts **Swift import references**, including conditional and
scoped imports. It groups source files by at most two directory levels. Those
groups are not compiler targets. It does not infer symbol references, call
graphs, build order, package resolution or likely breakages. It does not
execute Package.swift. Source locations are lexical evidence, not compiler
verification; uncommon Swift syntax such as regex literals may require a
compiler-backed scanner in a future version.

Up to 2,000 Swift files / 16 MiB of source, 20,000 visited entries and 12
directory levels are scanned; individual files over 512 KiB are skipped.
Hidden paths, symlinks, Vendor, Pods, Carthage, node_modules, build directories
and dist are excluded. Limits/skipped files are reported in the snapshot.
At most 30 evidence locations per edge and 100 visual nodes are displayed.
Search + Enter and isolation make nodes outside the initial display reachable.
The captured data is not an atomic filesystem snapshot; call the tool again
to refresh. Animation indicates selection and is decorative, not live traffic.

No network, Git mutation, shell commands or source-content injection into HTML.
Paths/module labels are assigned with textContent. Tests use OS temporary
directories, including explicit cancellation and symlink exclusion checks.
