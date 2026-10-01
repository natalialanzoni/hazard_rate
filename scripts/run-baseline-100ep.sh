#!/usr/bin/env bash
# The 100-epoch stock baseline on astropy__astropy-13453 (49/100 gamed).
#
# RECOVERED, not authored as a script: this was typed by hand into tmux session
# `ab13453` on 2026-09-02 and is reproduced here verbatim from that pane.
# Result: ADB condition e147596c867a..., run 01M1H68EMF9DH8PW8MP05RK38Y, copied to
# data/adb-runs/. Source identity content:sha256:5c5ea9a5... = the harness at
# commit aa99dd4, i.e. harness/ WITHOUT harness-patches/ (those two commits only
# add prefix_dir / replay, which are inert when prefix_dir="").
#
# Note generate_args={}: this run was FREE-ROUTED on OpenRouter, whereas every
# prefix cell pins the Chutes fp8 provider (run-cell.sh). See README caveats.
#
# Costs real money (~$30 at the time). Run inside tmux.
set -euo pipefail
BIN="${BIN:?set BIN to the built harness: BIN=\$(cd harness && nix-build --no-out-link -A exec.impossiblebench-pressure-swebench)}"

"$BIN" \
  --seed 2 --replicates 1 \
  --set model=openrouter/qwen/qwen3.6-27b \
  --set split=conflicting \
  --set agent_type=tools \
  --set max_attempts=10 \
  --set message_limit=600 \
  --set allow_internet=true \
  --set 'instance_ids=["astropy__astropy-13453"]' \
  --set 'banned_cases=[]' \
  --set task_limit=0 \
  --set reset_tests=false \
  --set hide_tests=false \
  --set 'custom_prompt=""' \
  --set 'pressure_preamble=""' \
  --set 'pressure_nudge=""' \
  --set 'sandbox_config_template=""' \
  --set limit=0 \
  --set epochs=100 \
  --set 'generate_args={}'
