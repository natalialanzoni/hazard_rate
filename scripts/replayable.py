#!/usr/bin/env python3
"""Is every disk mutation in a donor's first N turns reconstructible from the log?

Shared by select_donors.py and build_replay.py so the donor rule and the replay
planner cannot disagree about what "replayable" means.

The failure this exists to prevent: inspect logs a `text_editor str_replace` with
whatever arguments the model supplied, and the model sometimes omits `new_str`
entirely. The transcript then records that a file changed but not what it became,
so the edit cannot be replayed. It is harmless only when a later
`git checkout <path>` reverts it before the cut -- which is why this tracks
pending edits per path rather than just counting them.
"""
from __future__ import annotations
import re

CHECKOUT = re.compile(r'git checkout\s+(?:--\s+)?(\S+)')
WRITE = re.compile(r'(sed -i|\bcat\s*>|>>\s*/|>\s*/tmp|git (checkout|apply|stash|reset|clean|revert)'
                   r'|\bmv\b|\brm\b|\bcp\b|\bmkdir\b|\btouch\b|\bpatch\b)')
READONLY = re.compile(r'^\s*(cd \S+ && )?(python -m pytest|pytest|git (diff|show|log|status)'
                      r'|grep|ls|cat |head|tail|wc|find|sed -n|python -c)')
REPO_PREFIX = "/testbed/"


def norm_path(p: str) -> str:
    p = str(p).strip()
    p = p[len(REPO_PREFIX):] if p.startswith(REPO_PREFIX) else p
    return p.lstrip("./")


def replayable_to(msgs, cut: int) -> bool:
    turn = 0
    pending: list[tuple[str | None, bool]] = []
    for m in msgs:
        if m.get("role") != "assistant":
            continue
        turn += 1
        if turn > cut:
            break
        for tc in (m.get("tool_calls") or []):
            f = tc.get("function")
            a = tc.get("arguments") or {}
            if f == "text_editor" and a.get("command") in ("str_replace", "create", "insert"):
                ok = ("file_text" in a) if a.get("command") == "create" else ("new_str" in a)
                pending.append((norm_path(a.get("path", "")), ok))
            elif f in ("bash", "python"):
                cmd = str(a.get("command") or a.get("code") or "")
                m2 = CHECKOUT.search(cmd)
                if m2:
                    tgt = norm_path(m2.group(1))
                    pending = [] if tgt in (".", "") else [x for x in pending if x[0] != tgt]
                    continue
                if READONLY.match(cmd) and not WRITE.search(cmd):
                    continue
                if WRITE.search(cmd):
                    pending.append((None, True))
    return all(ok for _, ok in pending)
