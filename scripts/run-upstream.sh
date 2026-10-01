#!/usr/bin/env bash
# Run the UPSTREAM ADB registry `impossiblebench-swebench` over several splits,
# sequentially, with provenance capture and auto-collect.
#
#   MODEL=openrouter/qwen/qwen3.6-27b ./scripts/run-upstream.sh original conflicting
#   RUN_UPSTREAM_CHECK=1 ... ./scripts/run-upstream.sh original    # dry-run, free
#
# This is the registry experiment (9 params), NOT our fork (18 params). It exists to
# produce stock, paper-comparable transcripts. Differences that matter:
#
#   * no instance_ids / task_limit / banned_cases params. `limit` IS forwarded into
#     task_args by the registry adapter, and upstream applies it at
#     swebench_tasks.py:199 BEFORE image prep — so limit=10 pulls 10 images, not 349.
#   * with limit=10 the slice is the first 10 of the split, all astropy. Both splits
#     share the same ordering, so they cover the same instances.
#     django__django-15563 (the image that used to 404 and abort a whole run) is at
#     index 145, outside the slice.
#
# Why sequential: there is no retry plumbing (a 429 kills a sample outright) and two
# concurrent runs once exhausted OpenRouter's pooled quota. The second split also
# reuses the first's cached images, so serialising costs little wall-clock.
#
# Why the build is pinned once up front: --tarball-ttl 0 refetches registry `main`
# every call, so building per-split could silently give the two splits different
# source identities. One build, reused.

set -uo pipefail

SPLITS=("$@")
[ ${#SPLITS[@]} -gt 0 ] || SPLITS=(original conflicting)

MODEL="${MODEL:?set MODEL, e.g. MODEL=openrouter/qwen/qwen3.6-27b}"
LIMIT="${LIMIT:-10}"
EPOCHS="${EPOCHS:-1}"
MESSAGE_LIMIT="${MESSAGE_LIMIT:-250}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"
ALLOW_INTERNET="${ALLOW_INTERNET:-true}"
SEED="${SEED:-29}"
PER_SPLIT_TIMEOUT="${PER_SPLIT_TIMEOUT:-7h}"
INT64_MAX=9223372036854775807
REGISTRY="${REGISTRY:-https://github.com/antimemetics-institute/agentdatabank/archive/main.tar.gz}"

# shellcheck disable=SC1091
[ -f /etc/profile.d/nix.sh ] && . /etc/profile.d/nix.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# Model-I/O capture: NONE here. We run inspect DIRECTLY against OpenRouter (no
# proxy) — the custom wire-capture proxy was dropped 2026-08-13 (see
# archive/capture-proxy-dropped/README.md) because the inspect `.eval` log already
# stores a faithful, reconstructable record: per sample the full linear
# conversation (system + user + assistant + tool) with content in `attachments`,
# the tools schema per call, reasoning inside assistant `content` blocks, and
# response.id + provider per model call. Reconstruct for activations later with
#   scripts/reconstruct.py --from-eval <split>/arm-a.eval

for s in "${SPLITS[@]}"; do
  case "$s" in
    original|oneoff|conflicting) ;;
    *) echo "bad split '$s' (want original|oneoff|conflicting)" >&2; exit 2 ;;
  esac
done

if [ -z "${RUN_UPSTREAM_CHECK:-}" ]; then
  [ -n "${TMUX:-}" ] || { echo "ABORT: not inside tmux. Use ./scripts/launch-upstream.sh" >&2; exit 1; }
  docker ps >/dev/null 2>&1 || { echo "ABORT: cannot reach docker (launch via launch-upstream.sh, which wraps sg docker)" >&2; exit 1; }
fi

echo "building registry experiment (pinned once for all splits)…"
BIN=$(nix-build --no-out-link --tarball-ttl 0 "$REGISTRY" -A exec.impossiblebench-swebench 2>/dev/null | tail -1)
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "ABORT: registry build failed" >&2; exit 1; }
echo "  BIN=$BIN"

SHORT_MODEL=$(echo "$MODEL" | tr '/' '-' | tr -cd 'A-Za-z0-9.-')
STAMP=$(date +%Y%m%d-%H%M%S)
# n<LIMIT> = instances, ml<MESSAGE_LIMIT> = message cap. Both belong in the name:
# the cap is the thing being varied across sweeps, and without it two sweeps differ
# only by timestamp — which is useless when the point is comparing them.
SWEEP="$HERE/results/upstream-$SHORT_MODEL-n$LIMIT-ml$MESSAGE_LIMIT-e$EPOCHS-$STAMP"
SUMMARY="$SWEEP/summary.txt"
mkdir -p "$SWEEP"

{
  echo "upstream registry sweep  $STAMP"
  echo "  experiment    impossiblebench-swebench (registry main, 9 params)"
  echo "  BIN           $BIN"
  echo "  model         $MODEL"
  echo "  splits        ${SPLITS[*]}"
  echo "  limit         $LIMIT   epochs $EPOCHS   message_limit $MESSAGE_LIMIT"
  echo "  allow_internet $ALLOW_INTERNET   max_attempts $MAX_ATTEMPTS   seed $SEED"
  echo
} | tee "$SUMMARY"

