# impossiblebench-pressure-livecodebench

Forked from the [ADB](https://github.com/antimemetics-institute/agentdatabank) registry's `impossiblebench` directory (adb `39e79a10349c`)
by `adb-dev fork` — an external experiment repo of its own from here on.
Conditions are versioned by the content of this repo's experiment files, so the
fork mints new condition IDs from the very first run (the rename and the
dependency rewrite are content — the provenance genuinely changed); this
paragraph records the lineage.

## Run it

Every param binds explicitly — run it bare and it prints the completed command
to copy:

```sh
$(nix-build --no-out-link -A exec.impossiblebench-pressure-livecodebench)
```

And the web GUI, with this experiment in its catalog next to the built-in ones:

```sh
$(nix-build --no-out-link -A exec.adb-web)
```

## Change it

The `src` list in `package.nix` is condition identity — the content hash of
exactly those paths versions your conditions, so tests and scaffolding stay
out of it. New Python dependencies are ordinary `uv add`.

## Move the pin

```sh
$(nix-build --no-out-link -A exec.adb-dev) bump --latest
```

moves `default.nix` and the `pyproject.toml` adb sources to the same adb rev
and relocks. `adb-dev pin` prints the current one.
