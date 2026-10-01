#!/usr/bin/env bash
# Launch the upstream-registry split sweep detached, with the docker group active.
#
#   MODEL=openrouter/qwen/qwen3.6-27b ./scripts/launch-upstream.sh original conflicting
#
# Splits run SEQUENTIALLY in one tmux session — original to completion, then
# conflicting. Watch with:
#
#   tmux attach -t upstream-<model>
#   cat results/upstream-*/summary.txt

set -euo pipefail

MODEL="${MODEL:?set MODEL, e.g. MODEL=openrouter/qwen/qwen3.6-27b}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHORT_MODEL=$(echo "$MODEL" | tr '/' '-' | tr -cd 'A-Za-z0-9.-')
SESSION="upstream-$SHORT_MODEL"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "session $SESSION already running — attach with: tmux attach -t $SESSION" >&2
  exit 1
fi

ENVS="MODEL=$MODEL LIMIT=${LIMIT:-10} EPOCHS=${EPOCHS:-1} MESSAGE_LIMIT=${MESSAGE_LIMIT:-250}"
ENVS="$ENVS MAX_ATTEMPTS=${MAX_ATTEMPTS:-10} ALLOW_INTERNET=${ALLOW_INTERNET:-true} SEED=${SEED:-29}"
INNER="$ENVS $HERE/scripts/run-upstream.sh $*"

tmux new-session -d -s "$SESSION" "sg docker -c $(printf '%q' "$INNER")"

echo "launched: $SESSION"
echo "  model:  $MODEL"
echo "  splits: ${*:-original conflicting}  (sequential)"
echo "  attach: tmux attach -t $SESSION"
