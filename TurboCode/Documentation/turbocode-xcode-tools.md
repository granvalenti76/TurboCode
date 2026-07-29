# Building and Testing with Xcode

TurboCode provides a structured Xcode workflow so the model does not need to compose shell commands or read complete compiler logs.

## Inspect the project

The `inspect` action discovers the nearest Xcode workspace or project and lists its visible schemes, targets, and build configurations. A specific workspace-relative `.xcworkspace` or `.xcodeproj` can be selected when a repository contains multiple containers.

## Build a scheme

The `build` action invokes the selected Xcode toolchain with direct process arguments. TurboCode can use an explicit scheme, configuration, and destination, or choose the visible scheme that best matches the container or one of its targets. DerivedData remains under Xcode's normal management, so TurboCode can reuse incremental work produced by builds started in the application.

After the build, TurboCode reads the structured `.xcresult` summary and returns the build status, duration, destination, issue counts, and focused source locations. Raw build output is used only as a bounded fallback when Xcode cannot produce a structured result.

## Run tests

The `test` action runs the scheme tests and summarizes the total, passed, failed, and skipped cases. Failed test names and messages are returned without placing the complete test log in model context.

## Model availability

Apple on-device does not run Xcode builds or tests directly. Llama and Apple PCC receive compact output designed for a 32k working context. DeepSeek receives an enhanced but still bounded diagnostic report. In the experimental on-device delegation mode, the Apple model delegates Xcode validation to the configured capable model.

## Timeouts and build state

Xcode operations respect the maximum command timeout configured under TurboCode Settings or in `~/.turbocode/config.json`. TurboCode does not create a second DerivedData tree or force a cold build. Temporary result bundles are removed after diagnostics are extracted.
