#!/usr/bin/env python3
"""Find a base seed safe for EVERY condition in the study. CPU only, free.

    scripts/seed_preflight.py <conditions.txt>      # one condition id per line
    ./scripts/run-compaction.sh --seeds             # collects the ids and calls this

WHY THIS EXISTS. ADB derives the per-run model seed as an UNSIGNED 64-bit hash of
`<base_seed>:<condition_id>:<replicate>`, so about half of all base seeds exceed int64 max
for any given condition. The provider rejects those with a 400 AFTER image preparation, and
ADB then reports status=success with 0 samples. Four runs were lost to this before the
preflight existed.

The catch a per-arm preflight misses: the derived seed depends on the CONDITION, so a seed
safe for one arm is unsafe for another. With 11 conditions, a randomly chosen seed has about
a 1-in-2000 chance of being safe for all of them. Searching is instant; guessing is not.

Using a different seed per arm would also work -- seed is a runner flag, not a bound param,
so it never enters the condition id -- but a single seed across arms keeps the record simple
and removes any question of seed-shopping between conditions.
"""
from __future__ import annotations
import hashlib, sys
from pathlib import Path

INT64_MAX = 9223372036854775807


def derived(base: int | str, cid: str, replicate: int = 1) -> int:
    return int.from_bytes(
        hashlib.sha256(f"{base}:{cid}:{replicate}".encode()).digest()[:8], "big")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    lines = [l.split() for l in Path(sys.argv[1]).read_text().splitlines() if l.strip()]
    conds = [(p[0], p[1] if len(p) > 1 else "") for p in lines]
    print(f"{len(conds)} conditions\n")

    for base in range(1, 10 ** 6):
        if all(derived(base, cid) <= INT64_MAX for cid, _ in conds):
            print(f"SAFE BASE SEED: {base}\n")
            print(f"  {'condition':<16}{'arm':<18}{'derived seed':>22}  ok")
            for cid, arm in conds:
                d = derived(base, cid)
                print(f"  {cid[:12]:<16}{arm:<18}{d:>22}  {'yes' if d <= INT64_MAX else 'NO'}")
            print(f"\nUse: SEED={base} ./scripts/launch-compaction.sh …")
            print("Re-run this after ANY fork edit or epochs change — the condition ids move,")
            print("and a seed safe for one set is not safe for the next.")
            return 0
    print("no safe seed found below 1e6 — that should be impossible; check the ids")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
