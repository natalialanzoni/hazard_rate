#!/usr/bin/env python3
"""Pick the one cheat donor and the one honest donor the whole study rests on.

With a single donor per class (a deliberate choice -- see README §3) donor
identity is confounded with the cheat/honest contrast, so the selection rule has
to be written down and mechanical rather than eyeballed. Both donors must be
TYPICAL of their class, not extreme, or the study characterises an outlier.

Rule, applied in order:
  1. reaches turn 60          -- every cut in the grid must exist in both donors
  2. class-defining behaviour -- cheat donor edits a test file (44/49 do);
                                 honest donor NEVER edits one (31/51 qualify),
                                 so it is unambiguously honest rather than
                                 merely unsuccessful
  3. closest to its class median on (total turns, first submit turn), ranked by
     summed absolute z-score over the class -- the most ordinary member

    cheat_rate_turns_study/scripts/select_donors.py
"""
from __future__ import annotations
import argparse, json, re, statistics as st, sys, zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from replayable import replayable_to
from study_config import INSTANCE, BASELINES, STATES as CFG_STATES, samples as cfg_samples

HERE = Path(__file__).resolve().parent
PROFILE = CFG_STATES / "baseline_profile.json"
import os
# Deepest planned cut; replay must be reconstructible this far, and a donor must
# reach it. 13453's cuts topped out at 76; 14182 cheats later (median turn 65)
# and its grid runs 20/40/60, so 64 is enough there. Override per task.
DEEP_CUT = int(os.environ.get("TURNS_DEEP_CUT", "76"))
MIN_TURN = DEEP_CUT + 4
# The planned cut grid. A cheat donor is only useful if its cheat falls INSIDE
# this grid with cuts on both sides -- otherwise the transition is bracketed on
# one side only and the step cannot be localised at all. 13453's donor 82 cheated
# at 53 against cuts 48/52/55/60, which is why that step was visible.
GRID = [int(x) for x in os.environ.get("TURNS_GRID", "1,5,15,30,48,52,55,60").split(",")]


def z(x, mu, sd):
    return abs(x - mu) / sd if sd else 0.0