for split in "${SPLITS[@]}"; do
  RUNDIR="$SWEEP/$split"
  mkdir -p "$RUNDIR"
  LOG="$RUNDIR/arm-a.log"   # collect.py looks for arm-{a,b,c}.log and finds the run id in it

  ARGS=(
    --seed "$SEED"
    --set split="$split"
    --set agent_type=tools
    --set max_attempts="$MAX_ATTEMPTS"
    --set message_limit="$MESSAGE_LIMIT"
    --set allow_internet="$ALLOW_INTERNET"
    --set model="$MODEL"
    --set limit="$LIMIT"
    --set epochs="$EPOCHS"
    --set 'generate_args={}'
  )

  # Seed preflight. ADB derives the model seed as an UNSIGNED 64-bit hash, so ~half of
  # all base seeds exceed int64 max; providers that validate reject with a 400 AFTER
  # image prep and ADB reports status=success with 0 samples. Four runs lost to this.
  CID=$("$BIN" "${ARGS[@]}" --dry-run 2>/dev/null | grep -oE '\([0-9a-f]{64}\)' | tr -d '()')
  if [ -z "$CID" ]; then
    echo "$split: SKIPPED — could not resolve condition id" | tee -a "$SUMMARY"; continue
  fi
  read -r VERDICT DERIVED SAFE <<<"$(python3 - "$SEED" "$CID" "$INT64_MAX" <<'PYEOF'
import hashlib, sys
seed, cid, mx = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = lambda b: int.from_bytes(hashlib.sha256(f"{b}:{cid}:1".encode()).digest()[:8], "big")
derived = d(seed)
safe = next((b for b in range(1, 10**7) if d(b) <= mx), 0)
print("ok" if derived <= mx else "unsafe", derived, safe)
PYEOF
)"
  if [ "$VERDICT" != ok ]; then
    echo "$split: SKIPPED — seed $SEED derives $DERIVED > int64 max; use SEED=$SAFE" | tee -a "$SUMMARY"
    continue
  fi

  { echo '{'
    echo "  \"experiment\": \"impossiblebench-swebench (registry main)\","
    echo "  \"bin\": \"$BIN\","
    echo "  \"started_at\": \"$(date -Is)\","
    echo "  \"model\": \"$MODEL\", \"split\": \"$split\","
    echo "  \"limit\": $LIMIT, \"epochs\": $EPOCHS, \"message_limit\": $MESSAGE_LIMIT,"
    echo "  \"allow_internet\": $ALLOW_INTERNET, \"seed\": \"$SEED\", \"condition\": \"$CID\","
    echo "  \"analysis_commit\": \"$(git rev-parse --short HEAD 2>/dev/null || echo unknown)\","
    echo -n '  "argv": '
    printf '%s\n' "$BIN" "${ARGS[@]}" | python3 -c 'import json,sys;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))'
    echo '}'
  } > "$RUNDIR/config.json"

  start=$SECONDS
  echo "=== $split  seed ok (derived $DERIVED)  started $(date -Is)" | tee -a "$SUMMARY"
  if [ -n "${RUN_UPSTREAM_CHECK:-}" ]; then
    "$BIN" "${ARGS[@]}" --dry-run >"$LOG" 2>&1; rc=$?
  else
    timeout "$PER_SPLIT_TIMEOUT" "$BIN" "${ARGS[@]}" >"$LOG" 2>&1; rc=$?
  fi
  dur=$(( SECONDS - start ))

  # Exit code alone is not enough: ADB exits 0 with status=success even when every
  # sample errored. Read the real counts.
  line=$(grep -o 'completed=[0-9]* errors=[0-9]* samples=[0-9]*[^—]*' "$LOG" | tail -1)
  n_smp=$(sed -n 's/.*samples=\([0-9]*\).*/\1/p' <<<"$line")
  n_err=$(sed -n 's/.*errors=\([0-9]*\).*/\1/p' <<<"$line")
  case $rc in
    124) st="TIMED OUT after $PER_SPLIT_TIMEOUT" ;;
    0)   if [ -z "${n_smp:-}" ]; then st="UNKNOWN — no summary line"
         elif [ "$n_smp" -eq 0 ]; then st="NO DATA — 0 samples, ${n_err:-?} errors"
         elif [ "${n_err:-0}" -gt 0 ]; then st="PARTIAL — $n_smp samples, $n_err errors"
         else st="ok — $n_smp samples"; fi ;;
    *)   st="FAILED rc=$rc" ;;
  esac
  [ -n "$line" ] && echo "    $line" >>"$SUMMARY"
  printf '%s  %s  %dm%02ds\n' "$split" "$st" $((dur/60)) $((dur%60)) | tee -a "$SUMMARY"

  [ -z "${RUN_UPSTREAM_CHECK:-}" ] && ./scripts/collect.py "$RUNDIR" 2>&1 | tee -a "$SUMMARY"
done

echo | tee -a "$SUMMARY"
echo "finished $(date -Is)" | tee -a "$SUMMARY"
echo "results: ${SWEEP#$HERE/}"
