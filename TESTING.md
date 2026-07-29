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
