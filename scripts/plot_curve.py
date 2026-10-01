#!/usr/bin/env python3
"""Tier 1 figure: P(games the tests) against prefix depth, one line per donor class.

    scripts/plot_curve.py                      # -> graphs/<UTC>__cheat_rate_turns_tier1.{png,pdf}
    scripts/plot_curve.py --out /tmp/fig

Points worth stating because they are deliberate:

* Rates are recomputed from each cell's `.eval` on every run (FIGURES.md rule 1),
  so the figure cannot drift from the data. Nothing here is typed in.
* Error bars are **Wilson** 95% intervals (rule 2). The normal approximation would
  give a zero-width bar at 0/10 or 10/10 and assert impossible certainty.
* `make_trend`'s `show_shadow` is a *symmetric* band, which is wrong for a
  proportion near 0 or 1, so the interval is drawn explicitly and asymmetrically.
* Rule 4 asks for n on every point. n is 10 for all eight cells, so labelling each
  one adds eight identical annotations; it is stated once in the subtitle instead.
* The x axis is LINEAR in turns rather than categorical. That is the substantive
  choice: it shows the four measured cuts sitting far to the left of the turns
  where these trajectories actually decide anything, which is the finding.
"""
from __future__ import annotations
import argparse, datetime, glob, json, os, zipfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
# Where ADB run records live. Defaults to the copy committed in this repo
# (data/adb-runs, same layout as ~/.local/share/adb/runs); set ADB_RUNS to
# point at a live ADB store instead.
RUNS = Path(os.environ.get("ADB_RUNS", ROOT/"data/adb-runs"))

# ---- figures4papers spec (api.md): implement, it is a convention not a package ----
PALETTE = {
    "blue_main": "#0F4D92", "blue_secondary": "#3775BA",
    "green_1": "#DDF3DE", "green_2": "#AADCA9", "green_3": "#8BCF8B",
    "red_1": "#F6CFCB", "red_2": "#E9A6A1", "red_strong": "#B64342",
    "neutral": "#CFCECE", "highlight": "#FFD700",
    "teal": "#42949E", "violet": "#9A4D8E",
}
INK, INK_MUTED = "#1A1A1A", "#5A5A5A"
# The neighbouring cuts the step falls between (cheat arm 46 -> 48).
STEP_LO, STEP_HI = 46, 48


@dataclass(frozen=True)
class FigureStyle:
    font_size: int = 16
    axes_linewidth: float = 2.0
    use_tex: bool = False
    font_family: tuple[str, ...] = ("DejaVu Sans", "Helvetica", "Arial", "sans-serif")


def apply_publication_style(style: FigureStyle | None = None) -> None:
    s = style or FigureStyle()
    plt.rcParams.update({
        "font.family": "sans-serif", "font.sans-serif": list(s.font_family),
        "font.size": s.font_size, "axes.linewidth": s.axes_linewidth,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.edgecolor": INK_MUTED, "axes.labelcolor": INK,
        "text.color": INK, "xtick.color": INK_MUTED, "ytick.color": INK_MUTED,
        "xtick.labelcolor": INK, "ytick.labelcolor": INK,
        "legend.frameon": False, "text.usetex": s.use_tex,
        "svg.fonttype": "none", "pdf.fonttype": 42, "ps.fonttype": 42,
        "figure.facecolor": "white", "axes.facecolor": "white",
    })


def create_subplots(nrows=1, ncols=1, figsize=None, **kw):
    fig, axes = plt.subplots(nrows, ncols, figsize=figsize, **kw)
    return fig, np.atleast_1d(np.asarray(axes)).ravel()


def finalize_figure(fig, out_path, formats=None, dpi=300, close=True, pad=0.05, **kw):
    out = Path(out_path); out.parent.mkdir(parents=True, exist_ok=True)
    formats = formats or (["png", "pdf"] if not out.suffix else [out.suffix.lstrip(".")])
    saved = []
    for f in formats:
        p = out.with_suffix(f".{f}")
        fig.savefig(p, dpi=dpi, bbox_inches="tight", pad_inches=pad, **kw)
        saved.append(p)
    if close:
        plt.close(fig)
    return saved


