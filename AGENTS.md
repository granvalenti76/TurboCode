# Repository Guidelines

## Project Structure & Module Organization

`TurboCode/` contains the Swift 6 macOS application. Keep UI in `Views/`, presentation state in `ViewModels/` and `Stores/`, data types in `Models/`, and integrations in `Services/` or `Tools/`. Product references live in `TurboCode/Documentation/`. `TurboCodeEvaluations/` contains Swift Testing suites and agent evaluations. Assets belong in `Media.xcassets`; project settings live in `TurboCode.xcodeproj`.

## Product Direction

Treat `PRODUCT.md` as the contract. Preserve safety and reviewability while minimizing latency and context. Follow Apple's macOS Human Interface Guidelines with native, accessible SwiftUI or AppKit conventions. Avoid desktop automation, broad multi-language IDE features, and unrestricted shell behavior.

## Build, Test, and Development Commands

- `open TurboCode.xcodeproj` opens the project in Xcode. Select the `TurboCode` scheme to run the app.
- `xcodebuild -project TurboCode.xcodeproj -scheme TurboCode -configuration Debug build` builds the debug app and resolves Swift packages.
- `xcodebuild test -project TurboCode.xcodeproj -scheme TurboCodeEvaluations -destination 'platform=macOS'` runs the evaluation and unit-test target.
- `git diff --check` detects whitespace errors before a commit.

The project requires macOS 27, Xcode 27, and Swift 6.

## Coding Style & Naming Conventions

Follow Swift API design: four-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for methods, properties, and enum cases. Match filenames to their primary type, such as `SessionSearchViewModel.swift`. Prefer focused SwiftUI views and keep workspace, Git, Xcode, and provider behavior behind existing service/tool boundaries. Use `@MainActor` for UI-owned mutable state and preserve explicit concurrency annotations. No separate formatter or linter is configured; use Xcode formatting and keep warnings clean.

## Code Comments & Documentation

Every code change must add or update comments that make the modified behavior easy to review and maintain. Document the intent behind non-obvious logic, invariants, provider-specific workarounds, concurrency or safety constraints, and important tradeoffs. Keep public types and APIs documented with concise Swift documentation comments where their purpose is not already self-evident. When behavior changes, update nearby comments so they remain accurate. Prefer comments that explain why the code exists and what must remain true; avoid comments that merely repeat the syntax or narrate an obvious statement.

## Testing Guidelines

Tests use Apple's Swift Testing framework (`import Testing`), with descriptive `@Suite` and `@Test` labels and `#expect` assertions. Name test methods by observable behavior, for example `recentSessionsAreLimitedAndOrdered()`. Add focused coverage in `TurboCodeEvaluations/` for changed logic; update golden evaluations only when intended agent behavior changes. Run the shared evaluation scheme before opening a pull request.

## Commit & Pull Request Guidelines

History uses short, imperative subjects such as `Add native session search` and `Fix DeepSeek edit argument parsing`. Keep commits scoped to one coherent change. Pull requests should explain the user-visible outcome, note build/test results, link relevant issues, and include screenshots for SwiftUI changes. Call out changes to entitlements, signing, model configuration, or persisted data.

## Security & Configuration

Never commit credentials or local `~/.turbocode` data. Store API keys in macOS Keychain, and document configuration changes in `CONFIGURATION.md`. Preserve workspace path validation, revision checks, and confirmation gates around destructive Git or shell operations.