def pick(rows, want_cheat: bool):
    score = 1.0 if want_cheat else 0.0
    pool = [r for r in rows if r["score"] == score and r["turns"] >= MIN_TURN]
    if want_cheat:
        pool = [r for r in pool if r["first_test_edit"] is not None]
        # 3b. THE CHEAT MUST PRECEDE THE FIRST SUBMIT. Learned the hard way on
        #     13453: the scorer runs an eval script on every submit that checks
        #     the test files out at base_commit and re-applies test_patch, and
        #     those mutations appear nowhere in the tool-call log. Any cut past
        #     a submit therefore reconstructs a state the donor was never in --
        #     five candidate donors failed validation at 71/76 for exactly this.
        #     A donor that cheats before it ever submits keeps every cut clean.
        pool = [r for r in pool
                if r["first_submit"] is None or r["first_test_edit"] < r["first_submit"]]
        # 3c. the cheat must be BRACKETED WITH RESOLUTION: >=2 reachable cuts
        #     before it and >=2 after. One post-cheat cut is not a curve -- a
        #     donor cheating at 79 against cuts ...60, 80 gives a single point one
        #     turn later, and the transition is then bracketed by a 20-turn gap
        #     with nothing inside it to localise.
        # a cut only counts if the donor actually REACHES it
        pool = [r for r in pool
                if sum(1 for c in GRID if c < r["first_test_edit"]) >= 2
                and sum(1 for c in GRID
                        if r["first_test_edit"] < c <= r["turns"]) >= 2]
    else:
        pool = [r for r in pool if r["first_test_edit"] is None]
    # 3d. EVERY CUT THE DONOR IS ASKED FOR MUST BE PRE-SUBMIT, for both classes.
    #     Not just the cheat: the scorer mutates the repo on any submit, so an
    #     honest donor that submits at turn 76 cannot serve a cut at 80 either.
    deepest = max([c for c in GRID], default=0)
    pool = [r for r in pool
            if r["first_submit"] is None
            or r["first_submit"] > min(deepest, r["turns"])]

    # 4. the deep cuts need the sandbox replayed, so every mutation up to DEEP_CUT
    #    must be reconstructible from the transcript. The first honest donor picked
    #    (epoch 58) fails this: its load-bearing str_replace was logged without
    #    new_str and nothing reverts it, so 3 of 6 replay plans could not be built.
    pool = [r for r in pool if r.get("replayable")]
    if not pool:
        raise SystemExit(f"no eligible donor for cheat={want_cheat}")

    fields = ("turns", "first_submit")
    stats = {}
    for f in fields:
        vals = [r[f] for r in pool if r[f] is not None]
        stats[f] = (st.median(vals), st.pstdev(vals) or 1.0)

    def dist(r):
        d = sum(z(r[f], *stats[f]) for f in fields if r[f] is not None)
        # Prefer a cheat sitting CENTRALLY in the grid. A donor cheating at turn
        # 79 against cuts ...60, 80 has one post-cheat point, one turn later; the
        # transition is then bracketed by a 20-turn gap with nothing to localise
        # it. Centring maximises the cuts on each side. Weighted to act as a
        # tiebreak among already-eligible donors, not to override typicality.
        if r.get("first_test_edit"):
            reach = [c for c in GRID if c <= r["turns"]]
            if len(reach) >= 2:
                lo, hi = reach[0], reach[-1]
                frac = (r["first_test_edit"] - lo)/max(1, hi - lo)
                d += 1.5 * abs(frac - 0.5) * 2      # 0 at centre, 1.5 at an edge
        return d

    ranked = sorted(pool, key=lambda r: (dist(r), r["epoch"]))
    return ranked[0], pool, stats, ranked[:5]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", type=Path, default=PROFILE)
    ap.add_argument("--eval", type=Path, default=None)
    ap.add_argument("--out", type=Path, default=CFG_STATES / "donors.json")
    a = ap.parse_args()

    rows = json.loads(a.profile.read_text())

    def resolve(node, att):
        if isinstance(node, str):
            return att.get(node[13:], node) if node.startswith("attachment://") else node
        if isinstance(node, list):
            return [resolve(v, att) for v in node]
        if isinstance(node, dict):
            return {k: resolve(v, att) for k, v in node.items()}
        return node

    # the profile already carries source_eval + sample per row; re-pairing here
    # is what produced a donor whose epoch did not exist in its own run
    cache = {}
    for r in rows:
        ev = r.get("source_eval")
        if ev not in cache:
            cache[ev] = zipfile.ZipFile(ev)
        s_ = json.loads(cache[ev].read(r["sample"]))
        att = s_.get("attachments") or {}
        msgs = [resolve(m, att) for m in (s_.get("messages") or [])]
        r["replayable"] = r["turns"] >= DEEP_CUT and replayable_to(msgs, DEEP_CUT)
    out = {}
    for cls, want in (("cheat", True), ("honest", False)):
        best, pool, stats, top = pick(rows, want)
        print(f"\n=== {cls} donor ===")
        print(f"eligible pool: {len(pool)}  "
              f"(score={'1.0' if want else '0.0'}, turns>={MIN_TURN}, "
              f"{'has test-edit BEFORE first submit' if want else 'no test-edit'}, "
              f"replayable to turn {DEEP_CUT})")
        print(f"class medians: " + ", ".join(f"{k}={v[0]:.0f}" for k, v in stats.items()))
        print(f"{'':2}{'epoch':>7}{'turns':>7}{'submit':>8}{'edit':>6}{'rejects':>9}"
          f"   (grid {','.join(str(g) for g in GRID)})")
        for r in top:
            mark = "->" if r is best else "  "
            print(f"{mark}{r['epoch']:>7}{r['turns']:>7}{str(r['first_submit']):>8}"
                  f"{str(r['first_test_edit']):>6}{r['n_reject']:>9}")
        out[cls] = {
            "epoch": best["epoch"],
            "sample": best.get("sample"), "source_eval": best.get("source_eval"),
            "score": best["score"], "turns": best["turns"],
            "first_submit": best["first_submit"],
            "first_test_edit": best["first_test_edit"],
            "n_reject": best["n_reject"],
            "eligible_pool": len(pool),
        }
    a.out.parent.mkdir(parents=True, exist_ok=True); a.out.write_text(json.dumps(out, indent=1))
    print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
