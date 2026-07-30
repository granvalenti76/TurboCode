# TurboCode Test Paths

TurboCode keeps deterministic release tests separate from model-backed golden
evaluations. This prevents Foundation Models availability or response variance
from blocking a release gate.

## Deterministic release gate

Run all Swift Testing suites except the model-backed evaluation suite:

```sh
Scripts/test-deterministic.sh
```

The command exits green or red without starting Foundation Models.

The deterministic gate includes the three M4.2 vertical scenarios in
`AgentEndToEndScenarioTests`: a revision-aware edit followed by verification, an
empty worker result with a single recovery action, and cancellation while a
worker tool is active. These scenarios inject a scripted response stream but
retain the production chat coordinator, `delegate_task` adapter, bounded runner,
editing service, Activity reducer, and timeline cleanup.

## Optional golden evaluations

Run only the experimental on-device evaluation suite:

```sh
Scripts/test-golden.sh
```

Each golden has a two-minute Swift Testing limit. The command also enables
Xcode's test timeout with a 150-second maximum allowance so an unresponsive
model runtime cannot leave the test process running indefinitely.

Set `TURBOCODE_DERIVED_DATA_PATH` to use a different Derived Data directory for
either command.
