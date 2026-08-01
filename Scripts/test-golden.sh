#!/bin/zsh
set -euo pipefail

# Golden evaluations are deliberately separate from the release gate. Xcode's
# hard allowance bounds the process even if a model runtime ignores cancellation.
golden_derived_data="${TURBOCODE_DERIVED_DATA_PATH:-/tmp/TurboCodeGoldenDerivedData}"

xcodebuild test \
    -project TurboCode.xcodeproj \
    -scheme TurboCodeEvaluations \
    -destination 'platform=macOS' \
    -derivedDataPath "$golden_derived_data" \
    -only-testing:TurboCodeEvaluations/TurboCodeAgentEvaluationTests \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 150 \
    CODE_SIGNING_ALLOWED=NO
