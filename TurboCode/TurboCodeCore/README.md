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

- `Domain/` contains provider- and UI-neutral values shared across the boundary.
- `Persistence/` contains schema-1 session records and the ordered disk
  repository.
- Runtime contracts and provider ports will join this tree only after their
  dependency audit proves they do not reach back into application state.

See the repository `TODO.md` section “0.3.7 — Complete LLM runtime/UI
decoupling” for the release gates. Until a package product is published, third
parties should treat this directory as architecture documentation rather than a
source-stable dependency.
