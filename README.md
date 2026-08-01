<p align="center">
  <img src="turbocode-logo-provisional.png" width="112" alt="TurboCode icon">
</p>

# TurboCode

**A native macOS agent harness for Swift and Xcode.**

TurboCode is an open-source agent harness built in SwiftUI with Apple's
Foundation Models framework. It provides a native runtime for model routing,
typed tool calls, workspace safety, reviewable edits, builds, tests, and Git
operations, specialized in agentic work on Swift, SwiftUI, Xcode projects, and
Swift Package Manager packages.

> [!IMPORTANT]
> TurboCode 0.2.0 is a structured agent-loop release under active development. It targets macOS 27, Xcode 27, and Swift 6.

![TurboCode conversation with a Swift composer and a local workspace selected](.github/assets/turbocode-conversation.png)

## Philosophy

### Memory under control

TurboCode uses **less than 70 MB** of memory when idle. For context: Codex uses about 600 MB, Pi about 120 MB. This is not a secondary detail: it means TurboCode can sit comfortably in the background while Xcode, simulators, and browsers share the same machine.

### An agentic harness for Swift and Xcode

TurboCode is an **agent harness for Swift and Xcode workflows**. It brings
local Llama, Apple on-device, Apple PCC, and state-of-the-art Codex and DeepSeek
models behind one native SwiftUI runtime. The harness adapts to the runtimes
available on the user's machine and account, without making the agentic loop
depend on a single provider or subscription. Its goal is a high-performance
agentic loop in which models plan and act through typed tools, while
deterministic services enforce workspace boundaries, revision checks,
approvals, review, verification, and recoverable Git state.

The current release line is intentionally Apple-platform and Swift-first. A
broader general-purpose coding environment may be evaluated in a future
release line, but it is not a requirement or promise of the current product.

### A native interface that follows the HIG

Written in **SwiftUI** and aligned with Apple's **Human Interface Guidelines**. The UI follows the principle of **progressive disclosure**: the main elements—workspaces, past sessions, tools—are easily accessible in their respective areas through **collapsible lists**. No bloat, no buried menus.

## What it does

### 1. A structured conversation, not just text

The conversation with the agent is not purely textual. Some tools use the **`@Generable`** macro to present content in the most useful form—structured, navigable, and contextual. This includes:

- An **integrated diff checker** for seeing changes line by line
- A **visual Git status summary** that groups staged, modified, and untracked files
- A traceable Git loop for commit, branch, merge, rebase, and remote operations
- Revision-aware Undo and Review against the real working tree

<table>
  <tr>
    <td width="50%"><img src=".github/assets/turbocode-review-changes.png" alt="TurboCode Review Changes sheet showing a line-by-line diff"></td>
    <td width="50%"><img src=".github/assets/turbocode-changes-sidebar.png" alt="TurboCode Changes sidebar showing the diff beside the conversation"></td>
  </tr>
</table>

### 2. An intelligent repository map

TurboCode maps the workspace through compact Swift declarations, relationships between files, imports, and source locations. The **map depth is adaptive**: lighter for local models, richer for powerful backends. Results are cached for fast reuse. Repository-specific instructions in `AGENTS.md` are loaded into the session without exposing files outside the active workspace.

![TurboCode Workspace Files panel showing the contents of a Swift package](.github/assets/turbocode-workspace-files.png)

### 3. Visible and traceable Git

Every Git operation—branch, staging, commit, merge, rebase, remote, pull, push—is exposed as a tool call in the conversation flow. No invisible commands running in the background. Every action is reviewed before it is applied.

![TurboCode conversation showing a branch creation and completed Git commit](.github/assets/turbocode-git-commit.png)

### 4. Build, test, diagnostics

TurboCode inspects the Xcode project, runs builds and unit tests, and reports compiler diagnostics directly in the conversation. For standalone packages, one structured Swift Package Manager tool handles initialization, dependencies, resolution, build, test, run, cleanup, and package inspection.

### Xcode is a runtime prerequisite

The full Xcode suite is required even when the active workspace contains only
a standalone Swift package. TurboCode's Xcode tool calls depend on Xcode
project and scheme discovery, Apple SDKs, compiler and test destinations,
xcrun, xcodebuild, and structured xcresult diagnostics. The Command Line Tools
alone are not sufficient for the supported Xcode workflow.

You do not need to keep the Xcode UI open while using TurboCode, but Xcode 27
must be installed, launched once to accept its license and install requested
platform components, and selected as the active developer directory. Verify
the active toolchain with:

~~~shell
xcodebuild -version
xcode-select -p
~~~

For an Xcode project or workspace, TurboCode discovers schemes and invokes the
selected toolchain. For a standalone Swift package, TurboCode can perform the
package workflow without opening Xcode, but the full Xcode installation remains
the supported release prerequisite.

## Model profiles

TurboCode comes with preconfigured profiles for several model runtimes.

