# Repo Observatory — TurboCode 0.5 example

A read-only Git atlas: folder mosaics, file details, staged/unstaged filters,
search, three square sizes and four status colors. No frontend dependencies,
network calls, shell interpolation, file-content reads or Git mutations.

## Try in TurboCode

Install this directory at `~/.turbocode/plugins/repo-observatory`, including
`plugin.json`, `package.json` and `dist/`. TurboCode provisions its SDK dependency
when activating the plugin. Enable third-party plugins for the active profile,
select Repo Observatory if the profile uses explicit plugin selections, then
send `/reload`.

Ask: “Usa repo_observatory sul workspace corrente e mostrami le modifiche.”
The tool requires the absolute workspace path. Example:

```json
{"path":"/absolute/path/to/your/repository"}
```

Call again to refresh. Widget clicks navigate the captured data locally; they
do not execute commands. A browser preview of `dist/widget.html` offers a clearly
labelled “Explore demo data” button before host data arrives.

## Build and tests

From this directory in the SDK repository:

```sh
../../node_modules/.bin/tsc -p tsconfig.json
node build.mjs
npm test
```

For a standalone copy, install TypeScript and Node types plus the SDK package
exposed by TurboCode as TURBOCODE_SDK_PACKAGE:

```sh
npm install --save "file:$TURBOCODE_SDK_PACKAGE"
npm install --save-dev typescript @types/node
npm run build
npm test
```

Tests create disposable fixtures under the OS temporary directory and never
change the user's repository. The build copies the widget into dist.

## How it works

- `src/repository.ts`: bounded Git subprocesses, NUL-delimited status and
  numstat parsing. No external diff drivers or textconv.
- `src/index.ts`: one SDK tool and a widget receipt.
- `widget.html`: self-contained accessible HTML/CSS/JS, keyboard-operable file
  squares, dark mode and Reduce Motion. All repository text uses textContent.
- `plugin.json`: discoverable host metadata; keep it aligned with index.ts.

Line totals sum staged and unstaged edits. They are not the net diff from HEAD:
a staged addition subsequently removed contributes to both counters. Binary
and untracked contents are not counted. Renames appear as deletion + addition.
Submodule status is shown without recursively inspecting its contents.

Square sizes use bands (0–15, 16–100, >100 changed lines), not exact areas.
The mosaic groups every changed file by its next path component. Filters affect
the mosaic; the top counters always summarize the entire snapshot.

A status comparison catches membership/status changes during collection but
is not an atomic filesystem snapshot. Calls have a 10-second timeout per Git
command and a 4 MiB output bound; failures return an explicit tool error.
No tool execution or verification success is inferred from model prose.
