# TurboCode Product Contract

## Product Definition

TurboCode is a native macOS agentic development environment dedicated to Swift
and SwiftUI. It helps people understand, modify, build, test, run, and manage
Git-backed Xcode projects and Swift packages from one focused workspace.

TurboCode is not a general-purpose chatbot with coding tools. It is a specialist
workbench whose interface, tools, skills, and model routing are designed for the
Apple development workflow.

## Intended Users

TurboCode is for developers who work primarily in Swift and SwiftUI and want an
agent that can complete real repository tasks without replacing the native macOS
workflow with a browser-based IDE.

It must remain useful to both experienced Apple-platform developers and people
who are learning Swift, without hiding consequential actions or requiring users
to understand the capabilities of each underlying model.

## Core Promise

Within a selected workspace, TurboCode must be able to carry a task through the
complete engineering loop:

1. Inspect the project and understand the relevant code.
2. Make precise, reviewable file changes.
3. Build and test with the selected Xcode toolchain.
4. Interpret compiler and test diagnostics.
5. Inspect and manage the Git repository.
6. Present the result, failures, and recoverable next actions clearly.

The user should not have to move to Terminal merely because the agent cannot
write a build artifact, update Git metadata, or invoke a standard Swift tool.

## Supported Domain

TurboCode's primary domain is:

- Swift source code and Swift macros.
- SwiftUI applications and components.
- Native macOS application development.
- Xcode projects and workspaces.
- Swift Package Manager packages and dependencies.
- Swift Testing and XCTest.
- Apple SDK discovery and command-line tools through `xcrun`.
- Local Git workflows and repository review.
- Project documentation, configuration, and resources that belong to a Swift
  project.

Support for additional Apple platforms can build on this foundation, but must
not dilute the quality of the macOS, Swift, and SwiftUI experience.

## Explicit Non-Goals

TurboCode is not intended to become:

- A general desktop automation agent.
- A replacement for Finder, Terminal, or Xcode in unrelated workflows.
- A broad multi-language IDE.
- A generic web research assistant.
- A cloud account, sync, or deployment platform.
- An unrestricted shell that executes opaque commands without workspace context.

Requests outside the supported domain should receive a concise boundary
explanation. TurboCode may still handle ordinary repository-adjacent work, such
as editing Markdown or configuration files, when it directly supports a Swift
project task.

## Product Principles

### Native macOS Experience

TurboCode follows current macOS interaction conventions and uses native SwiftUI
or AppKit behavior for windows, sidebars, toolbars, menus, settings, keyboard
navigation, focus, accessibility, feedback, and destructive confirmations.

The interface must feel like a focused developer tool. It must not expose model
protocol details, raw transport errors, or configuration complexity during normal
work.

### Speed Is End-to-End

Speed means more than token generation. TurboCode must minimize the time between
intent and a verified result by using:

- Immediate streaming and real cancellation.
- Stable prompt prefixes that preserve provider cache reuse.
- Compact structured tool results.
- On-demand skill loading.
- Model-appropriate tool schemas.
- Incremental inspection, builds, tests, and diagnostics where possible.
- No unnecessary confirmation dialogs for reversible operations.

### Robustness Before Model Cleverness

Correctness must come from deterministic services around the model:

- Workspace-bound path resolution.
- Revision-bound edits.
- Atomic multi-file transactions.
- Patch validation before writes.
- Structured compiler, test, and Git results.
- Explicit timeout, cancellation, retry, and recovery states.
- Review and Undo for source changes.

Models decide what to do. TurboCode services guarantee how operations are
validated and executed.

### Context Is a Product Resource

Completed tool-call exchanges are discarded for Apple, PCC, Llama, and
orchestrator profiles after their useful result has been incorporated. Skills
are advertised compactly and loaded only when needed.

Provider protocols may require a transport exception. DeepSeek thinking, for
example, requires replaying reasoning and tool turns. Such exceptions must be
isolated in the provider adapter and must not weaken the general context policy.

### Git Must Be Complete

Git is part of the core workflow, not a read-only inspector. The product contract
includes structured support for status, diff, history, branches, staging,
commits, merges, rebases, remotes, pull, and push.

Normal reversible operations should run directly. TurboCode asks for confirmation
only when an operation can unexpectedly discard work, rewrite shared history, or
publish consequential remote changes. Git mutations must provide visible status
and recovery information.

### Capability Adapts to the Model

TurboCode presents one coherent product even when inference comes from different
backends:

- Apple on-device provides immediate lightweight assistance and orchestration.
- Apple PCC provides fast larger-context assistance when available.
- A local OpenAI-compatible model provides private, user-controlled inference.
- Optional premium providers handle demanding coding and advanced tool use.

Smaller models receive flat, constrained tools. Capable models may receive
multi-file edit, patch, refactoring, and advanced Git tools. The user's project
semantics and safety guarantees remain the same across backends.

## Configuration Contract

TurboCode must work with useful defaults. Common, infrequently changed options
belong in the native macOS Settings window. Advanced tuning belongs in a
versioned, validated file under `~/.turbocode/` and must never contain secrets.
The schema and active fields are documented in `CONFIGURATION.md`.

Credentials are stored in the macOS Keychain. Configuration files may contain a
credential reference, but never the credential value.

Invalid configuration must not be silently overwritten. TurboCode should retain
the user's file, explain the validation failure, and offer a recoverable action.

## Release Boundary

A release satisfies this contract only when its visible controls work and its
supported workflows can be completed without undocumented escape hatches.
Placeholder destinations and controls must be implemented, clearly marked as
unavailable, or hidden.

The first public release does not need every planned Git, build, or refactoring
operation, but it must describe omissions honestly and must complete its declared
MVP workflows reliably on a clean supported macOS account.

## Decision Test

When evaluating a feature, ask:

1. Does it make Swift or SwiftUI development on macOS faster or more reliable?
2. Does it complete an existing workflow instead of adding a disconnected mode?
3. Can it be expressed with native macOS interaction and accessible feedback?
4. Can deterministic code enforce its safety and correctness?
5. Does it protect context, latency, and provider cache stability?

If most answers are no, the feature is outside TurboCode's product scope.
