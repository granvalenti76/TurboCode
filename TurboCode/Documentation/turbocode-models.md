# Models and Orchestrator Mode

TurboCode presents one product experience while adapting its profile to the capabilities of the selected model.

In Standalone mode, the active model receives the tools appropriate to its capability tier and handles the request directly. Apple on-device is useful for immediate lightweight assistance and product guidance. Configured local, PCC, or premium models can handle broader coding work according to their declared capabilities.

In Orchestrator mode, Apple on-device interprets the request and coordinates the experience. Navigation and lightweight product questions remain local. Complex inspection, editing, build, test, and Git work is delegated through `call_powerful_model` to the model selected in TurboCode Settings.

The delegated model can be selected under **TurboCode > Settings > Agents > Orchestrator**. Available choices come from `~/.turbocode/models.json`; secrets remain in the macOS Keychain.

TurboCode validates reasoning and tool-calling capabilities before building a model profile. This prevents unsupported options from reaching a model and provides a foundation for giving advanced tools only to models that can use them reliably.

## Repository mapping and context budgets

For existing Swift, SwiftUI, Xcode, and Swift Package projects, capable models use `swift_workspace_map` before opening source files. The tool returns declaration signatures, line numbers, short documentation comments, project markers, and focused symbol queries without placing file bodies in the model context.

Apple on-device does not receive the repository map, including while it acts as orchestrator. The configured delegate performs project discovery. Llama and Apple PCC use a compact map designed around a conservative 32k context window. DeepSeek uses the enhanced map, which can also expose imports and type relationships.

The map is cached incrementally under `~/.turbocode/cache/repository-maps/`. TurboCode rescans only Swift files whose size or modification time changed. The cache contains declarations and workspace-relative paths, never source bodies.

## Xcode validation tools

Capable standalone and delegated models receive `xcode_project`. Its flat actions inspect the active `.xcworkspace` or `.xcodeproj`, build a scheme, or run its tests. Apple on-device does not receive this execution tool; in Orchestrator mode it delegates the operation to the selected Llama, PCC, or DeepSeek model.

Llama and Apple PCC receive compact compiler and test diagnostics suited to a conservative 32k context. DeepSeek can receive a larger diagnostic set, while still avoiding raw `xcodebuild` logs. Builds reuse the DerivedData normally managed by Xcode, including work already compiled from the application; temporary `.xcresult` bundles are removed after parsing.
