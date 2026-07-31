# Models and Agent Roles

TurboCode presents one product experience while adapting its profile to the capabilities of the selected model.

In Standalone mode, the selected profile determines the route. Apple on-device is a microtask profile for lightweight assistance, product guidance, and already-delimited Swift snippets of at most about 30 lines. It does not receive general Git, shell, project exploration, or multi-file editing capabilities. Configured coding models can handle broader work according to their declared capabilities.

For the 0.2.0 structured route, a custom profile can use Llama, DeepSeek, or Codex as coordinator and Apple PCC, Llama, or DeepSeek as its worker. The coordinator delegates a bounded envelope through `delegate_task` and remains responsible for verification and the final answer.

The menu item **On-Device (Experimental)** preserves the older compatibility path. In that mode Apple on-device may send a free-text task through `call_powerful_model`; it is not the primary 0.2.0 release scenario.

Choose **Coordinator → Worker** in **Custom Profiles** to reveal the route controls. Direct profiles remain simple. Llama and DeepSeek expose the selected worker; Codex additionally reveals **Codex model** and **Reasoning**, followed by the worker. A Codex route can pin both values, or keep **Codex Default** and **Model Default** to inherit the current direct-Codex preferences. Provider availability still comes from `~/.turbocode/models.json`; secrets remain in the macOS Keychain. **TurboCode > Settings > Agents > Default Delegated Worker** remains the fallback for older profiles and experimental on-device delegation.

TurboCode validates reasoning and tool-calling capabilities before building a model profile. This prevents unsupported options from reaching a model and provides a foundation for giving advanced tools only to models that can use them reliably.

## Configure Codex

The Codex profile uses the official Codex CLI and its local App Server. Install
Codex, select the profile in TurboCode, and complete the ChatGPT sign-in flow if
requested. TurboCode discovers the models available to the signed-in account
and lets the user choose a supported reasoning level.

Authentication remains owned by the Codex runtime: TurboCode neither reads nor
copies Codex credentials. Codex keeps its own agent loop while TurboCode exposes
the same bounded workspace, Swift Package Manager, review, and approval tools
used by the other capable profiles. A Codex coordinator profile applies its
saved model and reasoning per turn without replacing the direct-Codex composer
preferences. When a Codex coordinator profile is active,
TurboCode also advertises `delegate_task` and routes it through the shared
bounded worker, verification, and Activity pipeline. Direct Codex profiles do
not receive that tool.

## Configure Apple PCC

Apple on-device and Apple Private Cloud Compute are two different backends. The on-device model is loaded directly by the Foundation Models framework and does not require a server. TurboCode reaches PCC through the local Chat Completions server supplied by Apple's `fm` command-line tool.

Open Terminal and start the server on TurboCode's default port:

```shell
fm serve
```

Keep that Terminal process running while using PCC. TurboCode's default PCC entry points to `http://127.0.0.1:1976/v1` and selects the `pcc` model, so no endpoint editing or API key is required. Then choose **Apple PCC** as the standalone model, or reveal the route controls in a coordinator custom profile and choose it as the worker.

If PCC is unavailable, first check that `fm serve` is still running. The server also exposes `http://127.0.0.1:1976/health` for a local health check. Availability of the PCC model itself is determined by Apple's Foundation Models service and the current system environment.

## Repository mapping and context budgets

For existing Swift, SwiftUI, Xcode, and Swift Package projects, capable models use `swift_workspace_map` before opening source files. The tool returns declaration signatures, line numbers, short documentation comments, project markers, and focused symbol queries without placing file bodies in the model context.

Apple on-device does not receive the repository map, including in the experimental delegation mode. The configured coding model performs project discovery. Llama and Apple PCC use a compact map designed around a conservative 32k context window. DeepSeek uses the enhanced map, which can also expose imports and type relationships.

The map is cached incrementally under `~/.turbocode/cache/repository-maps/`. TurboCode rescans only Swift files whose size or modification time changed. The cache contains declarations and workspace-relative paths, never source bodies.

## Xcode validation tools

Capable standalone and delegated models receive `xcode_project`. Its flat actions inspect the active `.xcworkspace` or `.xcodeproj`, build a scheme, or run its tests. Apple on-device does not receive this execution tool; the experimental delegation mode passes the operation to the selected capable backend.

Llama and Apple PCC receive compact compiler and test diagnostics suited to a conservative 32k context. DeepSeek and Codex can receive richer project context while still avoiding unbounded raw `xcodebuild` logs. Builds reuse the DerivedData normally managed by Xcode, including work already compiled from the application; temporary `.xcresult` bundles are removed after parsing.
