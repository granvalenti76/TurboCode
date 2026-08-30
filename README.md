<p align="center">
  <img src="turbocode-logo-provisional.png" width="112" alt="TurboCode icon">
</p>

# TurboCode

## Install with Homebrew

To install TurboCode:

```shell
brew install --cask granvalenti76/homebrew-tap/turbocode
```

To update an existing installation:

```shell
brew upgrade --cask turbocode
```

To uninstall TurboCode:

```shell
brew uninstall --cask turbocode
```

> [!IMPORTANT]
> The current TurboCode development line requires the latest available macOS
> 27 beta, Xcode 27 beta, and Swift 6. Earlier macOS versions are not
> supported.

The distributed application is ad-hoc signed and is not notarized by Apple.
If macOS blocks the first launch, approve TurboCode in **System Settings →
Privacy & Security**, or open the application once with **right-click → Open**.

## What is TurboCode?

TurboCode is a native macOS agent harness written entirely in Swift. It
provides a general execution layer for models, tools, profiles, Skills,
plugins, context management, and safety boundaries. It brings these
capabilities together with native integrations for Swift, SwiftUI, Xcode,
Swift Package Manager, Git, and general workspace automation.

The core agent toolchain has no JavaScript or TypeScript runtime. Model
interaction, typed tool calls, routing, context management, workspace access,
and safety boundaries are implemented with SwiftUI, AppKit, and Apple's
Foundation Models framework. Optional TypeScript plugins run separately as
Node.js processes and are not part of the core runtime.

![TurboCode conversation with a Swift composer and a local workspace selected](.github/assets/turbocode-conversation.png)

## Local-first by design

TurboCode is built to make meaningful use of local models, including on
entry-level Macs such as a MacBook Air M4 with 16 GB of RAM. A capable local
MoE model, such as Qwen3.6-35B-A3B, is recommended when the available hardware
can run it comfortably.

Local inference keeps everyday work close to the machine and makes the
workbench useful without sending every request to a remote provider. When a
task needs more capability, the session can use a frontier model through one
of the supported adapters.

TurboCode is designed to remain lightweight: normal idle memory usage is kept
below 100 MB so the app can stay open alongside Xcode, simulators, and other
development tools.

## Supported model backends

TurboCode presents different model runtimes through one workbench. The model
provider changes, but the workspace, transcript, tools, approvals, and review
workflow remain inside TurboCode.

| Backend | Use | Setup |
| --- | --- | --- |
| **Apple on-device** | Local model for short answers and small agentic tasks. | No server or API key required. The available context is approximately 8k tokens. |
| **Local Llama** | Recommended local backend for longer and more capable agentic work. | Run an OpenAI-compatible server such as `llama-server`. |
| **OpenAI Codex** | Frontier model accessed through the official Codex CLI App Server. | Install Codex on the system and complete the first sign-in through the browser. |
| **DeepSeek API** | Remote provider for tasks that need a frontier model. | Add the API key in **Settings → Providers**. It is stored in the macOS Keychain. |

For remote and frontier inference, the current supported adapters are OpenAI
Codex and DeepSeek. Additional third-party adapters may be added in the
future without changing the workspace and tool model.

Apple Private Cloud Compute through `fm serve` remains a legacy compatibility
path. It is not exposed as a selectable default backend.

## How a TurboCode session works

TurboCode keeps the conversation connected to the real development task:

1. You select a workspace and describe an outcome.
2. The active model reads the context allowed by the current profile.
3. Structured tools inspect files, repositories, projects, tests, and
   diagnostics.
4. Changes remain revision-aware and reviewable before they are applied.
5. The resulting transcript, tool activity, and session state can be restored
   later.

The central workflow is **Coordinator → Worker**. A capable model such as
Codex or DeepSeek can plan a task and delegate implementation or subtasks to a
smaller local model. TurboCode tracks the operation, keeps the worker inside
its configured boundaries, and verifies the result before returning it to the
conversation.

## Profiles, tools, and Skills

Each profile contains a minimal system prompt and only the tool calls that are
important for its role. This keeps the model-facing context focused and avoids
turning every profile into an oversized general-purpose agent.

Profiles can be overridden by the user. Examples include:

- a Git-only profile;
- a read-only profile;
- a focused code-review profile;
- a local coordinator profile with an explicitly selected worker.

