#!/usr/bin/env bash
# Start llama-server with the settings I use with TurboCode.
#
# The configuration is opinionated on purpose: one fixed set of flags gives a
# reproducible result, so a problem can be compared against a known setup.
# See LLAMA_SERVER.md for why each flag is there.
#
# Usage:
#   MODEL=/path/to/model.gguf Scripts/turbocode-llama-server.sh
#   MODEL=... MMPROJ=/path/to/mmproj.gguf Scripts/turbocode-llama-server.sh
#   MODEL=... Scripts/turbocode-llama-server.sh -- --temp 0.8
#   MODEL=... DRY_RUN=1 Scripts/turbocode-llama-server.sh
#
# Arguments after -- are passed to llama-server unchanged and override the
# defaults below, because llama-server keeps the last value of a repeated flag.
#
# Environment variables:
#   MODEL         GGUF model file (required)
#   MMPROJ        vision projector GGUF; set it to enable image input
#   LLAMA_SERVER  llama-server binary (default: llama-server from PATH)
#   HOST          listen address (default: 127.0.0.1, this Mac only;
#                 use 0.0.0.0 to serve other machines on your network)
#   PORT          listen port (default: 8080, one of the ports TurboCode
#                 probes on first launch)
#   CTX           context window in tokens (default: 32768)
#   KV            KV cache type for K and V: f16 q8_0 q5_1 q5_0 q4_1 q4_0
#                 iq4_nl (default: q4_0)
#   EFFORT        starting reasoning effort (default: low); TurboCode changes
#                 it per request from the composer
#   DRY_RUN=1     print the command instead of starting the server
#
# Written for the bash 3.2 that ships with macOS: no associative arrays and no
# ${var,,} case conversion.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

EXTRA=()
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --)        shift; EXTRA=("$@"); break ;;
    *)         echo "unknown argument: $1 (pass llama-server flags after --, see -h)" >&2; exit 1 ;;
  esac
done

LLAMA_SERVER=${LLAMA_SERVER:-llama-server}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}
CTX=${CTX:-32768}
KV=${KV:-q4_0}
EFFORT=${EFFORT:-low}
MMPROJ=${MMPROJ:-}

[[ -n ${MODEL:-} ]] || { echo "set MODEL to a .gguf file (see -h)" >&2; exit 1; }
[[ -f $MODEL ]] || { echo "model not found: $MODEL" >&2; exit 1; }
[[ $CTX =~ ^[0-9]+$ ]] || { echo "CTX must be a number of tokens, such as 32768" >&2; exit 1; }
case $KV in
  f16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl) ;;
  *) echo "unsupported KV cache type: $KV" >&2; exit 1 ;;
esac

if [[ -n $MMPROJ ]]; then
  [[ -f $MMPROJ ]] || { echo "vision projector not found: $MMPROJ" >&2; exit 1; }
  VISION_ARGS=(--mmproj "$MMPROJ")
else
  # --no-mmproj stops llama-server from loading a projector on its own, so
  # /props reports no vision and TurboCode does not offer image input.
  VISION_ARGS=(--no-mmproj)
fi

if [[ ${DRY_RUN:-0} != 1 ]] &&! command -v "$LLAMA_SERVER" >/dev/null 2>&1; then
  echo "llama-server not found: $LLAMA_SERVER (set LLAMA_SERVER to the binary)" >&2
  exit 1
fi

# Not passed on purpose: --props. GET /props, which TurboCode reads, works
# without it; the flag only enables POST /props, which lets any client change
# the server's global settings.
CMD=("$LLAMA_SERVER"
  -m "$MODEL"
  -c "$CTX"
  # One slot: the whole context belongs to one conversation and its prompt
  # cache survives between turns.
  -np 1
  -fa on
  --cache-type-k "$KV"
  --cache-type-v "$KV"
  # --jinja runs the model's own chat template, needed for tool calls and for
  # the reasoning levels /props reports.
  --jinja
  --reasoning on
  --reasoning-preserve
  --reasoning-effort "$EFFORT"
  --temp 0.6
  --top-k 20
  --top-p 1
  --min-p 0.0
  --presence-penalty 0.0
  --repeat-penalty 1.0
  # Read the whole model into memory at startup instead of memory-mapping it.
  --load-mode none
  --metrics
  --host "$HOST"
  --port "$PORT"
  "${VISION_ARGS[@]}"
  ${EXTRA[@]+"${EXTRA[@]}"})

if [[ ${DRY_RUN:-0} == 1 ]]; then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
exec "${CMD[@]}"
