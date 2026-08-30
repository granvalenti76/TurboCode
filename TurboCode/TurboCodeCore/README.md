# TurboCodeCore integration boundary

`TurboCodeCore` is the provider- and presentation-neutral engine being
extracted from the TurboCode macOS application. This directory is the staging
boundary for that future Swift package: code moves here only after it no longer
imports SwiftUI or AppKit and no longer depends on an observable UI store.

## Availability

During TurboCode 0.3.7 these sources are still compiled into the application
target. They are not yet a supported binary or Swift Package dependency, and
their access levels do not constitute a stable public API. The directory makes
the dependency direction explicit and lets the extraction be tested without a
session-data migration. A separately versioned package product will be declared
only after the runtime contract and compatibility matrix close.

## Intended host contract

A third-party host will own presentation and configuration. TurboCodeCore will
own turn admission, provider-session lifetime, streaming, cancellation,
transcript rebuild, and ordered persistence. Communication crosses the boundary
through Sendable commands, events, immutable snapshots, and async protocols:

```text
host UI / CLI / service
    -> runtime command
        -> TurboCodeCore runtime -> provider adapter

provider event + TurnID
    -> runtime validation
        -> immutable snapshot / structured receipt
            -> host-defined presentation
```

Hosts must not retain a concrete provider session or infer operation lifetime
from UI state. A host may render `ChatBlock` and its typed tool receipts however
it chooses; the core never constructs a SwiftUI view.

In the current contract, `ToolReceipt` travels inside the owning `ToolResult`.
Native Foundation Models structure and Codex dynamic-tool output are converted
once, at their adapter edges, into the same provider-neutral receipt. The host
projects that receipt only after `AgentRuntime` accepts its `TurnID`; there is
no parallel widget callback that can race a cancelled, restored, or newer turn.
`workspaceListing` is the first receipt case, and its immutable
`WorkspaceListingBlock` preserves the existing widget and session payload.

`ReasoningEffort` is a provider-neutral domain value. Hosts may persist or
present that intent, while a provider adapter alone translates it into a wire-
or SDK-specific option. The observable `ModelRuntimeStore` follows the same
rule: it emits immutable configuration and does not construct models, sessions,
title inference, benchmarks, or task workers.

## Session persistence in 0.3.7

`DiskConversationRepository` stores one `StoredSession` JSON document per
conversation. Repository methods are asynchronous at the boundary and disk
access is serialized by an actor, outside `MainActor`. Saves use Foundation's
atomic replacement option, so readers observe either the previous complete file
or the next complete file; this is not a database transaction or an fsync
durability guarantee.

Session identifiers become filenames. Empty identifiers and path syntax are
rejected before filesystem access. Callers must treat `StoredSession.schemaVersion`
as the compatibility discriminator and preserve unknown future schemas rather
than rewriting them.

The 0.3.7 extraction deliberately preserves schema 1, the `.json` filenames,
structured widget payloads, provider identifiers, and optional Foundation
Models transcript. There is no JSONL/SQLite migration and rollback requires
only reverting code.

## Planned package usage

The final module is expected to expose dependency-injected runtime and
persistence protocols with an application-owned composition root. The intended
shape is:

```swift
import TurboCodeCore

let repository: any ConversationRepository = DiskConversationRepository(
    directoryURL: sessionsURL
)
let runtime = AgentRuntime(
    backendFactory: hostBackendFactory,
    repository: repository
)

let turn = try await runtime.start(command)
for await event in turn.events {
    await presenter.consume(event)
}
```

This example documents direction, not an API available in 0.3.7. Exact public
initializers, error types, package platforms, semantic-versioning policy, and
provider adapter SPI must be frozen before third-party distribution.

## Future extension compatibility

TurboCodeCore is not a plugin SDK or RPC server in 0.3.7. Keeping its commands,
events, receipts, and snapshots provider- and presentation-neutral nevertheless
preserves a future option: an application-owned adapter could expose selected
capabilities to an out-of-process TypeScript host without giving plugins access
to SwiftUI, observable stores, credentials, or concrete provider sessions.

That later proposal must define a versioned canonical contract, capability and
permission negotiation, structured errors, bounded concurrency, cancellation,
timeouts, backpressure, and failure isolation before choosing a wire transport.
Tool-call extensions must cross the same approval and workspace policy boundary
as built-in tools. UX contributions must be declarative, schema-validated data
rendered in fixed host-owned surfaces; they are not arbitrary remote views.

These constraints are compatibility guidance, not current API commitments. No
plugin registry, TypeScript SDK, transport framing, RPC lifecycle, hot reload,
or extension UI is part of the 0.3.7 extraction or automatically part of 0.4.0.

## Extraction rules

- Core source files may import Foundation and explicitly approved model SDKs,
  but never SwiftUI, AppKit, Observation, or application views/view models.
- Mutable I/O and provider lifetime use actors or another explicit async owner;
  no mutex is used to conceal an ownership problem.
- Public boundary values are `Sendable`; UI updates are host projections on the
  host's chosen actor.
- Provider configuration and credentials are injected. TurboCodeCore never
  edits `~/.turbocode/models.json` or reads application-global singletons.
- Structured tool receipts remain typed and serializable so `@Generable`
  results can drive native or third-party widgets without text flattening.
- Every schema or public API change requires compatibility tests, migration and
  rollback notes, and a semantic-versioning decision.

## Current source layout

- `Domain/` contains provider- and UI-neutral values shared across the boundary,
  including backend identity, reasoning intent, and immutable structured tool
  payloads such as `WorkspaceListingBlock`.
- `Persistence/` contains schema-1 session records, the ordered disk repository,
  and UI-neutral async persistence use cases. Observable hosts apply returned
  values only after durable operations succeed.
- `Runtime/` contains the provider-neutral command/event vocabulary, typed
  `ToolReceipt` envelope, transient turn reducer, immutable snapshots, and
  actor-isolated operation owner.
- The Sendable `BackendSession` adapter port remains under `Services/Chat/`.
  Concrete native and Codex actors implement it outside this directory and
  publish through explicit MainActor output ports; moving those presentation
  bridges into the core would disguise rather than remove the dependency.

`TurboCodeCoreArchitectureTests` scans every Swift source in this tree for
forbidden UI, observable-store, MainActor, and concrete-provider dependencies.
That guard is temporary structural enforcement until a separate target makes
the same dependency direction compiler-enforced.

See the repository `TODO.md` section “0.3.7 — Complete LLM runtime/UI
decoupling” for the release gates. Until a package product is published, third
parties should treat this directory as architecture documentation rather than a
source-stable dependency.