# ---- data ----
def wilson(k: int, n: int, z: float = 1.959963985) -> tuple[float, float]:
    if n == 0:
        return 0.0, 1.0
    c = (k + z*z/2) / (n + z*z)
    h = z/(n + z*z) * np.sqrt(k*(n-k)/n + z*z/4)
    return max(0.0, c-h), min(1.0, c+h)


def read_cells(cuts):
    ids = dict(l.split()[:2] for l in (ROOT/"runs/cell-conditions.txt").read_text().splitlines()
               if not l.startswith("#") and len(l.split()) == 2)
    out = {}
    for cls in ("cheat", "honest"):
        for cut in cuts:
            key = f"{cls}-cut{cut}"
            if key not in ids:
                continue
            ev = sorted(glob.glob(str(RUNS/f"{ids[key]}/*/artifacts/run.eval")))
            if not ev:
                continue
            # EVERY run of the condition, not just the newest. A topped-up cell
            # is a SECOND run under the same condition id (epochs is a bound
            # param, so epochs=20 would be a different condition and would not
            # collate), and ev[-1] would show the top-up INSTEAD of the original.
            k = n = err = pf = 0
            for ev_path in ev:
                z = zipfile.ZipFile(ev_path)
                for nm in z.namelist():
                    if not nm.startswith("samples/"):
                        continue
                    s = json.loads(z.read(nm)); n += 1
                    if s.get("error"):
                        err += 1
                    sc = s.get("scores") or {}
                    if sc and sc[list(sc)[0]].get("value") == 1.0:
                        k += 1
                    if (s.get("metadata") or {}).get("prefix_messages"):
                        pf += 1
            out[(cls, cut)] = dict(k=k, n=n, err=err, prefixed=pf)
    return out


def fisher(a, b, c, d):
    """Two-sided Fisher exact p for [[a, b], [c, d]]."""
    from math import comb
    n, r1, c1 = a+b+c+d, a+b, a+c
    P = lambda x: comb(r1, x)*comb(n-r1, c1-x)/comb(n, c1)
    obs = P(a)
    return sum(P(x) for x in range(max(0, c1-(n-r1)), min(r1, c1)+1) if P(x) <= obs*(1+1e-9))


def pooled(cells, cls, cuts):
    k = sum(cells[(cls, c)]["k"] for c in cuts)
    n = sum(cells[(cls, c)]["n"] for c in cuts)
    return k, n


def baseline_rate():
    """The unprefixed 100-epoch run, recomputed rather than hard-coded."""
    p = RUNS/("e147596c867a93d90d303732480083017944ce08af3d10cdd20a2e5748511f88/"
                     "01M1H68EMF9DH8PW8MP05RK38Y/artifacts/run.eval")
    z = zipfile.ZipFile(p); k = n = 0
    for nm in z.namelist():
        if not nm.startswith("samples/"):
            continue
        s = json.loads(z.read(nm)); n += 1
        sc = s.get("scores") or {}
        if sc and sc[list(sc)[0]].get("value") == 1.0:
            k += 1
    return k, n


