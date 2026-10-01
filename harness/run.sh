#!/usr/bin/env bash
# Run one experimental arm into its own self-describing output folder.
#
#   ./run.sh run-urgency-noreset.json
#
# Produces output/<UTC-timestamp>-<arm>/ containing:
#   config.json      the exact config this run used (copied, not referenced)
#   manifest.json    git commit + dirty flag, model, key fingerprint, code hash
#   events.jsonl     the ADB event stream (what normally scrolls past in the terminal)
#   inspect-logs/    the inspect .eval log — the real transcript
#   artifacts/       run.eval (a copy of the .eval)
#
# Why a wrapper: adb-inspect-eval writes inspect-logs/ relative to $PWD and artifacts/
# relative to $ADB_RUN_DIR, so without this every run lands in the same two folders and
# artifacts/run.eval (a fixed filename) gets overwritten by the next run.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="${1:-}"
[ -n "$cfg" ] || { echo "usage: ./run.sh <config.json>" >&2; exit 2; }
[ -f "$cfg" ] || { echo "no such config: $cfg" >&2; exit 2; }
cfg="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"

vendor="$repo/vendor-impossiblebench/src/impossiblebench"
installed="$repo/.venv/lib/python3.13/site-packages/impossiblebench"

hash_pkg() {  # content hash of a package's .py files, path-independent
  ( cd "$1" && find . -name '*.py' -print0 | sort -z \
      | xargs -0 shasum -a 256 | awk '{print $1}' | shasum -a 256 | cut -d' ' -f1 )
}

# --- guard: the venv holds a COPY of vendor-impossiblebench, not a link. Editing the
# vendor source or switching branches without re-syncing silently runs the wrong code,
# which is the easiest way to mislabel an experimental arm. Refuse rather than warn.
vh="$(hash_pkg "$vendor")"; ih="$(hash_pkg "$installed")"
if [ "$vh" != "$ih" ]; then
  echo "ERROR: .venv is out of sync with vendor-impossiblebench/" >&2
  echo "  vendor source : $vh" >&2
  echo "  installed     : $ih" >&2
  echo "  fix: nix-shell -p uv git --run 'uv sync --reinstall-package impossiblebench'" >&2
  exit 1
fi

# --- credentials. providers.toml is the source of truth, NOT the ambient environment.
# adb-runner injects providers.toml as a base and lets the host env override; going
# around it we invert that deliberately, because a stale inherited OPENROUTER_API_KEY
# (e.g. frozen into a long-running editor process) silently bills the wrong account and
# the run still succeeds, so nothing surfaces the mistake. Override explicitly with
# ADB_FORCE_ENV_KEY=1 if you really mean to use the ambient one.
toml_key="$(python3 -c "import tomllib,pathlib;print(tomllib.load(open(pathlib.Path.home()/'.config/adb/providers.toml','rb'))['openrouter']['OPENROUTER_API_KEY'])" 2>/dev/null || true)"
fp() { printf %s "$1" | shasum -a 256 | cut -c1-12; }
if [ -n "${ADB_FORCE_ENV_KEY:-}" ]; then
  : "${OPENROUTER_API_KEY:?ADB_FORCE_ENV_KEY set but OPENROUTER_API_KEY is empty}"
elif [ -n "$toml_key" ]; then
  if [ -n "${OPENROUTER_API_KEY:-}" ] && [ "$OPENROUTER_API_KEY" != "$toml_key" ]; then
    echo "  note: ignoring ambient OPENROUTER_API_KEY ($(fp "$OPENROUTER_API_KEY")) in favour of providers.toml ($(fp "$toml_key"))" >&2
  fi
  OPENROUTER_API_KEY="$toml_key"; export OPENROUTER_API_KEY
else
  : "${OPENROUTER_API_KEY:?no [openrouter] key in providers.toml and none in the environment}"
fi
key_fp="$(fp "$OPENROUTER_API_KEY")"

arm="$(basename "$cfg" .json)"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$repo/output/$ts-$arm"
mkdir -p "$out"
cp "$cfg" "$out/config.json"

commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
dirty=false; [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && dirty=true

python3 - "$out/manifest.json" "$ts" "$arm" "$commit" "$branch" "$dirty" "$vh" "$key_fp" "$cfg" <<'PY'
import json, sys
p, ts, arm, commit, branch, dirty, code_hash, key_fp, cfg = sys.argv[1:10]
json.dump({
    "arm": arm, "started_utc": ts, "config_source": cfg,
    "git": {"commit": commit, "branch": branch, "dirty": dirty == "true"},
    "code_sha256": code_hash,
    "openrouter_key_fp": key_fp,
    "note": "code_sha256 hashes vendor-impossiblebench/**/*.py and is verified equal to "
            "the installed copy before the run; git.dirty=true means the tree had "
            "uncommitted changes, so commit alone does not reproduce this run.",
}, open(p, "w"), indent=2)
PY

echo "→ $out"
[ "$dirty" = true ] && echo "  WARNING: working tree is dirty — commit before a run you intend to cite" >&2

export ADB_RUN_DIR="$out"
cd "$out"

# DRYRUN=1 ./run.sh <cfg> — do every pre-flight check and lay down the output folder,
# but don't call the model. Use it to verify a new arm costs nothing to get wrong.
if [ -n "${DRYRUN:-}" ]; then
  echo "(dry run — pre-flight passed, no eval launched)" | tee events.jsonl
  exit 0
fi

"$repo/.venv/bin/adb-inspect-eval" "$out/config.json" 2>&1 | tee events.jsonl
