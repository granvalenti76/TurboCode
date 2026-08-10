# Models and Agent Roles

TurboCode presents one product experience while adapting its profile to the capabilities of the selected model.

In Standalone mode, the selected profile determines the route. Apple on-device is a microtask profile for lightweight assistance, product guidance, focused read-only file inspection, and already-delimited Swift snippets of at most about 30 lines. It does not receive general Git, shell, repository-map, or multi-file editing capabilities. Configured coding models can handle broader work according to their declared capabilities.

For the structured route, delegation is a capability rather than a separate
profile type. When a custom profile includes `delegate_task`, its selected
model sends a goal to the configured worker and remains responsible for the
final answer. The coordinator chooses only between a coding worker with the
worker tool bundle configured by the profile and a text-only worker with no
tools; TurboCode owns runtime identifiers, workspace safety, approval,
cancellation, and verification when applicable. Custom on-device profiles can
also include `delegate_task`; the built-in On-device profile remains direct by
default. DeepSeek, Codex, and Llama support this capability, while Apple PCC,
Llama, or DeepSeek can be selected as the worker.

The menu item **On-Device (Experimental)** preserves the older compatibility
path. In that mode Apple on-device may send a free-text task through
`call_powerful_model`; it is not the primary 0.3.0 structured delegation path.

In **Custom Profiles**, add **Delegate Task** under **Included Capabilities**.
Only then does the **Delegation** section appear, revealing the worker picker;
this keeps the common profile editor compact through progressive disclosure.
Codex profiles additionally reveal **Codex model** and **Reasoning**. Provider
availability still comes from `~/.turbocode/models.json`; secrets remain in the
macOS Keychain. **TurboCode > Settings > Agents > Default Delegated Worker**
remains the fallback for older profiles and experimental on-device delegation.

TurboCode validates reasoning and tool-calling capabilities before building a model profile. Worker tool availability comes from the catalog-backed profile rather than per-delegation restrictions invented by the coordinator.

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
preferences. When a Codex coordinator profile is active, TurboCode also
advertises `delegate_task` and routes it through the shared worker and Activity
pipeline; coding tasks use the applicable verification path. Direct Codex
profiles do not receive that tool.

## Configure Apple PCC

Apple on-device and Apple Private Cloud Compute are two different backends. The on-device model is loaded directly by the Foundation Models framework and does not require a server. TurboCode reaches PCC through the local Chat Completions server supplied by Apple's `fm` command-line tool.

Open Terminal and start the server on TurboCode's default port:

```shell
fm serve
```

Keep that Terminal process running while using PCC. TurboCode's default PCC entry points to `http://127.0.0.1:1976/v1` and selects the `pcc` model, so no endpoint editing or API key is required. Then choose **Apple PCC** as a profile model, or include **Delegate Task** in a custom profile and choose PCC as its worker.

If PCC is unavailable, first check that `fm serve` is still running. The server also exposes `http://127.0.0.1:1976/health` for a local health check. Availability of the PCC model itself is determined by Apple's Foundation Models service and the current system environment.

## Repository mapping and context budgets

For existing Swift, SwiftUI, Xcode, and Swift Package projects, capable models use `swift_workspace_map` before opening source files. The tool returns declaration signatures, line numbers, short documentation comments, project markers, and focused symbol queries without placing file bodies in the model context.

Apple on-device does not receive the repository map, including in the experimental delegation mode. The configured coding model performs project discovery. Llama and Apple PCC use a compact map designed around a conservative 32k context window. DeepSeek uses the enhanced map, which can also expose imports and type relationships.

The map is cached incrementally under `~/.turbocode/cache/repository-maps/`. TurboCode rescans only Swift files whose size or modification time changed. The cache contains declarations and workspace-relative paths, never source bodies.

## Xcode validation tools

Capable standalone and delegated models receive `xcode_project`. Its flat actions inspect the active `.xcworkspace` or `.xcodeproj`, build a scheme, or run its tests. Apple on-device does not receive this execution tool; the experimental delegation mode passes the operation to the selected capable backend.

Llama and Apple PCC receive compact compiler and test diagnostics suited to a conservative 32k context. DeepSeek and Codex can receive richer project context while still avoiding unbounded raw `xcodebuild` logs. Builds reuse the DerivedData normally managed by Xcode, including work already compiled from the application; temporary `.xcresult` bundles are removed after parsing.
