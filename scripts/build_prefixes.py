#!/usr/bin/env python3
"""Cut the two donor trajectories into turn-N prefixes.

    cheat_rate_turns_study/scripts/build_prefixes.py            # all cuts
    cheat_rate_turns_study/scripts/build_prefixes.py --cuts 1 5 15

Writes states/<class>/<N>/{prefix.json,manifest.json,rendered.txt}.

Unlike the cross-run transplant (scripts/prefill/build_pool.py) the donor here is
the SAME task, so:

  * the donor's system + user messages are DROPPED. The target episode emits
    byte-identical ones itself -- asserted, not assumed, see _check_head. Keeping
    them would duplicate the task statement.
  * there is NO bridge message. The transplant needs one because it pivots to a
    different task; here the model is continuing its own episode and any seam
    would announce the manipulation.

A prefix of N turns ends on the TOOL RESULT answering turn N's last tool call, so
no tool_call is ever left unanswered -- most chat APIs reject that, and it keeps
the structure identical across cuts.

Reasoning blocks are kept verbatim. The transplant arms replayed donor reasoning
through this same stack without incident, so stripping it would be a gratuitous
difference from the trajectory being reproduced.
"""
from __future__ import annotations
import argparse, hashlib, json, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
import sys
sys.path.insert(0, str(HERE))
from study_config import INSTANCE, BASELINES, STATES
BASELINE = BASELINES[0] if BASELINES else None
CUTS = (1, 5, 15, 30, 45, 60)


def resolve(node, att):
    if isinstance(node, str):
        return att.get(node[13:], node) if node.startswith("attachment://") else node
    if isinstance(node, list):
        return [resolve(v, att) for v in node]
    if isinstance(node, dict):
        return {k: resolve(v, att) for k, v in node.items()}
    return node


def load(z, member):
    s = json.loads(z.read(member))
    att = s.get("attachments") or {}
    return s, [resolve(m, att) for m in (s.get("messages") or [])]


def _check_head(z, donor_msgs, donor_epoch):
    """The donor's system+user must match another episode's, or dropping them
    would silently change the task statement the model sees."""
    other = next(n for n in z.namelist()
                 if n.startswith("samples/") and f"_epoch_{donor_epoch}." not in n)
    _, om = load(z, other)
    for i, role in ((0, "system"), (1, "user")):
        assert donor_msgs[i]["role"] == role == om[i]["role"], f"msg {i} not {role}"
        if donor_msgs[i]["content"] != om[i]["content"]:
            raise SystemExit(
                f"ABORT: donor {role} message differs from {other}. The target "
                f"episode would not reproduce it, so it cannot be dropped.")
    return other


def truncate(body, n_turns):
    """First n_turns assistant messages, plus the tool results answering them and
    any rejection feedback that followed.

    Past turn ~60 a prefix legitimately contains USER messages: the donor has
    submitted and been rejected, and the rejection is delivered as a user turn.
    Ending on one is the natural resumption point -- the model is being asked to
    continue after feedback -- so a trailing user message is kept, not trimmed.
    """
    turns, cut = 0, 0
    for i, m in enumerate(body):
        if m.get("role") == "assistant":
            if turns == n_turns:
                break
            turns += 1
        cut = i + 1
    kept = body[:cut]
    # an assistant message with unanswered tool_calls cannot end a prefix
    while kept and kept[-1].get("role") == "assistant":
        kept.pop()
    return kept, turns


def wellformed(msgs):
    """Every tool_call must have a matching tool result, and vice versa.

    User messages ARE allowed here (they are rejection feedback from a submit
    inside the prefix) and a prefix may end on one. A SYSTEM message is never
    allowed: the target episode emits its own.
    """
    want, got, errs = [], [], []
    for m in msgs:
        if m.get("role") == "assistant":
            want += [tc.get("id") for tc in (m.get("tool_calls") or [])]
        elif m.get("role") == "tool":
            got.append(m.get("tool_call_id"))
    if set(want) - set(got):
        errs.append(f"{len(set(want)-set(got))} unanswered tool_call(s)")
    if set(got) - set(want):
        errs.append(f"{len(set(got)-set(want))} orphan tool result(s)")
    if msgs and msgs[-1].get("role") not in ("tool", "user"):
        errs.append(f"prefix ends on {msgs[-1].get('role')}, not a tool result or feedback")
    if any(m.get("role") == "system" for m in msgs):
        errs.append("prefix contains a system message")
    return errs


