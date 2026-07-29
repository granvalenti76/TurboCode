# What TurboCode Can Do

TurboCode is a native macOS agent harness written entirely in Swift and focused exclusively on developing macOS applications with Swift and SwiftUI. Rather than acting as a general-purpose IDE, it gives language models a purpose-built environment for understanding, modifying, building, testing, and reviewing Apple-platform projects.

Its tool set combines general development operations with dedicated integrations for Xcode, Swift Package Manager, and Git. Shell access remains confined by the sandbox and is exposed to language models only through narrowly scoped wrappers. TurboCode also provides a lightweight repository map that helps local models work effectively when their context windows are limited.

TurboCode natively supports Apple's on-device AFM Core 3 Advanced model with an 8K context window, Apple Private Cloud Compute through `fm serve`, Llama models distributed as GGUF files through `llama-server`, Codex with native OpenAI tool calls and TurboCode-specific tools, and DeepSeek.

## Understand an existing project

TurboCode can build a compact map of Swift declarations, signatures, documentation comments, and line numbers before reading source code. It then reads focused ranges, searches for symbols and patterns, explains unfamiliar Swift code, and connects implementation details across files. Every file operation remains bounded to the selected workspace.

## Make precise changes

The agent can create and update source files through revision-bound editing operations. TurboCode validates paths and revisions, generates patches internally, groups related edits into a visible change widget, and provides Review and Undo actions.

## Complete the engineering loop

TurboCode can inspect Xcode containers and schemes, run focused builds and tests with the selected Xcode toolchain, and reduce verbose result bundles to actionable file, line, error, warning, and test-failure summaries. It shares Xcode's normal incremental build state instead of creating a separate cold-build cache. TurboCode can also inspect Git changes, work with branches and commits, and summarize what changed. The goal is to complete a workflow without forcing the user to move between a chatbot, Terminal, Finder, and a browser-based IDE.

For standalone Swift packages, the structured `swift_package_manager` tool
initializes official templates, adds URL, registry, and workspace-relative path
dependencies, updates target dependencies, resolves and updates versions, and
runs build, test, run, cleanup, and inspection actions. Manifest changes use the
same Review/Undo path as source edits. Package execution can write only
`Package.resolved`, `.build`, and `.swiftpm`, while command time, output, and
network access follow Agent Settings.

## Good use cases

- Understand the architecture of an unfamiliar Swift project.
- Implement or refine a SwiftUI feature.
- Diagnose a compiler or test failure.
- Refactor code while keeping changes reviewable.
- Create tests for existing behavior.
- Inspect a working tree and prepare a Git commit.
- Learn Swift through explanations grounded in the current project.

TurboCode is intentionally focused on Apple development. It is not a general desktop automation agent or an unrestricted shell.
