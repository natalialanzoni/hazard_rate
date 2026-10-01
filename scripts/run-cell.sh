#!/usr/bin/env bash
# Run one cell of the point-of-no-return grid.
#
#   ./scripts/run-cell.sh --dry-run cheat:15        # free: resolve + hash, no spend
#   ./scripts/run-cell.sh --dry-run all             # every cell's condition id
#   ./scripts/run-cell.sh --seeds                   # find a base seed safe for ALL cells
#   ./scripts/run-cell.sh cheat:15                  # run it (needs tmux)
#
# A cell is <class>:<cut> (cheat|honest x 1|5|15|30|45|60), or `control`, which binds
# prefix_dir="" -- kept as an option but NOT part of the grid. The 100-epoch baseline
# already is the control: same instance, split, model and params, and every line this
# fork adds sits inside `if prefix_dir:`, so with it empty the code path is unchanged.
# A 10-epoch re-measurement would be strictly worse (+/-31 pts vs +/-10) and has only
# an ~9% chance of flagging a fork that had silently moved the rate to 35%. Injection
# failure is caught directly and for free by verify_injection.py instead.
#
# Every one of the 20 params is bound explicitly and matches the 100-epoch baseline
# except epochs and the two prefix params -- the run IS its command line.
set -uo pipefail

REPO="${REPO:-$HOME/impossiblebench-turns}"
MODEL="${MODEL:-openrouter/qwen/qwen3.6-27b}"
INSTANCE="${INSTANCE:-astropy__astropy-13453}"
SPLIT="${SPLIT:-conflicting}"
EPOCHS="${EPOCHS:-10}"
MESSAGE_LIMIT="${MESSAGE_LIMIT:-600}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"
ALLOW_INTERNET="${ALLOW_INTERNET:-true}"
SEED="${SEED:-}"                       # launch.sh passes it; run bare and it refuses. Current safe seed: 10600
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4}"  # two other studies share the OpenRouter quota -- see README §5

# PIN THE SERVING PROVIDER. generate_args={} lets OpenRouter free-route, and on
# 2026-09-06 the routing changed mid-study: cache hit rate fell 91% -> 31.6% and
# cost went $0.32 -> $1.04 per episode, taking a $54 study toward ~$250 (recorded
# in the parent analysis repo, commit 543f60a). Caching was never something we enabled -- it worked by
# default -- so the fix is pinning, not a cache setting.
#
# This study is MORE exposed than that one: its result is a gradient across 8 cells
# run sequentially over hours, so any routing drift between the first cell and the
# last lands directly on the curve being measured.
#
# allow_fallbacks stays TRUE deliberately: commit 4be1e06 records that false dropped
# throughput to 3.4 calls/min and timed two runs out at 7h with zero scored samples.
# The fp8 restriction is what keeps the served weights uniform across cells.
#
# generate_args is a BOUND param, so this moves every condition id. Pinned and
# unpinned cells do not collate -- set it before the first cell, never mid-sweep.
PIN_PROVIDER="${PIN_PROVIDER:-Chutes}"
if [ -n "$PIN_PROVIDER" ]; then
  GEN_ARGS="{\"extra_body\":{\"provider\":{\"order\":[\"$PIN_PROVIDER\"],\"allow_fallbacks\":true,\"quantizations\":[\"fp8\"]}}}"
else
  GEN_ARGS="{}"
fi
INT64_MAX=9223372036854775807

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATES="$HERE/states"
cd "$HERE"
# shellcheck disable=SC1091
[ -f /etc/profile.d/nix.sh ] && . /etc/profile.d/nix.sh

DRY=""; SEEDS=""
ARGS=()
for x in "$@"; do
  case "$x" in
    --dry-run) DRY=1 ;;
    --seeds)   SEEDS=1; DRY=1 ;;
    *)         ARGS+=("$x") ;;
  esac