def render(msgs) -> str:
    out = []
    for i, m in enumerate(msgs):
        r = m.get("role")
        c = m.get("content")
        if isinstance(c, list):
            c = "\n".join(
                (x.get("text") or x.get("reasoning") or "") for x in c if isinstance(x, dict))
        head = f"--- [{i}] {r} "
        if m.get("tool_calls"):
            head += "".join(f"| {tc.get('function')} " for tc in m["tool_calls"])
        out.append(head + "-" * max(0, 78 - len(head)))
        out.append((c or "").strip()[:1800])
        for tc in (m.get("tool_calls") or []):
            out.append(f"    CALL {tc.get('function')} {json.dumps(tc.get('arguments'), ensure_ascii=False)[:900]}")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval", type=Path, default=None)
    ap.add_argument("--donors", type=Path, default=STATES / "donors.json")
    ap.add_argument("--cuts", type=int, nargs="+", default=list(CUTS))
    a = ap.parse_args()

    donors = json.loads(a.donors.read_text())

    print(f"{'class':8}{'cut':>5}{'msgs':>7}{'turns':>7}{'~tok':>9}{'edits':>8}{'submit':>8}{'rej':>6}  sha256")
    for cls, d in donors.items():
        z = zipfile.ZipFile(a.eval or d.get("source_eval") or BASELINE)
        s, msgs = load(z, d["sample"])
        ref = _check_head(z, msgs, d["epoch"])
        body = msgs[2:]
        for n in a.cuts:
            kept, got = truncate(body, n)
            if got < n:
                print(f"{cls:8}{n:>5}  SKIP: donor has only {got} turns")
                continue
            errs = wellformed(kept)
            if errs:
                raise SystemExit(f"ABORT {cls} cut {n}: " + "; ".join(errs))
            blob = json.dumps(kept, ensure_ascii=False, indent=1)
            sha = hashlib.sha256(blob.encode()).hexdigest()
            out = STATES / cls / str(n)
            out.mkdir(parents=True, exist_ok=True)
            (out / "prefix.json").write_text(blob)
            (out / "rendered.txt").write_text(render(kept))
            manifest = {
                "study": "cheat_rate_turns_study", "class": cls, "cut_turns": n,
                "instance": INSTANCE, "split": "conflicting",
                "donor_epoch": d["epoch"], "donor_score": d["score"],
                "donor_total_turns": d["turns"],
                "donor_first_test_edit": d["first_test_edit"],
                "baseline_eval": str(a.eval), "head_checked_against": ref,
                "n_messages": len(kept), "prefix_sha256": sha,
                "submits_in_prefix": sum(
                    1 for m in kept if m.get("role") == "assistant"
                    for tc in (m.get("tool_calls") or []) if tc.get("function") == "submit"),
                "rejections_in_prefix": sum(1 for m in kept if m.get("role") == "user"),
                "approx_tokens": int(len(blob) / 3.6),
            }
            (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
            mut = sum(1 for m in kept if m.get("role") == "assistant"
                      for tc in (m.get("tool_calls") or [])
                      if (tc.get("function") == "text_editor"
                          and (tc.get("arguments") or {}).get("command")
                          in ("str_replace", "create", "insert")))
            print(f"{cls:8}{n:>5}{len(kept):>7}{got:>7}{int(len(blob)/3.6):>9,}"
                  f"{mut:>8}{manifest['submits_in_prefix']:>8}"
                  f"{manifest['rejections_in_prefix']:>6}  {sha[:16]}…")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
