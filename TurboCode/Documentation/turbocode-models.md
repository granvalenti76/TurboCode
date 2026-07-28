# Models and Orchestrator Mode

TurboCode presents one product experience while adapting its profile to the capabilities of the selected model.

In Standalone mode, the active model receives the tools appropriate to its capability tier and handles the request directly. Apple on-device is useful for immediate lightweight assistance and product guidance. Configured local, PCC, or premium models can handle broader coding work according to their declared capabilities.

In Orchestrator mode, Apple on-device interprets the request and coordinates the experience. Navigation and lightweight product questions remain local. Complex inspection, editing, build, test, and Git work is delegated through `call_powerful_model` to the model selected in TurboCode Settings.

The delegated model can be selected under **TurboCode > Settings > Agents > Orchestrator**. Available choices come from `~/.turbocode/models.json`; secrets remain in the macOS Keychain.

TurboCode validates reasoning and tool-calling capabilities before building a model profile. This prevents unsupported options from reaching a model and provides a foundation for giving advanced tools only to models that can use them reliably.

## Configure Apple PCC

Apple on-device and Apple Private Cloud Compute are two different backends. The on-device model is loaded directly by the Foundation Models framework and does not require a server. TurboCode reaches PCC through the local Chat Completions server supplied by Apple's `fm` command-line tool.

Open Terminal and start the server on TurboCode's default port:

```shell
fm serve
```

Keep that Terminal process running while using PCC. TurboCode's default PCC entry points to `http://127.0.0.1:1976/v1` and selects the `pcc` model, so no endpoint editing or API key is required. Then choose **Apple PCC** as the standalone model, or as the delegated model under **TurboCode > Settings > Agents > Orchestrator**.

If PCC is unavailable, first check that `fm serve` is still running. The server also exposes `http://127.0.0.1:1976/health` for a local health check. Availability of the PCC model itself is determined by Apple's Foundation Models service and the current system environment.

## Repository mapping and context budgets

For existing Swift, SwiftUI, Xcode, and Swift Package projects, capable models use `swift_workspace_map` before opening source files. The tool returns declaration signatures, line numbers, short documentation comments, project markers, and focused symbol queries without placing file bodies in the model context.

Apple on-device does not receive the repository map, including while it acts as orchestrator. The configured delegate performs project discovery. Llama and Apple PCC use a compact map designed around a conservative 32k context window. DeepSeek uses the enhanced map, which can also expose imports and type relationships.

The map is cached incrementally under `~/.turbocode/cache/repository-maps/`. TurboCode rescans only Swift files whose size or modification time changed. The cache contains declarations and workspace-relative paths, never source bodies.

## Xcode validation tools

Capable standalone and delegated models receive `xcode_project`. Its flat actions inspect the active `.xcworkspace` or `.xcodeproj`, build a scheme, or run its tests. Apple on-device does not receive this execution tool; in Orchestrator mode it delegates the operation to the selected Llama, PCC, or DeepSeek model.

Llama and Apple PCC receive compact compiler and test diagnostics suited to a conservative 32k context. DeepSeek can receive a larger diagnostic set, while still avoiding raw `xcodebuild` logs. Builds reuse the DerivedData normally managed by Xcode, including work already compiled from the application; temporary `.xcresult` bundles are removed after parsing.