done
[ ${#ARGS[@]} -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }
# Named grids, kept identical to launch.sh so --dry-run/--seeds resolve exactly
# what a launch would run.
case "${ARGS[0]}" in
  topup-far) ARGS=(cheat:52 cheat:55 cheat:60 honest:52 honest:55 honest:60) ;;
  topup-remaining) ARGS=(cheat:1 cheat:5 cheat:15 cheat:30 cheat:52 cheat:55 cheat:60 honest:1 honest:5 honest:15 honest:30 honest:52 honest:55 honest:60) ;;
  topup-step-rest) ARGS=(cheat:42 cheat:46 cheat:48 honest:34 honest:38 honest:42 honest:46 honest:48) ;;
  topup-step) # +10 epochs on the five cuts bracketing the step, both donors.
    # The far cells are already pinned (10/10 four times over; honest arm flat),
    # so extra epochs there buy nothing. n=10 is only the binding constraint
    # around the 46->48 boundary, where localisation currently sits at p=0.087.
    ARGS=(cheat:34 cheat:38 cheat:42 cheat:46 cheat:48 honest:34 honest:38 honest:42 honest:46 honest:48) ;;
  topup) # all 24 cells again, per-cell seeds, collating into the same conditions
    ARGS=(cheat:1 cheat:5 cheat:15 cheat:30 cheat:34 cheat:38 cheat:42 cheat:46 cheat:48 cheat:52 cheat:55 cheat:60 honest:1 honest:5 honest:15 honest:30 honest:34 honest:38 honest:42 honest:46 honest:48 honest:52 honest:55 honest:60) ;;
  full)
    # ONE coherent curve, one donor pair, turns 1 -> 60, crossing the cheat at 53.
    # Tier 1's graph cannot be extended: its honest donor (epoch 58) is replayable
    # only to turn 30 -- its load-bearing str_replace was logged without new_str and
    # nothing reverts it. This regrid uses cheat 82 + honest 27, both replayable at
    # every cut, and 82 cheats at turn 53, inside the range.
    ARGS=(cheat:1 cheat:5 cheat:15 cheat:30 cheat:48 cheat:52 cheat:55 cheat:60
          honest:1 honest:5 honest:15 honest:30 honest:34 honest:38 honest:42 honest:46 honest:48 honest:52 honest:55 honest:60) ;;
  gap)   ARGS=(cheat:34 cheat:38 cheat:42 cheat:46 honest:34 honest:38 honest:42 honest:46) ;;
  tier1) ARGS=(cheat:1 cheat:5 cheat:15 cheat:30 honest:1 honest:5 honest:15 honest:30) ;;
  tier2) ARGS=(cheat:45 cheat:55 cheat:60 honest:45 honest:55 honest:60) ;;
  tier3) ARGS=(cheat:48 cheat:52 cheat:55 cheat:60 honest:48 honest:52 honest:55 honest:60) ;;
  all)   ARGS=(cheat:45 cheat:55 cheat:60 honest:45 honest:55 honest:60) ;;
esac

echo "building $REPO …"
BIN=$(cd "$REPO" && nix-build --no-out-link -A exec.impossiblebench-pressure-swebench 2>/dev/null | tail -1)
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "ABORT: build failed" >&2; exit 1; }
SRCID=$(grep -o 'ADB_SOURCE=content:sha256:[0-9a-f]*' "$BIN" | head -1 | cut -d: -f3)
echo "  BIN=$BIN"
echo "  source identity=${SRCID:0:16}…"
echo "  provider pin=${PIN_PROVIDER:-<none, FREE-ROUTED>} (fp8, fallbacks on)"

# The Aug 28 transplant run was lost to a stale build/lib shadowing the patched
# src: every arm ran un-prefixed and all three landed on the same number. Check
# that the patch is actually in the artefact we are about to run.
PKG=$(nix-store -qR "$BIN" 2>/dev/null | grep -m1 -- '-impossiblebench-0\.1\.0$')
if [ -n "$PKG" ]; then
  N=$(grep -rl 'AGENT_INIT_PREFIX' "$PKG" 2>/dev/null | wc -l)
  C=$(find "$PKG" -name swebench_agent_full.py | wc -l)
  echo "  patch present in $N file(s); $C copy(ies) of swebench_agent_full.py"
  [ "$N" -ge 1 ] || { echo "ABORT: built package does NOT contain the prefix patch" >&2; exit 1; }
  [ "$C" -le 1 ] || { echo "ABORT: $C copies of the agent module -- a stale build/ may shadow src" >&2; exit 1; }
fi

