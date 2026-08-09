# Task Delegation Feature Plan

This document defines the next release slice for user-controlled delegated
tasks. The current implementation stops at the Activity entry point and the
existing `delegate_task` runtime path; the manual task flow below is a plan,
not an implemented contract.

## Product outcome

Make delegated work discoverable without competing with the conversation. A
user should be able to see whether a subagent is active, inspect what it is
doing, and later create a bounded subtask from the same surface when the
workflow is ready.

## UX direction

### Entry point

- Keep one persistent toolbar icon beside Changes/Inspector.
- Use an SF Symbol that communicates multiple agents, with a tooltip and an
  accessibility label such as “Delegated task activity”.
- The icon must remain available when no task is active so the surface is
  discoverable and does not shift layout during a run.
- Opening the icon reuses the existing Activity inspector for a live delegated
  attempt. With no active attempt, show a calm empty state explaining that
  delegated activity will appear here.

### Progressive disclosure

The first surface should answer only “is anything delegated, what is it doing,
and where is it going?”. Keep the full task text, route/model details, active
tool, verification receipt, and technical output behind the existing disclosure
controls. Add “Create subtask” below the current activity summary only after
the read-only surface is stable.

### HIG and accessibility constraints

- Prefer native toolbar buttons, SF Symbols, tooltips, keyboard focus, and
  VoiceOver labels over custom badges or persistent banners.
- Do not use color alone to communicate phase; retain the existing labels and
  symbols for success, failure, cancellation, and active work.
- Respect Reduce Motion and keep the inspector width and navigation behavior
  consistent with the existing Changes panel.
- The create flow must not steal focus from the composer unless the user
  explicitly invokes it.
- Keep destructive or workspace-mutating actions behind the existing approval,
  scope, revision, and review gates.

## Functional design

### Phase 1 — Activity entry point (current slice)

1. Show the delegated-activity icon persistently beside the Changes icon.
2. Open the current `AgentActivity` inspector when an attempt exists.
3. Show an informative empty state when there is no active attempt.
4. Preserve the existing automatic opening when delegation starts and the
   existing explicit-close behavior.

### Phase 2 — Subtask composer

The future “Create subtask” action should open a native sheet with a clear
two-step flow: define the task, then review the execution summary before
starting it. A popover is appropriate for a small picker, but the complete
form needs the space and explicit commit point of a sheet.

#### Step A — Define the task

- a required goal, focused on the outcome rather than provider instructions;
- optional acceptance criteria, with one criterion required when the goal is
  ambiguous or mutation-capable;
- a bounded workspace scope, defaulting to the current task scope when the
  action is launched from an existing task;
- an agent picker limited to configured and compatible worker agents;
- a verification choice, defaulting to the safest applicable option;
- an “Advanced limits” disclosure for timeout and maximum tool calls, with
  conservative defaults and inline validation.

#### Step B — Review and start

The review area should show the exact typed envelope that will be executed in
human-readable form:

- selected agent and role;
- allowed capabilities derived by TurboCode, not arbitrary model text;
- workspace scope and verification target;
- execution limits;
- a primary “Start subtask” action and a secondary Cancel action.

The primary action must be disabled until the envelope validates. Starting a
task closes the sheet, opens Activity, and presents the same live lifecycle
used by model-created delegation. The user should not need to paste the task
into the composer or create a synthetic chat message.

The action should create a typed `AgentTaskEnvelope`, run through the existing
bounded task runner, and feed the same `AgentActivityStore` lifecycle. It must
not accept free-form provider instructions as a substitute for the typed
envelope.

#### Agent selection rules

Manual selection chooses from configured worker profiles, not raw provider
endpoints. The list should expose the agent name, provider/model, role, and a
short capability summary. Unavailable, disabled, or incompatible profiles are
shown as disabled with a reason when that reason is actionable. The form must
not silently fall back to another agent after the user confirms a choice; if a
selected agent becomes unavailable, fail before starting and ask the user to
choose again.

#### Scope rules

Scope is a safety control, not an implementation hint. The form should show
the active workspace and let the user choose explicit workspace-relative files
or folders. A task launched from another task inherits its declared scope and
may narrow it, but may not widen it without an explicit user action. The
serialized envelope remains the source of truth for `AgentTaskPathScope`.

