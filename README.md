# TurboCode

TurboCode is a compact, native agentic development environment for macOS 27, built specifically for Swift, SwiftUI, Xcode projects, and Swift packages.

It combines Apple's Foundation Models framework with model-aware tools, native macOS interaction, integrated product documentation, and deterministic workspace services. Its goal is to take a development request from project inspection to a reviewable, buildable result without becoming a browser-based IDE or a generic chatbot.

> [!NOTE]
> TurboCode is under active development and currently targets macOS 27 and Xcode 27.

## Why TurboCode?

General-purpose coding agents often expose the same tools and prompts to every model, regardless of context capacity or tool-calling reliability.

TurboCode takes a different approach. Each supported model receives a dedicated `DynamicProfile` built with Apple's Foundation Models framework. The profile controls instructions, context management, reasoning capabilities, and the exact tools available to that model.

Smaller models receive compact, flat tool interfaces. More capable models can receive richer project maps, diagnostics, and advanced workflows. Regardless of the selected backend, the user interacts with the same workspace, conversation experience, review interface, and safety boundaries.

## Highlights

- Native SwiftUI application for macOS 27.
- Focused on Swift, SwiftUI, Xcode, and Swift Package Manager.
- Four model profiles with model-specific tools and context policies.
- Standalone and Orchestrator operating modes.
- Automatic removal of completed tool-call exchanges where supported.
- Compact Swift repository maps for medium and large projects.
- Structured Xcode project inspection, build, and test tools.
- Revision-bound source editing with visible Review and Undo.
- Structured local Git workflows.
- Reusable, on-demand Skills.
- Integrated, versioned TurboCode documentation.
- Native Settings with Keychain-backed credential storage.
- Local session persistence under `~/.turbocode`.
- No web runtime or browser-based user interface.

## Supported models

TurboCode currently defines four distinct model profiles.

| Model | Role | Default setup | Tool profile |
| --- | --- | --- | --- |
| Apple on-device | Lightweight assistant and orchestrator | Loaded directly through Foundation Models | Small, flat tools and product guidance |
| Apple PCC | Larger Apple-hosted model through Private Cloud Compute | Local `fm serve` bridge | Compact 32K-oriented coding profile |
| Llama | Private local coding model | OpenAI-compatible server on port `8080` | Compact 32K-oriented coding profile |
| DeepSeek V4 Flash | Premium backend for demanding tasks | DeepSeek API with Keychain credential | Enhanced repository map and larger diagnostic budget |

TurboCode presents these backends as one coherent product. They share the active workspace, persisted conversation experience, project safety rules, and deterministic execution services, while retaining model-specific context and tool capabilities.

## Standalone and Orchestrator modes

### Standalone

The selected model handles the request directly and receives the tools assigned to its capability profile.

This mode is useful when working directly with Apple PCC, a local Llama model, or DeepSeek.

### Orchestrator

Apple's on-device model handles lightweight interaction and decides when a task requires a more capable coding model.

Complex project inspection, editing, Git operations, builds, and tests are delegated through `call_powerful_model`. Select the delegated model under **TurboCode > Settings > Agents > Orchestrator**. Available delegates are read from `~/.turbocode/models.json`.

## Context-efficient by design

TurboCode treats context as a product resource.

Completed tool-call exchanges are removed from later generations for Apple on-device, Apple PCC, Llama, and Orchestrator profiles after their useful result has been incorporated. Skills are advertised using only their names and activation descriptions; their complete instructions are loaded only when needed.

DeepSeek is handled separately because its reasoning protocol requires previous reasoning and tool messages to be preserved. This transport exception remains isolated inside the DeepSeek adapter.

## Understanding existing projects

Before reading large source files, capable models can call `swift_workspace_map`.

The repository map extracts:

- Swift classes, actors, structs, enums, protocols, and extensions;
- function and property signatures;
- source line numbers;
- nearby documentation comments;
- imports and project markers;
- focused symbol relationships.

Llama and Apple PCC receive a compact map designed for a conservative 32K context. DeepSeek can receive an enhanced map containing additional type and import relationships.

Repository maps are cached incrementally under:

```text
~/.turbocode/cache/repository-maps/
```

Only Swift files whose size or modification date changed need to be scanned again.

## Workspace tools

Depending on the selected model, TurboCode provides tools for:

- reading complete files or focused line ranges;
- searching source code and text;
- listing and managing workspace files;
- creating and editing files;
- producing reviewable patches;
- inspecting Swift declarations through the repository map;
- running bounded commands;
- inspecting and managing Git repositories;
- building and testing Xcode projects.

File operations are limited to the active workspace.

## Xcode builds and tests

TurboCode includes a structured `xcode_project` tool with three flat actions:

- `inspect`
- `build`
- `test`

The tool discovers Xcode projects, workspaces, schemes, targets, and build configurations. Builds and tests use the selected Xcode toolchain through direct process arguments rather than shell interpolation.

TurboCode reads `.xcresult` data and returns compact diagnostics containing:

- build status and duration;
- source file and line;
- compiler errors and warnings;
- test totals;
- failed test names and messages.

Builds reuse Xcode's normal DerivedData directory. TurboCode does not create a separate cold-build environment, and temporary result bundles are removed after diagnostics have been extracted.

Apple on-device delegates Xcode work in Orchestrator mode. Apple PCC and Llama receive compact diagnostics, while DeepSeek can receive a larger but still bounded diagnostic report.

## Source editing and review

Generated edits are revision-bound. A model cannot silently overwrite a source file that changed after it was read.

