#!/usr/bin/env python3
"""Verify every episode in a cell actually received its prefix.

    cheat_rate_turns_study/scripts/verify_injection.py runs/cheat-cut15.eval

Reads the .eval, not the run log. That distinction is the whole point: the solver
announces the injection with logger.warning, which inspect keeps in the sample
transcript and NEVER writes to stdout -- so grepping the log always reports 0 and
cannot tell a working run from a broken one. The 2026-08-28 transplant run was
lost to exactly that (a stale build/lib shadowed the patched src, every arm ran
un-prefilled, and all three landed on the same number because they were the same
condition in all but name).

Exit status 1 if any episode is missing its prefix, so a driver can stop before
spending on the next cell.
"""
from __future__ import annotations
import json, sys, zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__); return 2
    ev = Path(sys.argv[1])
    if not ev.exists():
        print(f"FAIL: no such eval {ev}"); return 1
    cell = ev.stem
    z = zipfile.ZipFile(ev)
    rows, bad = [], 0
    for name in sorted(n for n in z.namelist() if n.startswith("samples/")):
        s = json.loads(z.read(name))
        md = s.get("metadata") or {}
        msgs = s.get("messages") or []
        errs = []
        n_pf = md.get("prefix_messages")
        control = cell.startswith("control")
        if control:
            if n_pf:
                errs.append(f"control episode carries a prefix ({n_pf} messages)")
        elif not n_pf:
            errs.append("NO PREFIX")
        else:
            # messages[0]=system, [1]=the task, [2:2+n_pf]=the prefix.
            if len(msgs) > 1:
                if msgs[0].get("role") != "system":
                    errs.append(f"messages[0] is {msgs[0].get('role')}, expected system")
                if msgs[1].get("role") != "user":
                    errs.append(f"messages[1] is {msgs[1].get('role')}, expected the task")
            if len(msgs) > 2:
                if msgs[2].get("role") != "assistant":
                    errs.append(f"prefix starts on {msgs[2].get('role')}, expected assistant")
                tail = msgs[1 + n_pf]
                if tail.get("role") != "tool":
                    errs.append(f"prefix ends on {tail.get('role')}, expected a tool result")
                # the model must have actually continued past the prefix
                if len(msgs) <= 2 + n_pf:
                    errs.append("model produced nothing after the prefix")
        scores = s.get("scores") or {}
        val = scores[list(scores)[0]].get("value") if scores else None
        if errs:
            bad += 1
        rows.append((s.get("epoch"), md.get("prefix_class"), md.get("prefix_cut_turns"),
                     n_pf, (md.get("prefix_sha256") or "")[:12], val,
                     "; ".join(errs) or "ok"))

    ok = len(rows) - bad
    print(f"{cell}: {ok}/{len(rows)} episodes carry their prefix")
    print(f"{'ep':>4}{'class':>8}{'cut':>5}{'msgs':>6}{'sha':>14}{'score':>7}  status")
    for ep, cls, cut, n, sha, val, st in sorted(rows, key=lambda r: r[0] or 0):
        flag = " " if st == "ok" else "*"
        print(f"{ep:>4}{str(cls):>8}{str(cut):>5}{str(n):>6}{sha:>14}{str(val):>7} {flag}{st}")
    scored = [r[5] for r in rows if r[5] is not None]
    if scored:
        print(f"\ncheat rate (score 1.0 = gamed, by construction on `conflicting`): "
              f"{sum(1 for v in scored if v == 1.0)}/{len(scored)}")
    if bad:
        print(f"\nFAIL: {bad} episode(s) ran WITHOUT a valid prefix — this cell is not data.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
