# What TurboCode Can Do

TurboCode is a native macOS development workbench specialized in Swift, SwiftUI, Xcode projects, and Swift packages. It combines a conversational agent with deterministic project services so that a request can become a reviewable and verified engineering result.

## Understand an existing project

TurboCode can build a compact map of Swift declarations, signatures, documentation comments, and line numbers before reading source code. It then reads focused ranges, searches for symbols and patterns, explains unfamiliar Swift code, and connects implementation details across files. Every file operation remains bounded to the selected workspace.

## Make precise changes

The agent can create and update source files through revision-bound editing operations. TurboCode validates paths and revisions, generates patches internally, groups related edits into a visible change widget, and provides Review and Undo actions.

## Complete the engineering loop

TurboCode can inspect Xcode containers and schemes, run focused builds and tests with the selected Xcode toolchain, and reduce verbose result bundles to actionable file, line, error, warning, and test-failure summaries. It shares Xcode's normal incremental build state instead of creating a separate cold-build cache. TurboCode can also inspect Git changes, work with branches and commits, and summarize what changed. The goal is to complete a workflow without forcing the user to move between a chatbot, Terminal, Finder, and a browser-based IDE.

## Good use cases

- Understand the architecture of an unfamiliar Swift project.
- Implement or refine a SwiftUI feature.
- Diagnose a compiler or test failure.
- Refactor code while keeping changes reviewable.
- Create tests for existing behavior.
- Inspect a working tree and prepare a Git commit.
- Learn Swift through explanations grounded in the current project.

TurboCode is intentionally focused on Apple development. It is not a general desktop automation agent or an unrestricted shell.
