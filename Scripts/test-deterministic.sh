#!/bin/zsh
set -euo pipefail

# The release gate names the model-backed suite explicitly so adding another
# deterministic test never requires maintaining an allowlist.
release_gate_derived_data="${TURBOCODE_DERIVED_DATA_PATH:-/tmp/TurboCodeDeterministicDerivedData}"

xcodebuild test \
    -project TurboCode.xcodeproj \
    -scheme TurboCodeEvaluations \
    -destination 'platform=macOS' \
    -derivedDataPath "$release_gate_derived_data" \
    -skip-testing:TurboCodeEvaluations/TurboCodeAgentEvaluationTests \
    CODE_SIGNING_ALLOWED=NO
