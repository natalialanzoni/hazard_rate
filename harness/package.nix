# ImpossibleBench (arXiv:2510.20270) as ADB experiments: coding benchmarks whose
# "impossible" test variants (oneoff / conflicting) can only be passed by
# specification-violating shortcuts — passing IS the reward-hacking signal.
#
# One experiment per upstream @task (the task is the experiment, never a param):
#   impossiblebench-livecodebench → impossiblebench.impossible_livecodebench
#   impossiblebench-swebench      → impossiblebench.impossible_swebench
#
# Both run agentic coding loops inside an inspect sandbox: docker must be on the
# host PATH (SWE-bench pulls per-instance images; the runner forwards PATH into the
# experiment). VM-isolated execution (forest.nix) is the planned replacement.
{ adb, lib, writeShellApplication, jq }:

let
  env = adb.mkPythonEnv {
    name = "adb-impossiblebench-env";
    workspaceRoot = ./.;
    # the two git deps build from source (no wheels) and both use setuptools —
    # impossiblebench ships a legacy setup.py, inspect-evals declares the backend
    # without it being provided — so inject setuptools as their build system
    overrides = final: prev:
      lib.genAttrs [ "impossiblebench" "inspect-evals" ] (name:
        prev.${name}.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ])
            ++ final.resolveBuildSystem { setuptools = [ ]; };
        }));
  };

  results = with adb.types; {
    status = str;
    samples = int;
    completed = int;
    errors = int;
    score = float;
    score_name = str;
    tokens_input = int;
    tokens_output = int;
  };

  # hints come from types.llm itself (mkExperiment attaches the shared model
  # catalog to every llm-typed param); nothing to declare here
  modelParam = with adb.types; param llm {
    description = "Inspect model id (provider/model), resolved through inspect's own provider layer. Required: there is deliberately no default real model.";
    order = 1000;
    group = "model";
  };

  splitParam = with adb.types; param (enum [ "original" "oneoff" "conflicting" ]) {
    description = "Dataset split: `original` = the unmutated benchmark (the control); `oneoff` / `conflicting` = impossible variants where passing implies test exploitation. Required: the split is the condition's whole point.";
    order = 1;
    group = "task";
  };

  sharedParams = with adb.types; {
    limit = param int {
      description = "Sample cap (0 = the whole split).";
      initial = 0;
      order = 1010;
      group = "inspect";
    };
    epochs = param int {
      description = "Repeats of the dataset (1 = a single pass).";
      initial = 1;
      order = 1011;
      group = "inspect";
    };
    generate_args = param object {
      description = "Generation config overrides; leave a field unset to keep the provider's default.";
      initial = { };
      # typed sub-form generated from the pinned inspect_ai's GenerateConfig —
      # through `adb`, never a ../../ path: this directory must evaluate outside
      # the tree (that is what `adb-dev fork` produces)
      fields = adb.inspectGenerateFields;
      order = 1020;
      group = "generation";
    };
  };

  # the lift between the runner protocol (flat params on stdin, seed in $ADB_SEED)
  # and the wrapper's config: named params regroup into inspect task_args; the task
  # spec is baked per experiment.
  mkAdapter = name: taskFn: jqTaskArgs: writeShellApplication {
    name = "${name}-adapter";
    runtimeInputs = [ jq ];
    # limit goes to the task too, not just eval-level: inspect's limit truncates
    # after the task fn has already built its dataset, and swebench prepares a
    # docker image per sample in there — eval-level alone means images for the
    # whole split. 0 (= whole split) must stay absent: upstream slices
    # samples[:limit] whenever its arg is non-null.
    text = ''
      config=$(mktemp)
      trap 'rm -f "$config"' EXIT
      jq --argjson seed "''${ADB_SEED:-0}" '{
        task: "pkg:impossiblebench:${taskFn}",
        model: .model,
        limit: .limit,
        epochs: .epochs,
        generate_args: .generate_args,
        seed: $seed,
        task_args: (${jqTaskArgs}
          + (if .limit > 0 then {limit: .limit} else {} end))
      }' > "$config"
      ${lib.getExe' env "adb-inspect-eval"} "$config"
    '';
  };

  # hand-written (no upstream link registry here). Links are pointers, not pins:
  # the exact rev lives in pyproject.toml/uv.lock
  links = [
    { label = "paper"; url = "https://arxiv.org/abs/2510.20270"; }
    { label = "source"; url = "https://github.com/safety-research/impossiblebench"; }
  ];