TurboCode:

1. validates the workspace path;
2. verifies the file revision;
3. constructs the candidate change;
4. generates and validates the patch;
5. applies the edit;
6. presents the resulting additions and deletions.

Changes appear as native widgets in the conversation with Review and Undo actions.

## Git integration

Git is part of the main development workflow rather than a read-only inspector.

TurboCode's structured Git service supports:

- repository initialization;
- status and diff;
- history;
- local branches;
- staging and commits;
- merges and rebases;
- remotes;
- fetch, pull, and push.

Git arguments are passed directly to `/usr/bin/git` and are never interpolated into shell commands. Operations that can discard work, rewrite history, delete content, or publish consequential remote changes require confirmation according to the configured policy.

## Skills

TurboCode supports reusable Skills stored under:

```text
~/.turbocode/SKILLS/<skill-name>/SKILL.md
```

A Skill contains a short activation description and focused operational instructions. TurboCode discovers Skills automatically and loads their complete content only when relevant.

Built-in Skills include:

- `turbocode` — product knowledge, setup, workflows, and configuration;
- `skill-creator` — guidance for creating reusable Skills.

Skills can also be invoked explicitly from the composer:

```text
/skills
/skill <name>
/<skill-name>
```

## Integrated documentation

TurboCode installs versioned product documentation under:

```text
~/.turbocode/documentation/official/
```

Users can ask questions such as:

- "What can TurboCode do?"
- "How do I configure PCC?"
- "How does Orchestrator mode work?"
- "Which model can build an Xcode project?"
- "How are API keys stored?"

The model retrieves the relevant official source through `turbocode_guide` and presents the answer using a native documentation card.

The configuration layout also reserves `~/.turbocode/documentation/user/` for future user-provided documentation workflows.

## Requirements

- macOS 27 or later.
- Xcode 27 or later.
- Swift 6.
- A system capable of using Apple Foundation Models for the on-device profile.
- An optional local OpenAI-compatible model server for Llama.
- An optional DeepSeek API key for the premium backend.

## Building from source

Open `TurboCode.xcodeproj` in Xcode, select the `TurboCode` scheme, and run the macOS application.

Command-line builds are also supported:

```shell
xcodebuild \
  -project TurboCode.xcodeproj \
  -scheme TurboCode \
  -configuration Debug \
  build
```

Swift Package dependencies are resolved automatically by Xcode. Current package dependencies include:

- [Apple Foundation Models Utilities](https://github.com/apple/foundation-models-utilities)
- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)

## First launch

On first launch, TurboCode creates its application directory:

```text
~/.turbocode/
├── cache/
├── diagnostics/
├── documentation/
│   ├── official/
│   └── user/
├── sessions/
├── SKILLS/
├── config.json
└── models.json
```

The default Llama, Apple PCC, and DeepSeek endpoints are added automatically. Secrets are never stored in these JSON files.

## Model setup

### Apple on-device

No server or API key is required. The model is loaded directly through the Foundation Models framework.

### Apple PCC

Start Apple's local Foundation Models bridge from Terminal:

```shell
fm serve --port 1976
```

Keep the process running while using PCC. TurboCode already uses:

```text
Endpoint: http://127.0.0.1:1976/v1
Model:    pcc
```

No API key is required. The local server health endpoint is `http://127.0.0.1:1976/health`.

### Llama

TurboCode expects an OpenAI-compatible local server by default:

```text
Endpoint: http://127.0.0.1:8080/v1
Model:    local-model
```

The endpoint and model identifier can be changed in `~/.turbocode/models.json`.

### DeepSeek V4 Flash

Open **TurboCode > Settings > Providers > DeepSeek** and enter the API key in the secure field. TurboCode stores it in the macOS Keychain and keeps only a credential reference in `models.json`.

## Configuration

TurboCode uses two versioned configuration files:

```text
~/.turbocode/config.json
~/.turbocode/models.json
```

`config.json` controls:

- response style;
- verification policy;
- command timeouts;
- maximum tool output;
- network access;
- Git policies;
- Orchestrator delegate;
- Skill discovery.

`models.json` defines non-secret model information:

- endpoint;
- model identifier;
- role;
- context budget;
- reasoning transport;
- repository-map capability;
- credential reference.

Common settings are available in the native Settings window. Advanced values can be edited manually and reloaded from Settings. See [CONFIGURATION.md](CONFIGURATION.md) for the complete schema.

## Privacy and safety

- Apple on-device inference remains local.
- Llama inference remains local when using a local server.
- PCC requests use Apple Private Cloud Compute.
- DeepSeek requests are sent to the configured DeepSeek endpoint.
- Credentials are stored in the macOS Keychain.
- Configuration files never contain API-key values.
- Workspace tools reject paths outside the active workspace.
- Source edits are revision-bound and reviewable.
- Destructive file and Git operations require confirmation.
- Diagnostic records avoid prompts, generated source content, file contents, and workspace paths.

## Project scope

TurboCode is intentionally specialized. It is designed for:

- Swift and Swift macros;
- SwiftUI;
- native macOS development;
- Xcode projects and workspaces;
- Swift Package Manager;
- Swift Testing and XCTest;
- Apple SDK and `xcrun` workflows;
- Git-backed project development.

TurboCode is not intended to be a general desktop automation agent, an unrestricted shell, a broad multi-language IDE, or a generic web assistant.

## Project status

TurboCode is currently in active development toward its first MVP. APIs and configuration formats may change before the first stable release.

## License

TurboCode is available under the [MIT License](LICENSE).
