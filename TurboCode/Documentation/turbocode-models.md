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
default. DeepSeek, Codex, and Llama support this capability; Llama or DeepSeek
can be selected as the worker.

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

After choosing a worker, expand **Worker tools** to customize its tool surface.
The default is **All tools**, so existing profiles keep the complete worker
catalog without extra configuration. Turning that option off reveals the tools
grouped by category with their availability explained inline. The selection is
stored on the override profile, independently from the coordinator's Included
Capabilities: an empty selection deliberately creates a text-only worker,
while restoring **All tools** removes the override and follows the worker
catalog again. Delegation itself is never offered as a worker tool, preventing
recursive worker chains.

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

## Apple PCC status

Apple's PCC model exposed through `fm serve` is retired in the current
Foundation Models environment. TurboCode no longer exposes it as a default
profile, custom-profile override, composer model, or delegated worker. Legacy
PCC records remain readable only long enough for the compatibility code marked
`PCC-RETIREMENT` to be removed.

## Repository mapping and context budgets

For existing Swift, SwiftUI, Xcode, and Swift Package projects, capable models use `swift_workspace_map` before opening source files. The tool returns declaration signatures, line numbers, short documentation comments, project markers, and focused symbol queries without placing file bodies in the model context.

Apple on-device does not receive the repository map, including in the experimental delegation mode. The configured coding model performs project discovery. Llama uses a compact map designed around a conservative 32k context window. DeepSeek uses the enhanced map, which can also expose imports and type relationships.

The map is cached incrementally under `~/.turbocode/cache/repository-maps/`. TurboCode rescans only Swift files whose size or modification time changed. The cache contains declarations and workspace-relative paths, never source bodies.

## Xcode validation tools

Capable standalone and delegated models receive `xcode_project`. Its flat actions inspect the active `.xcworkspace` or `.xcodeproj`, build a scheme, or run its tests. Apple on-device does not receive this execution tool; the experimental delegation mode passes the operation to the selected capable backend.

Llama receives compact compiler and test diagnostics suited to a conservative 32k context. DeepSeek and Codex can receive richer project context while still avoiding unbounded raw `xcodebuild` logs. Builds reuse the DerivedData normally managed by Xcode, including work already compiled from the application; temporary `.xcresult` bundles are removed after parsing.