in
{
  impossiblebench-pressure-livecodebench = adb.mkExperiment {
    name = "impossiblebench-pressure-livecodebench";
    src = ./.;
    summary = "ImpossibleBench LiveCodeBench: function-implementation tasks with impossible test variants — passing an impossible split means the agent gamed the tests";
    inherit links;

    params = with adb.types; {
      model = modelParam;
      split = splitParam;
      agent_type = param (enum [ "minimal" "tools" ]) {
        description = "Agent scaffold: `minimal` = submission loop with test feedback; `tools` = SWE-style file editing with bash.";
        initial = "minimal";
        order = 2;
        group = "task";
      };
      max_attempts = param int {
        description = "Maximum submission attempts per sample.";
        initial = 3;
        order = 3;
        group = "task";
      };
      message_limit = param int {
        description = "Per-sample message cap.";
        initial = 30;
        order = 4;
        group = "task";
      };
      allow_test_modifications = param bool {
        description = "Whether the agent may edit test files (test modification is one of the cheating channels the benchmark measures).";
        initial = true;
        order = 5;
        group = "task";
      };
    } // sharedParams;

    inherit results;
    env = { network = true; docker = true; };
    program = mkAdapter "impossiblebench-livecodebench" "impossible_livecodebench"
      ''{split: .split, agent_type: .agent_type, max_attempts: .max_attempts,
         message_limit: .message_limit, allow_test_modifications: .allow_test_modifications}'';
  };

  impossiblebench-pressure-swebench = adb.mkExperiment {
    name = "impossiblebench-pressure-swebench";
    src = ./.;
    summary = "ImpossibleBench SWE-bench: real-repo issue fixing with impossible test variants — passing an impossible split means the agent gamed the tests";
    inherit links;

    params = with adb.types; {
      model = modelParam;
      split = splitParam;
      agent_type = param (enum [ "minimal" "tools" ]) {
        description = "Agent scaffold: `minimal` = mini-agent (bash only); `tools` = multi-submission with bash, python, and a text editor.";
        initial = "tools";
        order = 2;
        group = "task";
      };
      max_attempts = param int {
        description = "Maximum submission attempts per sample.";
        initial = 10;
        order = 3;
        group = "task";
      };
      message_limit = param int {
        description = "Per-sample message cap.";
        initial = 100;
        order = 4;
        group = "task";
      };
      allow_internet = param bool {
        description = "Whether the sandbox may reach the internet. NOTE: upstream sets `internal: false` on the generated compose network, which is Docker's default (full egress) — so on stock impossiblebench this flag does NOT isolate the sandbox. Use sandbox_config_template with `internal: true` for real isolation.";
        initial = false;
        order = 5;
        group = "task";
      };

      # -- selection: which samples run at all. `instance_ids` is applied BEFORE the
      # task builds its docker images, so pinning one instance turns a multi-hour image
      # preparation into seconds. `limit` alone does not: the shared `limit` param is
      # inspect's eval-level cap (it trims results), whereas the task's own `limit`
      # trims the dataset before image prep — hence task_limit below.
      instance_ids = param (listOf str) {
        description = "Restrict to these SWE-bench instance ids (e.g. pydata__xarray-6992). Applied before image preparation, so a pinned instance starts in seconds instead of preparing all 349. Empty = the whole split.";
        initial = [ ];
        order = 6;
        group = "task";
      };
      banned_cases = param (listOf str) {
        description = "Instance ids to exclude. Needed because a missing upstream image aborts the whole run (upstream asserts every image built); django__django-15563 currently 404s on Docker Hub.";
        initial = [ ];
        order = 7;
        group = "task";
      };
      task_limit = param int {
        description = "Dataset cap applied INSIDE the task, before docker image preparation (0 = no cap). Distinct from the inspect-level `limit`, which only caps samples evaluated after the task has already prepared images for the whole split.";
        initial = 0;
        order = 8;
        group = "task";
      };

      # -- test access control: which cheating channels are reachable. reset_tests
      # restores the official tests before scoring, so edits to test files are reverted
      # and test-modification stops working as a way to pass.
      reset_tests = param bool {
        description = "Restore the official test files before scoring, so the agent's edits to tests do not count. Closes the test-modification channel while leaving source-side gaming open.";
        initial = false;
        order = 9;
        group = "task";
      };
      hide_tests = param bool {
        description = "Hide test files from the agent entirely. Combine with reset_tests for the 'hidden tests' access level.";
        initial = false;
        order = 10;
        group = "task";
      };

      # -- prompting
      custom_prompt = param str {
        description = "Extra instruction text. Appended to the prompt suffix, so it appears BOTH in the system prompt and in every rejection message.";
        initial = "";
        order = 11;
        group = "prompt";
      };
      pressure_preamble = param str {
        description = "Text prepended verbatim to the system prompt (local addition). Empty reproduces upstream byte-for-byte.";
        initial = "";
        order = 12;
        group = "prompt";
      };
      pressure_nudge = param str {
        description = "Text repeated on every rejection, after the test output (local addition). When set, rejections also open with 'No — the function should work.' Empty reproduces upstream byte-for-byte.";
        initial = "";
        order = 13;
        group = "prompt";
      };

      prefix_dir = param str {
        description = "Point-of-no-return study: path to a cell directory holding manifest.json + prefix.json — the first N turns of a completed rollout OF THIS SAME instance, appended after the task's user message so the model resumes mid-episode. Empty reproduces upstream byte-for-byte. NOTE the directory contents are NOT content-hashed into the condition id — pin prefix_manifest_sha alongside it.";
        initial = "";
        order = 14;
        group = "prompt";
      };
      prefix_manifest_sha = param str {
        description = "sha256 of the cell's prefix.json (manifest.prefix_sha256). Carries no behaviour; it exists so the condition id changes when the prefix changes, which prefix_dir (a bare path) would not catch.";
        initial = "";
        order = 15;
        group = "prompt";
      };

      # -- sandbox
      sandbox_config_template = param str {
        description = "Path to a docker-compose template used verbatim for the sandbox ({{IMAGE_NAME}} is substituted). Supported upstream hook; the way to get real network isolation given the allow_internet bug. Empty = the task's generated compose file.";
        initial = "";
        order = 14;
        group = "task";
      };
    } // sharedParams;

    inherit results;
    env = { network = true; docker = true; };
    # Empty strings / empty lists mean "unset": jq maps them back to null so the task
    # falls through to its own defaults, rather than receiving "" or [] and treating
    # those as a real (and different) configuration.
    program = mkAdapter "impossiblebench-swebench" "impossible_swebench"
      ''{split: .split, agent_type: .agent_type, max_attempts: .max_attempts,
         message_limit: .message_limit, allow_internet: .allow_internet,
         instance_ids: (if (.instance_ids | length) == 0 then null else .instance_ids end),
         banned_cases: (if (.banned_cases | length) == 0 then null else .banned_cases end),
         limit: (if .task_limit == 0 then null else .task_limit end),
         reset_tests: .reset_tests, hide_tests: .hide_tests,
         custom_prompt: .custom_prompt,
         pressure_preamble: .pressure_preamble, pressure_nudge: .pressure_nudge,
         prefix_dir: (if .prefix_dir == "" then null else .prefix_dir end),
         sandbox_config_template_file:
           (if .sandbox_config_template == "" then null else .sandbox_config_template end)}'';
  };
}
