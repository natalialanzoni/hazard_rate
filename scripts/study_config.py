#!/usr/bin/env python3
"""Which task the study scripts operate on, and where its data lives.

    TURNS_INSTANCE=astropy__astropy-14182 scripts/trajectory_profile.py

Default is astropy-13453, so every existing invocation behaves exactly as before.

Why a config module rather than a second copy of the scripts: the 13453 study
accumulated a dozen corrections (the test-edit detector, the replay planner's
revert pruning, the scorer's per-submit mutation, the task-setup commit). A fork
would strand all of that on one task. Adding a task should be data, not code.

BASELINE evals are a LIST: a task's stock samples may span several runs at
identical config. 13453's come from one 100-epoch run.
"""
from __future__ import annotations
import glob, json, os, zipfile
from pathlib import Path

INSTANCE = os.environ.get("TURNS_INSTANCE", "astropy__astropy-13453")
# Where ADB run records live. Defaults to the copy committed in this repo
# (data/adb-runs, same layout as ~/.local/share/adb/runs); set ADB_RUNS to
# point at a live ADB store instead.
RUNS = Path(os.environ.get("ADB_RUNS", Path(__file__).resolve().parents[1]/"data/adb-runs"))


# The stock cell every donor must come from. Matching the instance and split is
# NOT enough: this box has 13453 runs from the steering study (served locally via
# openai/, different sampler), the compaction study (compaction_dir set), pressure
# arms, and reset_tests variants. Pooling those gave 484/799 = 0.61 where the
# actual stock baseline is 49/100 = 0.49 -- a 12-point contamination that would
# have gone straight into donor selection.
STOCK = {
    "model": "openrouter/qwen/qwen3.6-27b",
    "message_limit": 600,
    "max_attempts": 10,
    "allow_internet": True,
    "reset_tests": False,
    "hide_tests": False,
    "split": "conflicting",
}
# Any of these being set means the run carries an extra manipulation. Matching by
# NAME PREFIX, not an exact list: the first version named only "prefix_dir" (this
# study's param) and every cross-run transplant arm -- which spells it
# "prefill_dir", one letter apart -- sailed through as a stock baseline. That put
# 90 transplant samples into a supposed 14182 baseline and produced a donor pool
# out of episodes whose visible task was some OTHER instance.
MANIPULATION_PREFIXES = ("prefix_", "prefill_", "compaction_", "pressure_",
                         "custom_prompt", "sandbox_config_template", "dummy")


def _manipulated(p: dict) -> bool:
    return any(v for k, v in p.items()
               if any(k.startswith(mp) for mp in MANIPULATION_PREFIXES))


def _discover(instance: str) -> list[Path]:
    """Completed runs of `instance` in the STOCK cell, largest first."""
    out = []
    for rj in glob.glob(str(RUNS/"*/*/run.json")):
        try:
            d = json.loads(Path(rj).read_text())
        except Exception:
            continue
        p = d.get("realized_params") or {}
        if (p.get("instance_ids") or [None])[0] != instance:
            continue
        if _manipulated(p):
            continue
        if any(p.get(k) != v for k, v in STOCK.items()):
            continue
        ev = Path(rj).parent/"artifacts"/"run.eval"
        if not ev.exists():
            continue
        try:
            n = sum(1 for x in zipfile.ZipFile(ev).namelist() if x.startswith("samples/"))
        except Exception:
            continue
        out.append((n, ev))
    return [ev for _, ev in sorted(out, key=lambda t: -t[0])]


SHORT = INSTANCE.split("-")[-1]                      # 13453, 14182
IMAGE = f"swebench/sweb.eval.x86_64.{INSTANCE.replace('__', '_1776_')}:latest"
ROOT = Path(__file__).resolve().parents[1]
# ADB store only. The earlier `+ _discover_results(INSTANCE)` also globbed
# ../results/, where a copy of the 13453 100-epoch run sits -- every sample
# was counted twice (220 pooled instead of 120 distinct).
BASELINES = _discover(INSTANCE)
# 13453 keeps the original flat layout so its committed data stays put; any other
# task gets its own subtree.
STATES = ROOT/"states" if SHORT == "13453" else ROOT/"states"/SHORT
RUNS_DIR = ROOT/"runs" if SHORT == "13453" else ROOT/"runs"/SHORT


def samples(evals=None, instance=None):
    """Yield (sample dict, source eval) for THIS instance across every baseline.

    Filtering by sample id matters for the results/ sweeps, where one .eval holds
    several instances.
    """
    want = instance or INSTANCE
    for ev in (evals or BASELINES):
        z = zipfile.ZipFile(ev)
        for nm in z.namelist():
            if not nm.startswith("samples/"):
                continue
            s = json.loads(z.read(nm))
            if s.get("id") and s["id"] != want:
                continue
            yield s, ev


if __name__ == "__main__":
    print(f"instance : {INSTANCE}")
    print(f"image    : {IMAGE}")
    print(f"states   : {STATES}")
    print(f"baselines: {len(BASELINES)} run(s)")
    n = k = 0
    for s, _ in samples():
        n += 1
        sc = s.get("scores") or {}
        if sc and sc[list(sc)[0]].get("value") == 1.0:
            k += 1
    print(f"pooled   : {k}/{n} = {k/n:.2f}" if n else "pooled   : no samples")