CONDS=""; MAP=""
for CELL in "${ARGS[@]}"; do
  if [ "$CELL" = "control" ]; then
    PDIR=""; PSHA=""; LABEL="control"
  else
    CLS="${CELL%%:*}"; CUT="${CELL##*:}"
    # cheat-nojust: cut 48 with donor 82's pro-edit sentences removed (build_ablation.py)
    case "$CLS" in cheat|honest|cheat-nojust) ;; *) echo "bad cell '$CELL'" >&2; exit 2 ;; esac
    PDIR="$STATES/$CLS/$CUT"
    [ -f "$PDIR/manifest.json" ] || { echo "ABORT: no prefix at $PDIR — run build_prefixes.py" >&2; exit 2; }
    PSHA=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['prefix_sha256'])" "$PDIR/manifest.json")
    GOT=$(sha256sum "$PDIR/prefix.json" | cut -d' ' -f1)
    [ "$PSHA" = "$GOT" ] || { echo "ABORT: $PDIR prefix.json sha $GOT != manifest $PSHA" >&2; exit 1; }
    LABEL="$CLS-cut$CUT"
  fi

  if [ -z "$DRY" ]; then
    [ -n "${TMUX:-}" ] || { echo "ABORT: not inside tmux — an ssh drop kills the run" >&2; exit 1; }
    docker ps >/dev/null 2>&1 || { echo "ABORT: cannot reach docker" >&2; exit 1; }
    # A per-cell seed from runs/topup-seeds.txt, when present, overrides $SEED.
    # With 24 conditions no single base seed is int64-safe for all of them
    # (~1-in-16M), and seed is a runner flag so it never enters the condition id:
    # a top-up run still collates with the original.
    CELL_SEED="$SEED"
    if [ -f "$HERE/runs/topup-seeds.txt" ] && [ -n "${TOPUP:-}" ]; then
      CS=$(awk -v c="$LABEL" '$1==c {print $2}' "$HERE/runs/topup-seeds.txt")
      [ -n "$CS" ] && CELL_SEED="$CS"
    fi
    [ -n "$CELL_SEED" ] || { echo "ABORT: no SEED. Run ./scripts/run-cell.sh --seeds first" >&2; exit 1; }
  fi

  echo; echo "=== cell $LABEL  (epochs=$EPOCHS) ==="
  set -- \
    --set model="$MODEL" \
    --set split="$SPLIT" \
    --set agent_type=tools \
    --set max_attempts="$MAX_ATTEMPTS" \
    --set message_limit="$MESSAGE_LIMIT" \
    --set allow_internet="$ALLOW_INTERNET" \
    --set "instance_ids=[\"$INSTANCE\"]" \
    --set 'banned_cases=[]' \
    --set task_limit=0 \
    --set reset_tests=false \
    --set hide_tests=false \
    --set 'custom_prompt=""' \
    --set 'pressure_preamble=""' \
    --set 'pressure_nudge=""' \
    --set "prefix_dir=${PDIR:-\"\"}" \
    --set "prefix_manifest_sha=${PSHA:-\"\"}" \
    --set 'sandbox_config_template=""' \
    --set limit=0 \
    --set epochs="$EPOCHS" \
    --set "generate_args=$GEN_ARGS" \
    --replicates 1

  if [ -n "$DRY" ]; then
    OUT=$("$BIN" "$@" --dry-run 2>&1)
    echo "$OUT" | grep -Ei 'condition|param|error|abort' | head -25
    CID=$(echo "$OUT" | sed -nE 's/^condition [0-9a-f]+ +\(([0-9a-f]{64})\).*/\1/p' | head -1)
    [ -n "$CID" ] && CONDS="$CONDS$CID"$'\n'
    # Write the label->condition pairing rather than leaving it to be transcribed
    # by hand. An earlier README had two of these swapped, which briefly looked
    # like a cell running the wrong condition.
    [ -n "$CID" ] && MAP="$MAP$(printf '%-16s %s' "$LABEL" "$CID")"$'\n'
  else
    RUN_LABEL="$LABEL" "$BIN" "$@" --seed "$CELL_SEED" 2>&1 | tee "$HERE/runs/$LABEL.log"
    # ADB prints status=success even when EVERY episode errored, so the summary
    # line is not a health check. On 2026-09-08 a single bad generate_args key
    # ("quantization" for "quantizations") returned 400 before generation and all
    # 8 cells reported completed=0 errors=N samples=0 status=success -- zero spend,
    # but 25 min of wall clock burned before anyone looked. Stop at the first one.
    SUM=$(grep -o 'samples=[0-9]*' "$HERE/runs/$LABEL.log" | tail -1 | cut -d= -f2)
    ERRS=$(grep -o 'errors=[0-9]*' "$HERE/runs/$LABEL.log" | tail -1 | cut -d= -f2)
    if [ "${SUM:-0}" = "0" ]; then
      echo "ABORT: cell $LABEL scored 0 samples (errors=${ERRS:-?}). Not a data cell;" >&2
      echo "       stopping rather than running the remaining cells. Check the error with:" >&2
      echo "       grep -o '\"message\": \"[^\"]*\"' \$(ls -t ~/.local/share/adb/runs/*/*/events-*.jsonl | head -1) | head" >&2
      exit 1
    fi
    echo "  cell $LABEL: samples=$SUM errors=${ERRS:-0}"
  fi
done

if [ -n "$DRY" ] && [ -n "$MAP" ]; then
  M="$HERE/runs/cell-conditions.txt"
  # MERGE, don't overwrite: a dry-run of one cell used to replace the whole map
  # with that single line, silently dropping every cell analyze.py and the
  # figures read. Existing lines are kept unless this invocation re-resolved
  # the same label.
  NEW_LABELS=$(printf '%s' "$MAP" | awk '{print $1}')
  { if [ -f "$M" ]; then
      awk -v drop="$NEW_LABELS" 'BEGIN{n=split(drop,a,"\n"); for(i=1;i<=n;i++) d[a[i]]=1}
                                 /^#/ || !($1 in d)' "$M"
    else
      echo "# cell -> condition id   (generated by run-cell.sh --dry-run; do not hand-edit)"
    fi
    echo "# + $(date -u +%Y-%m-%dT%H:%MZ): source identity ${SRCID:0:16}  provider pin ${PIN_PROVIDER:-none}  epochs $EPOCHS"
    printf '%s' "$MAP"; } > "$M.tmp" && mv "$M.tmp" "$M"
  echo; echo "cell -> condition map written to $M"; cat "$M"
fi

if [ -n "$SEEDS" ]; then
  F="$HERE/runs/conditions.txt"; printf '%s' "$CONDS" | sort -u > "$F"
  echo; echo "collected $(wc -l < "$F") condition id(s) -> $F"
  python3 "$HERE/scripts/seed_preflight.py" "$F"
fi