Profiles can select models, tools, Skills, delegation behavior, and optional
plugin capabilities. Built-in profiles provide useful defaults, while user
overrides remain authoritative. Skills can be stored globally or discovered
from a workspace's `.agents/skills` directory.

<table>
  <tr>
    <td width="50%"><img src=".github/assets/turbocode-custom-profiles.png" alt="TurboCode Custom Profiles editor with tool calls and Skills assigned to a local Llama model"></td>
    <td width="50%"><img src=".github/assets/turbocode-model-picker.png" alt="TurboCode model picker showing built-in and custom profiles"></td>
  </tr>
</table>

## Workspaces, tools, and safety

TurboCode includes native integrations for Swift, SwiftUI, Xcode projects,
Swift Package Manager packages, and general repository workflows. Its
structured tools cover:

- workspace and file inspection;
- compact Swift repository maps;
- revision-aware file editing;
- Xcode and Swift Package Manager builds and tests;
- compiler diagnostics and test results;
- Git status, branches, commits, remotes, and other repository operations.

The interface keeps consequential work visible. File operations outside the
active workspace require explicit approval, and destructive file or Git
operations have their own confirmation boundaries. Generated changes can be
reviewed against the real working tree before publication.

![TurboCode Workspace Files panel showing the contents of a Swift package](.github/assets/turbocode-workspace-files.png)

### Structured conversation output

The transcript is more than a stream of text. TurboCode renders important
results as native views so they can be inspected without losing the
conversation context:

- line-by-line change review;
- grouped Git status;
- file and workspace listings;
- build and test diagnostics;
- tool activity and plugin widgets.

<table>
  <tr>
    <td width="50%"><img src=".github/assets/turbocode-review-changes.png" alt="TurboCode Review Changes sheet showing a line-by-line diff"></td>
    <td width="50%"><img src=".github/assets/turbocode-changes-sidebar.png" alt="TurboCode Changes sidebar showing the diff beside the conversation"></td>
  </tr>
</table>

### Native macOS interface

TurboCode uses SwiftUI and AppKit for its window, sidebar, transcript,
inspector, settings, and workspace interactions. The interface follows native
macOS conventions and Apple's Human Interface Guidelines, with progressive
disclosure so tools and past sessions remain available without taking over the
main conversation.

![TurboCode conversation showing a branch creation and completed Git commit](.github/assets/turbocode-git-commit.png)

### Tools and diagnostics

The **Tools** view makes the active runtime explicit. It shows backend
availability, context requirements, model capabilities, installed Skills, and
on-device latency, token, tool-call, and outcome statistics.

![TurboCode Tools view comparing model profiles and their runtime capabilities](.github/assets/turbocode-tools.png)

## TypeScript plugins

TypeScript plugins are optional extensions for users who want to add typed
tools or custom response widgets. A plugin is a normal Node.js project using
the `@granvalenti/turbocode-sdk`.

TurboCode retains ownership of plugin registration, workspace access,
approvals, timeouts, cancellation, process lifecycle, validation, and
presentation. Plugin processes receive value-based session snapshots; they do
not receive Swift, SwiftUI, application stores, credentials, or provider
sessions.

The SDK is bundled with the app and installed during onboarding at:

```text
~/.turbocode/sdk/@granvalenti/turbocode-sdk/
```

Plugins are validated and installed under:

```text
~/.turbocode/plugins/<plugin-id>/
```

The model can create or modify a plugin in the active workspace, build and
validate it, and reload it with `/reload` without rebuilding TurboCode. Custom
HTML widgets run in a host-owned WebView and cannot replace TurboCode's
navigation or safety controls.

See [TypeScript plugins](TurboCode/Documentation/turbocode-typescript-plugins.md)
and [`TurboCodeSDK/README.md`](TurboCodeSDK/README.md) for the workflow and
SDK reference.

## Configuration

During onboarding TurboCode creates the local configuration under
`~/.turbocode/`. The default OpenAI-compatible endpoint used by Llama is:

```text
http://127.0.0.1:8080/v1
```

Change it in `~/.turbocode/models.json` when using another local server or
port. The file contains non-sensitive model endpoints and capabilities.

Agent, execution, Skill, and Git policies live in:

