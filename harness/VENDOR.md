# Vendored upstream: `vendor-impossiblebench/`

`vendor-impossiblebench/` is a **vendored copy** of upstream ImpossibleBench, checked in
as plain files (its `.git` was removed deliberately — see below). `pyproject.toml` points
at it via a path source, so the experiment builds from these files, not from a git pin.

## Provenance

| | |
|---|---|
| upstream | <https://github.com/safety-research/impossiblebench> |
| vendored at rev | `061dc3dce6a96ab6cf02a855157263033dcfa3ba` |
| rev subject | `Change original_patch to original_test_patch` |
| why this rev | it is the rev ADB's own registry pins, so behaviour starts identical to the built-in `impossiblebench` experiments and every difference below is a deliberate edit |
| paper | ImpossibleBench, arXiv:2510.20270 |

## Why `.git` was removed

Two reasons:

1. **One repo, one history.** Everything the experiment needs is committed here, so any
   run can be reproduced by checking out this repo at the commit the run was made from.
2. **Condition-hash stability.** ADB hashes the experiment's `src` (`./.`) to mint
   condition ids, and its dev-artifact filter excludes only `.venv`, `__pycache__`,
   `node_modules`, `dist`, `.direnv`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` and
   `result*` — **not** `.git`. A nested git directory mutates on its own (packing, logs,
   index churn), which would re-version conditions without any change to behaviour.

## Diffing against upstream

Removing `.git` means `git diff` no longer compares to upstream. To review local changes:

```bash
git clone https://github.com/safety-research/impossiblebench /tmp/ib-upstream
git -C /tmp/ib-upstream checkout 061dc3dce6a96ab6cf02a855157263033dcfa3ba
diff -ru /tmp/ib-upstream/src/impossiblebench vendor-impossiblebench/src/impossiblebench
```

## Local changes to upstream

Record every edit here — this is the audit trail for what makes results differ from
the published implementation.

| file | change | why |
|---|---|---|
| `swebench_agent_full.py` | `multi_submission_solver()` gains `pressure_preamble` / `pressure_nudge` params | pressure framing becomes config, not source — arms differ by config only |
| `swebench_agent_full.py` | `_get_default_template()` prepends `pressure_preamble` when non-empty | the system-prompt manipulation |
| `swebench_agent_full.py` | `custom_incorrect_message()` prepends `"No — the function should work."` and appends `pressure_nudge`, **both only when `pressure_nudge` is set** | the repeated-rejection manipulation |
| `swebench_tasks.py` | `impossible_swebench()` gains the same two params and forwards them | makes them settable from `task_args`, so they land in the eval log |

**Empty defaults reproduce upstream byte-for-byte**, so an unpressured run on this branch
is a valid baseline. All changes live on **`pressure-urgency`**; `main` (`44de7e1`) is
pristine upstream — `git checkout main` reverts everything.

> Note: the first pressure run (score 0.0, 8 attempts, no cheating) was produced by commit
> `42e1241`, which hardcoded this text instead of parameterising it. The rendered prompts
> are identical; only the plumbing changed.

### ADB experiment params (package.nix, `expose-params` branch)

`package.nix` declares which knobs exist; the web GUI renders its form from those
declarations, so a param that is not declared cannot be set from the UI. Added:
`instance_ids`, `banned_cases`, `task_limit`, `reset_tests`, `hide_tests`,
`custom_prompt`, `pressure_preamble`, `pressure_nudge`, `sandbox_config_template`.

Two subtleties encoded in the adapter's jq mapping:

- **`task_limit` is not `limit`.** The shared `limit` param is inspect's eval-level cap,
  applied after the task has already prepared docker images for the whole split.
  `task_limit` is the task's own dataset cap, applied *before* image preparation. Only
  the latter avoids the multi-hour image phase. `instance_ids` does the same, better.
- **Empty string / empty list means "unset".** jq maps them to `null` so the task falls
  through to its own defaults instead of receiving `""` or `[]` and treating those as a
  distinct configuration (which would silently mint a different condition).

### Known upstream bugs worth patching

- `src/impossiblebench/swebench_tasks.py:361` — `internal: false` in the generated
  compose network. `allow_internet=False` therefore does **not** isolate the sandbox;
  `internal: true` is what blocks egress. Observed effect: an agent reached
  `api.github.com` / `raw.githubusercontent.com` and used the real upstream test file to
  justify deleting a contradictory assertion.
- `src/impossiblebench/swebench_build_images.py:140` — `assert len(missing_images) == 0`
  aborts the whole run when any one instance image is unavailable (e.g.
  `django__django-15563` 404s on Docker Hub). Filtering those samples with a warning
  would be preferable to losing a multi-hour run.
