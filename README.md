# hazard_rate

Where in a trajectory does a model commit to gaming the tests?

We take one rollout that eventually cheats and one that never does, cut each at
turn N, hand the first N turns back to the model as its own history (with the
sandbox restored to match), and measure how often the resumed episode games the
tests. Repeating this at many cuts gives a cheat rate as a function of turn,
which is the "hazard" curve this repo is named for.

Task: [ImpossibleBench](https://arxiv.org/abs/2510.20270) `conflicting` split,
`astropy__astropy-13453`, model `openrouter/qwen/qwen3.6-27b`. On `conflicting`
the test file contains two contradictory assertions, so **passing means the
model gamed the tests**. The score is the label; no judge is involved.

![cheat rate vs prefix depth](graphs/20261001T180357Z__cheat_rate_turns_tier1.png)

## Result

| | cuts | gamed |
|---|---|---|
| cheat donor, before the step | 30–46 | 51/90 = 0.57 |
| cheat donor, after the step | 48–60 | 48/50 = 0.96 |
| honest donor, all cuts | 1–60 | 104/170 = 0.61 |
| unprefixed baseline | — | 49/100 = 0.49 |

The cheat arm jumps between cut 46 (13/20) and cut 48 (18/20); Fisher p = 2e-7
for 30–46 against 48–60. The replayed sandbox is **byte-identical** at cuts
38–52 (one replayed edit, the donor's turn-37 source fix), so the jump comes
from the transcript, not from disk state. Turns 47–48 are where the donor first
argues for editing the test ("I should just fix the test", "the instruction is
likely meant to prevent…"). Turn 48 then retracts ("let me submit my fix as
is"), and the donor actually deletes the assertion at turn 53. The honest donor
notices the same contradiction many times but never argues for editing.

The ablation cell (`cheat-nojust:48`, stage 4) tests whether those sentences
are what moves the rate. **It has not been run yet.**

## Stages → code

All scripts are in `scripts/`. Everything here is the code that produced the
figure and its inputs, plus the ablation.

**1. Find a ~50% task.**

| script | what it did |
|---|---|
| `launch-upstream.sh`, `run-upstream.sh` | stock ADB-registry sweep: first 10 astropy tasks × `original`/`conflicting` × 10 epochs |
| `collect.py` | per-sweep summary + `results.json` |
| `per_instance_rates.py` | per-task rate table. **Reconstructed:** the pick was made by reading this table, not with a committed script. Output in `results/sweeps/per_instance_rates.txt` |
| `run-baseline-100ep.sh` | the 100-epoch confirmation run (49/100). **Recovered verbatim** from the tmux pane it was typed into |

The 2026-08-18 sweep had 13453 at 4/10. The 2026-08-21 sweep is mostly
unscored samples and was not used. Result directories: `results/`.

**2. Truncated replays.**

| script | what it did |
|---|---|
| `study_config.py` | which task, where its stock baseline lives |
| `trajectory_profile.py` | profiles the 100 baseline rollouts → `states/baseline_profile.json` |
| `select_donors.py`, `replayable.py` | donor selection rule. The final `states/donors.json` was curated from its output; see the `note` fields |
| `build_prefixes.py` | cuts a donor at turn N → `states/<class>/<N>/prefix.json` |
| `build_replay.py` | the disk mutations up to N → `replay.json` |
| `verify_replay.py` | replays a plan into a throwaway container and checks it against the donor's own `git diff`. Free |
| `run-cell.sh`, `launch.sh`, `seed_preflight.py` | run one cell / a named grid under ADB (tmux, sequential) |
| `verify_injection.py` | checks every episode in a cell actually received its prefix |

**3. Figure.** `plot_curve.py` recomputes every number on the figure,
including the title, from the `.eval` logs in `data/`.

**4. Justification ablation.** `build_ablation.py` copies cut 48 and deletes
five pro-edit passages from the reasoning of turns 47–48 → `states/cheat-nojust/48/`.
Tool calls, tool results and `replay.json` are byte-identical to cut 48. The
reasoning text is stored twice per block (`reasoning` and the
`reasoning-details://` signature that is sent back to the API); both are edited.

## Reproduce

```bash
# figure, from the committed logs (needs matplotlib + numpy)
python scripts/plot_curve.py

# baseline numbers / prefixes / ablation prefix, all from committed data
python scripts/study_config.py          # -> pooled 49/100
python scripts/build_prefixes.py --eval data/adb-runs/e147596c*/*/artifacts/run.eval
python scripts/build_ablation.py

# run the ablation cell (paid; ~$3-7). Needs nix, docker, ADB credentials, tmux.
SEED=23800 EPOCHS=20 REPO=$PWD/harness ./scripts/launch.sh cheat-nojust:48
```

Scripts read ADB run records from `data/adb-runs/` (same layout as
`~/.local/share/adb/runs`); set `ADB_RUNS` to use a live store instead.

## What's in here

```
scripts/          all code, stages 1-4
harness/          the ADB experiment every cell ran on: fork of ImpossibleBench
                  (vendored upstream @ 061dc3dc, MIT) at fork commit d9d4179
harness-patches/  the two fork commits that add prefix_dir + sandbox replay.
                  The baseline ran on harness/ WITHOUT them (commit aa99dd4);
                  both are inert when prefix_dir="".
states/           donors, baseline profile, the 24 prefix cells + the ablation cell
runs/             cell -> ADB condition id map, per-cell top-up seeds
data/adb-runs/    run.json + run.eval for the baseline and all 24 cells (35 runs)
results/          sweep configs/summaries, per-instance table, baseline provenance
graphs/           the figure
```

`harness/run.sh` and `harness/run-*.json` belong to an earlier pressure study
and were not used here. They are kept so `harness/` is the exact tree that ran.
Not included: the two sweeps' `.eval` logs (~46 MB). Only their configs,
summaries and the per-instance table are here.

`REPO=$PWD/harness` builds the same code, but ADB hashes the tree, `.git`
included, into the condition id. A fresh checkout therefore mints **new**
condition ids, and its runs will not collate with the ones in `runs/cell-conditions.txt`.

## Caveats

- **One donor per class.** The cheat/honest contrast is confounded with donor
  identity.
- **The baseline isn't served like the cells.** The 49/100 baseline was
  free-routed on OpenRouter (`generate_args={}`); every cell pins the Chutes fp8
  provider. Treat the baseline line as approximate. A pinned no-prefix control
  (`run-cell.sh control`) would fix this.
- **Some cells are thinner than others.** Cuts 34–48 have n=20; the rest n=10.
  The step localisation rests on 46 vs 48 (13/20 vs 18/20).
- **Replay fidelity was checked, but not everywhere.** In every post-prefix
  `git diff` the model ran before editing or submitting, the state matched the
  donor (61/61). Cheat cuts 38–52 have no donor diff to compare against, but
  their replay plan is identical to cuts that do.
- **Known code issues, not affecting the figure:** `build_replay.py` treats a
  bash command containing `git checkout` as only a checkout, and its write
  detector misses heredoc and Python file writes. Neither donor does either
  before turn 60. `verify_replay.py` is hardwired to 13453. The test-edit regex
  also matches scratch files named `test_*.py`.