```text
~/.turbocode/config.json
```

DeepSeek credentials are configured in **Settings → Providers** and stored in
the macOS Keychain. TurboCode does not require or read a `.env` file.
See [CONFIGURATION.md](CONFIGURATION.md) for the complete configuration
schema.

## Experimental capabilities

The following capabilities are available but remain experimental:

### On-device orchestration

The on-device model can act as the entry point, analyze a request, and
delegate complex work to a configured worker model. The result returns to the
on-device coordinator for presentation.

### Automatic conversation titles

TurboCode can generate a concise title for a session from its initial context,
making the sidebar easier to scan.

### Safari MCP

Safari MCP is an optional coordinator-only integration. It is disabled by
default and can be enabled from **Settings → Agents → Experimental**.

## Requirements and Xcode setup

- The latest available macOS 27 beta
- Xcode 27 beta with the full suite installed
- Swift 6
- Node.js 24 or later for TypeScript plugins
- A Mac capable of running Apple Foundation Models for the on-device profile
- An optional local model server or remote provider credential for other
  profiles

The full Xcode suite is required even for a standalone Swift package because
TurboCode uses Xcode project and scheme discovery, Apple SDKs, `xcrun`,
`xcodebuild`, compiler destinations, and structured `xcresult` diagnostics.
The Command Line Tools alone are not sufficient for the supported workflow.

Launch Xcode once to accept its license and install requested platform
components, then verify the active toolchain:

```shell
xcodebuild -version
xcode-select -p
```

## Build from source

Clone the repository, open `TurboCode.xcodeproj`, select the **TurboCode**
scheme, and run the macOS app.

Command-line build:

```shell
xcodebuild \
  -project TurboCode.xcodeproj \
  -scheme TurboCode \
  -configuration Debug \
  build
```

Swift Package dependencies are resolved automatically by Xcode. The project
uses a local copy of [Apple Foundation Models Utilities](https://github.com/apple/foundation-models-utilities),
temporarily vendored from `1.0.0-beta3` with the obsolete
`Transcript.Segment.custom` case removed for Xcode 27 beta compatibility.
Provenance and removal instructions are documented in
`Vendor/foundation-models-utilities/README-TurboCode.md`.

Other direct dependencies include
[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Tests and evaluations

The deterministic release gate runs Swift Testing coverage without starting
Foundation Models:

```shell
Scripts/test-deterministic.sh
```

Model-backed golden evaluations use a separate, timeout-bounded command. They
can vary with macOS 27 beta and Foundation Models changes, so they are
experimental signals rather than the deterministic release gate. See
[TESTING.md](TESTING.md) for both paths.

## Privacy and safety

- Apple on-device inference stays local.
- Local OpenAI-compatible inference stays local when a local endpoint is used.
- Remote requests are sent only to the backend selected by the user.
- Credentials are stored in the macOS Keychain, not in TurboCode's JSON files.
- File tools validate workspace paths and recheck targets before execution.
- Source edits are revision-bound and presented for review.
- Destructive file and Git operations have explicit approval boundaries.
- Diagnostics exclude prompts, generated source, file contents, and workspace
  paths.

TurboCode is software under development and should not be treated as a
security boundary. Review generated changes and Git operations before
publishing them.

## Project status

The 0.4.0 line currently includes:

- workspace and session persistence;
- built-in and custom model profiles;
- local and Codex runtime lifecycle management;
- reviewable, revision-bound edits;
- repository maps and structured Git tools;
- Xcode and Swift Package Manager inspection, builds, and tests;
- Codex App Server integration and model handoff;
- TypeScript plugin SDK, validation, installation, reload, tools, and widgets;
- workspace `AGENTS.md` instructions;
- native transcript sharing and compact sidebar session controls.

The release still requires final clean-install validation, documentation
polish, and confirmation of the supported macOS 27 beta environment. Model
behavior varies between backends, and plugin trust and some advanced approval
flows remain under active development.

See [CHANGELOG.md](CHANGELOG.md) for the release history and
[PRODUCT.md](PRODUCT.md) for the product contract. For a visual overview and
the latest project notes, visit [granvalenti.art/turbocode](https://granvalenti.art/turbocode/).

## License

TurboCode is available under the [MIT License](LICENSE).