| Backend | Setup |
| --- | --- |
| **Apple Foundation Models (on-device)** | Runs locally through Apple's framework; no server or API key required. |
| **Apple PCC** | Uses the local Foundation Models bridge while `fm serve --port 1976` is running. |
| **Llama / OpenAI-compatible** | Connects to a local server such as `llama-server`; example endpoint: `http://127.0.0.1:8080/v1`. |
| **Codex** | Uses the official Codex CLI App Server and its ChatGPT sign-in flow; TurboCode does not read Codex credentials. |
| **DeepSeek** | Uses the configured remote API; credentials are entered in Settings and stored in macOS Keychain. |

The profiles use the beta FoundationModels libraries—**`DynamicProfile`**, **`Summary`**, **dynamic tool calls**, **automatic removal of obsolete tool calls**, and **model switching without losing the session** or creating a new one.

### User-customizable profiles

Every profile can be **overridden** by the user. You can manually select which tool calls to enable and create specialized agents:

- A **Git-only** profile that can only perform Git operations
- A **read-only** profile that can read but not write files
- A **reviewer** profile for automatic code review

Custom profiles and reusable Skills live in versioned configurations.

<table>
  <tr>
    <td width="50%"><img src=".github/assets/turbocode-custom-profiles.png" alt="TurboCode Custom Profiles editor with tool calls and Skills assigned to a local Llama model"></td>
    <td width="50%"><img src=".github/assets/turbocode-model-picker.png" alt="TurboCode model picker showing built-in and custom profiles"></td>
  </tr>
</table>

## Experimental features

### A rudimentary orchestrator

An experimental orchestrator lets you use the **on-device model as an entry point**: it receives the request, analyzes it, and delegates complex operations to more powerful models. The result returns to the orchestrator, which presents it to the user. This provides local responsiveness with remote power.

### A standalone support profile

For each session, the on-device model can automatically generate the **conversation title** by analyzing the initial context—instead of using the user's prompt as the title. A small automation that keeps conversation history navigable without effort.

## Tools and diagnostics

The **Tools** view resolves model profiles, the selected workspace, installed Skills, and runtime capabilities into a matrix. It is a practical and transparent debugging surface.

- Backend availability
- Context requirements
- Capability matrix
- On-device latency, token, tool-call, and outcome statistics

![TurboCode Tools view comparing model profiles and their runtime capabilities](.github/assets/turbocode-tools.png)

## Configuration

Non-sensitive data such as endpoints and capabilities lives in `~/.turbocode/models.json`. Agent, execution, Skill, and Git policies live in `~/.turbocode/config.json`. See [CONFIGURATION.md](CONFIGURATION.md) for the complete schema.

## Requirements

- macOS 27 or later
- Xcode 27 or later, full suite installed and selected as the active developer directory
- Swift 6
- A Mac capable of running Apple Foundation Models for the on-device profile
- An optional local model server or remote provider credential for other profiles

## Build from source

Clone the repository, open `TurboCode.xcodeproj`, select the **TurboCode** scheme, and run the macOS app.

Command-line build:

```shell
xcodebuild \
  -project TurboCode.xcodeproj \
  -scheme TurboCode \
  -configuration Debug \
  build
```

Swift Package dependencies are resolved automatically by Xcode. Direct dependencies:

- [Apple Foundation Models Utilities](https://github.com/apple/foundation-models-utilities)
- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)

## Tests and evaluations

The release gate runs deterministic Swift Testing coverage without starting
Foundation Models:

```shell
Scripts/test-deterministic.sh
```

Golden evaluations use a separate, timeout-bounded command. They may vary with
macOS 27 betas and Foundation Models changes, so they remain experimental
signals rather than release gates. See [TESTING.md](TESTING.md) for both paths.

## Privacy and safety

- Apple on-device inference stays local.
- Local OpenAI-compatible inference stays local when a local endpoint is used.
- Remote requests are sent only to the backend selected by the user.
- Credentials are stored in macOS Keychain, not in TurboCode's JSON files.
- File tools validate paths against the active workspace.
- Source edits are revision-bound and presented for review.
- Destructive file and Git operations have explicit approval boundaries.
- Diagnostics exclude prompts, generated source, file contents, and workspace paths.

TurboCode is software under development and should not be treated as a security boundary. Review generated changes and Git operations before publishing them.

## Project status

Working now:

- Workspace and session persistence
- Built-in and custom model profiles
- Reviewable, revision-bound edits
- Repository maps and structured Git tools
- Xcode and Swift Package Manager inspection, builds, and tests
- Codex App Server integration and model handoff
- Workspace `AGENTS.md` instructions
- Git status visualization and on-device model statistics
- Session Summary App Shortcut
- Versioned configuration and Keychain-backed credentials

Still to improve:

- Some composer and secondary controls are incomplete
- Approval flows need broader testing
- Model behavior varies considerably between backends
- Setup assumes familiarity with Swift tooling
- Compatibility is limited to recent development releases
- Clean-install testing and documentation are ongoing

For a visual overview and the latest project notes, visit [granvalenti.art/turbocode](https://granvalenti.art/turbocode/).

## License

TurboCode is available under the [MIT License](LICENSE).