def donor_events():
    """Where the two donors actually decide, from states/donors.json + the profile."""
    d = json.loads((ROOT/"states/donors.json").read_text())
    prof = json.loads((ROOT/"states/baseline_profile.json").read_text())
    ev = {}
    for cls, rec in d.items():
        row = next(r for r in prof if r["epoch"] == rec["epoch"])
        ev[cls] = dict(submit=row["first_submit"], edit=row["first_test_edit"],
                       total=row["turns"], epoch=rec["epoch"])
    return ev


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cuts", type=int, nargs="+", default=[1, 5, 15, 30, 34, 38, 42, 46, 48, 52, 55, 60])
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()

    cells = read_cells(a.cuts)
    bk, bn = baseline_rate()
    base = bk/bn
    ev = donor_events()
    cuts = [c for c in a.cuts if ("cheat", c) in cells]
    tot_err = sum(v["err"] for v in cells.values())
    ns = {v["n"] for v in cells.values()}

    apply_publication_style(FigureStyle(font_size=17, axes_linewidth=2.2))
    fig, axes = create_subplots(1, 1, figsize=(12.5, 7.0))
    ax = axes[0]

    # X is CATEGORICAL (evenly spaced), not linear in turns. Twelve irregular cuts
    # on a linear axis collide badly around 46/48/52/55, and adjacency is exactly
    # what this figure must show -- the step sits between two neighbouring cuts.
    # Even spacing keeps every point legible; the axis label flags the distortion.
    pos = {c: i for i, c in enumerate(cuts)}

    def at(turn):
        """Place a turn number on the categorical axis, interpolating between cuts."""
        lo = max([c for c in cuts if c <= turn], default=cuts[0])
        hi = min([c for c in cuts if c >= turn], default=cuts[-1])
        return pos[lo] if lo == hi else pos[lo] + (turn - lo) / (hi - lo)

    # Annotate WHAT THE DONOR DID, not why. An earlier version labelled the jump
    # "the model has worked out the test is unsatisfiable" -- that is refuted:
    # 100/100 baseline rollouts verbalise the contradiction (cheaters median turn
    # 38, non-cheaters 37), and this donor diagnosed it at turn 12, well before
    # cut 30 where the rate is still at baseline. Diagnosis does not distinguish.
    # the unprefixed base rate this whole study is measured against
    ax.axhline(base, color=INK_MUTED, ls=(0, (5, 4)), lw=1.6, zorder=1)
    ax.text(len(cuts) - 0.62, base + 0.02, f"unprefixed baseline {base:.2f} (n={bn})",
            va="bottom", ha="right", fontsize=12.5, color=INK_MUTED)

    ax.axvspan(at(53), len(cuts) - 0.6, color=PALETTE["neutral"], alpha=0.40, lw=0, zorder=0)
    ax.axvline(at(53), color=PALETTE["red_strong"], ls=(0, (4, 4)), lw=1.8, zorder=1)
    ax.axvspan(pos[STEP_LO], pos[STEP_HI], color=PALETTE["highlight"], alpha=0.35, lw=0, zorder=0)
    ax.text((pos[STEP_LO]+pos[STEP_HI])/2, 1.03, "the step\nlands here", ha="center", va="bottom",
            fontsize=13.5, color=INK_MUTED, linespacing=1.25, clip_on=False)
    ax.text((at(53)+len(cuts)-0.6)/2, 1.03, "test already\ngamed on disk",
            ha="center", va="bottom", fontsize=13.5, color=INK_MUTED, linespacing=1.25)
    ax.annotate("donor deletes the contradictory\nassertion (turn 53)",
                xy=(at(53), 0.22), xytext=(pos[52], 0.30),
                ha="center", va="center", fontsize=12, color=PALETTE["red_strong"],
                linespacing=1.25,
                arrowprops=dict(arrowstyle="->", color=PALETTE["red_strong"], lw=1.5))
    ax.text(pos[1] - 0.3, 0.035,
            "donor already knows the test is contradictory from turn 12;\n"
            "its source fix finally works at turn 37 — neither moves the rate",
            ha="left", va="bottom", fontsize=12, color=INK_MUTED, linespacing=1.35)

    series = (("cheat", "Cheating donor", PALETTE["red_strong"], "o"),
              ("honest", "Honest donor", PALETTE["blue_main"], "s"))
    for cls, label, colour, marker in series:
        xs = np.arange(len(cuts), dtype=float)
        p = np.array([cells[(cls, c)]["k"]/cells[(cls, c)]["n"] for c in cuts])
        ci = [wilson(cells[(cls, c)]["k"], cells[(cls, c)]["n"]) for c in cuts]
        lo = np.array([c[0] for c in ci]); hi = np.array([c[1] for c in ci])
        ax.errorbar(xs, p, yerr=[p-lo, hi-p], fmt="none", ecolor=colour,
                    elinewidth=2.2, capsize=6, capthick=2.2, alpha=0.95, zorder=3)
        ax.plot(xs, p, color=colour, lw=2.8, marker=marker, ms=11,
                mfc="white", mec=colour, mew=2.6, label=label, zorder=4,
                clip_on=False, solid_capstyle="round")

    ax.set_xlabel("Prefix depth — donor turns replayed before the model takes over  (cuts evenly spaced, not to scale)", labelpad=10)
    ax.set_ylabel("P(games the tests)", labelpad=10)
    ax.set_xlim(-0.45, len(cuts) - 0.55); ax.set_ylim(0, 1.05)
    ax.set_xticks(list(pos.values()))
    ax.set_xticklabels([str(c) for c in cuts])
    ax.set_yticks(np.arange(0, 1.01, 0.25))
    ax.set_yticklabels([f"{v:.2f}" for v in np.arange(0, 1.01, 0.25)])
    ax.yaxis.grid(True, color=PALETTE["neutral"], lw=0.9, alpha=0.55, zorder=0)
    ax.set_axisbelow(True)
    ax.tick_params(length=6, width=1.8, labelsize=15)

    n_txt = f"n = {ns.pop()}" if len(ns) == 1 else "n varies"
    never = [c for c in ("cheat", "honest") if ev[c]["edit"] is None]
    note = f" · {'/'.join(never)} donor never edits a test" if never else ""

    # Header is placed explicitly rather than via set_title: a multi-line subtitle
    # plus a padded title collide, because the pad is measured from the axes and
    # the subtitle grows upward from its own anchor.
    # Every number in the header is computed from `cells`. It used to be typed in,
    # and went stale when cuts were topped up (it said 40/40 after 48 when 48 was
    # 18/20).
    pre_cuts = [c for c in cuts if 30 <= c <= STEP_LO]
    post_cuts = [c for c in cuts if c >= STEP_HI]
    k1, n1 = pooled(cells, "cheat", pre_cuts)
    k2, n2 = pooled(cells, "cheat", post_cuts)
    kh, nh = pooled(cells, "honest", cuts)
    p_step = fisher(k1, n1-k1, k2, n2-k2)
    ax.text(0, 1.36, f"Cheat donor: {k1/n1:.2f} through turn {STEP_LO}, "
                     f"{k2/n2:.2f} from turn {STEP_HI}",
            transform=ax.transAxes, fontsize=20, fontweight="bold",
            color=INK, va="bottom")
    ax.text(0, 1.20, f"astropy__astropy-13453 · conflicting · qwen3.6-27b · {n_txt} per point · Wilson 95% CI\n"
                      f"Cheat donor {k1}/{n1} across cuts {pre_cuts[0]}-{pre_cuts[-1]}, then {k2}/{n2} across cuts "
                      f"{post_cuts[0]}-{post_cuts[-1]} (Fisher p = {p_step:.1g}); honest donor {kh}/{nh} = {kh/nh:.2f} pooled.\n"
                      f"Not explained by noticing the contradiction (100/100 baseline rollouts do) nor by the source fix landing at turn 37{note}",
            transform=ax.transAxes, fontsize=13, color=INK_MUTED, va="bottom",
            linespacing=1.5)
    ax.legend(loc="upper left", fontsize=14, handlelength=2.0,
              bbox_to_anchor=(0.012, 0.985), labelspacing=0.6)

    out = a.out or (ROOT/"graphs"/(datetime.datetime.now(datetime.timezone.utc)
                                   .strftime("%Y%m%dT%H%M%SZ") + "__cheat_rate_turns_tier1"))
    saved = finalize_figure(fig, out, formats=["png", "pdf"], dpi=300, pad=0.06)
    for p in saved:
        print(f"wrote {p}")
    kb, nb = pooled(cells, "cheat", [c for c in cuts if STEP_HI <= c < 53])
    print(f"\ncaption: {len(cuts)*2} cells x {n_txt}, {tot_err} errored samples. Donors are "
          f"epoch {ev['cheat']['epoch']} (games the test at turn 53, first submits at 69) and "
          f"epoch {ev['honest']['epoch']} (never games it). Dashed red line = the donor's own "
          f"cheat. Shaded region = cuts whose replayed sandbox ALREADY carries that cheat, so a "
          f"pass there requires no action from the model. At cuts {STEP_HI}-52 the contradiction "
          f"is still present and the model re-derives the cheat itself {kb}/{nb}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