The first version should offer a deliberate “Entire workspace” option only
when the workspace is already trusted and the user confirms it in the review
step. The default should be the narrowest useful scope.

#### Verification rules

- `None` is available for read-only or exploratory tasks.
- `Build` and `Test` are available only when the selected agent can use the
  relevant Xcode capability and a valid workspace container is discoverable.
- The form should preserve optional container, scheme, configuration, and
  destination values in `AgentVerificationParameters`.
- Passing verification is determined by the deterministic verifier and its
  receipt, never by the worker's final prose.

#### Active-task behavior

The first manual-task release should support one active delegated attempt per
conversation because `AgentActivityStore` currently models one current task.
While one task is active, “Create subtask” becomes “Task already running” and
offers “Show activity”; it must not silently queue or replace the running task.
Multiple concurrent subtasks require the task ledger described in Phase 3.

Cancellation remains available from Activity and must use the existing runner
cancellation path. Closing the inspector only hides it; it does not cancel the
task.

### Phase 2.5 — Manual task record and lifecycle boundary

Before wiring the form to the runner, introduce a small provider-neutral task
record separate from the live `AgentActivity` snapshot. It should include:

- `taskID`, `attemptID`, optional `parentTaskID`, and conversation ID;
- creation source (`manual` or `modelDelegated`);
- the validated envelope and selected agent snapshot;
- lifecycle timestamps and terminal outcome;
- verification receipt IDs and a compact user-facing result;
- cancellation and failure details suitable for restoration.

The record is needed so a manually created task can survive inspector closure,
produce a stable timeline receipt, and prevent late callbacks from mutating a
new task. It should not persist provider transcripts or credentials.

The live store can continue to own only the current operational snapshot. A
future ledger can own records and history without changing the Activity view's
phase semantics.

### Phase 3 — Multiple and historical subtasks

Supporting multiple simultaneous or historical subtasks requires the explicit
task ledger keyed by task and attempt identity. The ledger must define:

- ordering and grouping by parent task;
- one active attempt versus terminal records;
- retention limits and session ownership;
- cancellation and restart semantics;
- late-event rejection and tombstoning;
- persistence and migration of old sessions;
- which records are visible in the Activity overview versus the chat timeline.

Only after these rules exist should the empty Activity state become a list of
recent subtasks or expose nested “Create subtask” actions.

## State and safety invariants

- A task has one stable task/attempt identity; late provider events cannot
  resurrect or mutate another task.
- Activity is operational state, not a second transcript. Tool receipts remain
  in the chat timeline.
- Worker tools remain constrained by the typed task scope and capability plan.
- Verification owns the terminal success state; prose from a worker cannot mark
  a task complete.
- Session changes close conversation-local Activity presentation and cancel or
  tombstone old callbacks according to the existing store rules.
- Manual task creation is an explicit user action and is never inferred from
  ordinary composer text.
- A task record is immutable after terminal completion except for presentation
  metadata such as dismissal or pinning.

## Acceptance criteria for the full feature

- A user can discover, inspect, create, cancel, and review a bounded subtask
  without leaving the workbench.
- The form has a visible review/confirm step and never starts a task from a
  partially valid or silently broadened configuration.
- The selected agent is visibly compatible with the requested tools and scope.
- Empty, active, succeeded, failed, and cancelled states are understandable
  without relying on model-generated prose.
- Keyboard navigation and VoiceOver expose the same actions as pointer input.
- Focused tests cover state transitions, agent selection, scope enforcement,
  cancellation, session switching, and the native presentation path.

## Implementation order

1. Extract an agent-selection snapshot from the existing runtime/profile
   configuration without exposing credentials.
2. Add a pure form model and validation reducer for goal, criteria, scope,
   agent, verification, and budget.
3. Add the manual task record and a coordinator that invokes the existing
   `ConfiguredAgentTaskInvoker`/`BoundedAgentTaskRunner` path.
4. Add the native sheet and review step, then connect Start/Cancel to the
   coordinator.
5. Add the Activity receipt and session persistence boundary.
6. Test the full lifecycle with fake agents before enabling the UI by default.
