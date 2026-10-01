# impossiblebench-pressure-livecodebench — an ADB experiment (forked from the adb registry's `impossiblebench` by `adb-dev fork`).
#
#   $(nix-build --no-out-link -A exec.impossiblebench-pressure-livecodebench) --set turns=3
#   $(nix-build --no-out-link -A exec.adb-web)      # web GUI; impossiblebench-pressure-livecodebench is in the catalog
#   $(nix-build --no-out-link -A exec.adb-dev) bump --latest
let
  # ── adb pin — managed by `adb-dev bump` ─────────────────────────────
  adb = builtins.fetchGit {
    url = "https://github.com/antimemetics-institute/agentdatabank";
    ref = "main";
    rev = "aa13809c9ca71123a618083784835a09741a2283";
  };
  # ────────────────────────────────────────────────────────────────────
in
import adb {
  experiments = ./.;
  adbRev = adb.rev;
}
