#!/usr/bin/env bash
# fm-agy-lib.sh - agy effort, permission posture, worker wiring and cleanup.
# Sourced by fm-spawn.sh, fm-teardown.sh and the quota resolver.
#
# New wired ships/scouts map crew-permissions=auto to --mode auto --sandbox.
# The task brief is withheld until fm-agy-native-lib.sh proves active Auto,
# a real harmless tool result and generation-bound Stop; the task's own later
# PreInvocation must then prove brief delivery. No default-review/bypass
# fallback is allowed. Manual retains native review; secondmates and explicit
# raw commands remain outside the worker policy layer.
#
# Native workers grant only the physical worktree, task data/scratch and
# owned hooks, never the shared state directory. The policy independently
# enforces exact task writes, protected wiring, credentials and publication.
# fm-agy-admission.sh owns executable/model/effort/backend compatibility proof.
# jq, Python 3, owned hook wiring and readable per-task policy are required.
# Project .agents/hooks.json files refuse a policy-layer launch.
#
# --agy-bypass, --no-agy-bypass and --agy-judge refuse new worker launches.

# Launch and quota resolution share this model/effort normalization.
agy_effort_level() {  # <effort> <model>
  case "$2" in *-low | *-medium | *-high) return 0 ;; esac
  case "$1" in
    low | medium) printf '%s\n' "$1" ;;
    high | xhigh | max) printf '%s\n' high ;;
  esac
}

# The synthetic initial turn uses upstream's interactive-prompt launch shape.
# It carries no task instructions or authority; qualification owns handoff.
fm_agy_readiness_prompt() {
  printf '%s' 'This is a launch readiness check, before your task. Reply exactly WARM_READY. Use no tools and do nothing else.'
}

# Own only agy's launch template here; fm-spawn owns common substitutions.
fm_agy_launch_template() { # <permission-flags>
  local permission_flags=$1
  printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS AGY_CLI_DISABLE_AUTO_UPDATE=1 __AGYBIN__ '
  printf '%s' "$permission_flags"
  printf '%s' ' __MODELFLAG____EFFORTFLAG____PERMISSIONDIRS__'
  if [ "${AGY_NATIVE_AUTO:-0}" = 1 ]; then
    printf '%s' '--log-file __AGYNATIVELOG__ --prompt-interactive '
    shell_quote "$(fm_agy_readiness_prompt)"
  else
    # shellcheck disable=SC2016 # Expanded later by the staged launch shell.
    printf '%s' '-i "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  fi
}

# Native workers require verified Auto; supervisors keep accept-edits.
fm_agy_permission_flags() {  # <crew-permission-mode>
  case "${1-}" in
  auto)
    if [ "${AGY_NATIVE_AUTO:-0}" -eq 1 ]; then
      printf '%s' '--mode auto --sandbox'
    else
      printf '%s' '--mode accept-edits'
    fi
    ;;
  manual) ;;
  *) return 1 ;;
  esac
}

# Select native Auto only for new wired workers. Recorded postures and
# secondmate/manual launches retain their own route.
fm_agy_default_posture() {  # <harness> <kind>
  [ "$1" = agy ] && [ "$2" != secondmate ] || return 0
  [ "$AGY_BYPASS_POSTURE_SET" = 0 ] || return 0
  [ "$CREW_PERMISSION_MODE" = auto ] || return 0
  AGY_NATIVE_AUTO=1
  AGY_BYPASS_POSTURE_SET=1
}

# Same-adapter recovery accepts only explicit current worker postures.
# Legacy and pre-field records remain readable by retirement/audit, but cannot
# acquire native Auto or a different review posture through relaunch.
fm_agy_relaunch_inherit() {
  [ "$ARG3" = agy ] && [ "$KIND" != secondmate ] || return 0
  [ "${RELAUNCH_PRIOR_HARNESS:-agy}" = agy ] || return 0
  [ "$MODEL_SET" -eq 1 ] || MODEL=$(fm_meta_get "$RELAUNCH_META" model)
  [ "$EFFORT_SET" -eq 1 ] || EFFORT=$(fm_meta_get "$RELAUNCH_META" effort)
  [ "$MODEL" != default ] || MODEL=
  if [ -n "$(fm_meta_get "$RELAUNCH_META" agy_bypass)" ] \
    || [ -n "$(fm_meta_get "$RELAUNCH_META" agy_judge)" ]; then
    echo 'error: retired legacy agy permission record; preserve the task and its decisions for explicit recovery before relaunch' >&2
    exit 1
  fi
  case "$(fm_meta_get "$RELAUNCH_META" agy_posture)" in
    native-auto) AGY_NATIVE_AUTO=1 CREW_PERMISSION_MODE=auto ;;
    manual) AGY_NATIVE_AUTO=0 CREW_PERMISSION_MODE=manual ;;
    *)
      echo 'error: unknown or retired agy permission posture; preserve the task and its decisions for explicit recovery before relaunch' >&2
      exit 1 ;;
  esac
  AGY_BYPASS_POSTURE_SET=1
}

# Native prerequisites and refusal of retired worker permission flags.
fm_agy_bypass_validate() {
  if [ "${AGY_BYPASS_SET:-0}" = 1 ] || [ "$AGY_JUDGE_SET" = 1 ]; then
    echo "error: --agy-bypass, --no-agy-bypass and --agy-judge are deprecated for new workers; config/crew-permissions selects verified native Auto or explicit manual review; legacy records require explicit recovery before relaunch" >&2
    exit 1
  fi
  if [ "${AGY_NATIVE_AUTO:-0}" = 1 ]; then
    case "${BACKEND:-tmux}" in tmux|herdr) ;; *)
      echo "error: agy native Auto requires live-verified mode-transition and viewport primitives; backend '${BACKEND:-unknown}' is not verified; choose manual review explicitly or a verified backend" >&2
      exit 1 ;;
    esac
  fi
  # Every agy task, including manual and raw launches, archives at teardown.
  # Refuse before acquiring an endpoint rather than discover a missing audit
  # dependency only after the task has completed.
  if [ "$HARNESS" = agy ] && ! python3 -c 'import datetime, hashlib, json, pathlib, re, sys' >/dev/null 2>&1; then
    echo "error: cannot spawn agy task: Python 3 is required for its cleanup audit; install python3 before launching" >&2
    exit 1
  fi
}

# agy resolves a path physically before testing it against the granted
# workspace, so every grant must be handed over already resolved. Verified
# on agy 1.2.0: granting an unresolved path whose parent is a symlink (the
# /var -> /private/var case every mktemp -d lab hits) made agy treat a write
# inside its OWN worktree as non-workspace access and park on an "Allow
# creation of this file? Reason: outside workspace" prompt. The worktree is
# granted here rather than through __WORKTREE__ so it is resolved the same
# way as the other two, and so cursor's --workspace and omp's --cwd keep
# taking the recorded path unchanged.
fm_agy_permission_dirs() {
  local permission_dirs
  permission_dirs="--add-dir $(shell_quote "$(cd "$WT" && pwd -P)") --add-dir $(shell_quote "$(cd "$(dirname "$BRIEF")" && pwd -P)") "
  if [ "${AGY_NATIVE_AUTO:-0}" = 1 ]; then
    permission_dirs="$permission_dirs--add-dir $(shell_quote "$(cd "$TASK_TMP" && pwd -P)") "
  else
    permission_dirs="$permission_dirs--add-dir $(shell_quote "$STATE_REAL") "
  fi
  if [ "$KIND" != secondmate ] && [ "$RAW_LAUNCH" -eq 0 ]; then
    permission_dirs="$permission_dirs--add-dir $(shell_quote "$STATE_REAL/$ID.agy-hooks") "
  fi
  printf '%s' "$permission_dirs"
}

fm_agy_spawn_wire() {
  [ "$RAW_LAUNCH" -eq 0 ] || return 0
  if [ "${AGY_NATIVE_AUTO:-0}" = 1 ]; then
    fm_agy_native_wire
    return
  fi
  "$FM_ROOT/bin/fm-agy-hook.sh" install-worker "$STATE_REAL" "$ID" "$BUSY_GEN" "$WT" || {
    echo "error: could not install agy worker hooks for $ID" >&2
    exit 1
  }
}

# This short-circuits in the pane immediately before the native invocation,
# including before shell expansion of the real brief. A replacement after
# spawn's admission cannot inherit that earlier executable's receipt.
fm_agy_launch_guard() {
  local value
  [ "${AGY_NATIVE_AUTO:-0}" -eq 1 ] || return 0
  printf 'python3 %s assert ' "$(shell_quote "$SCRIPT_DIR/fm-agy-admission.py")"
  for value in "$AGY_ADMISSION_RECEIPT" "$AGY_BIN" "${MODEL:-}" \
    "$(agy_effort_level "${EFFORT:-}" "${MODEL:-}")" \
    "$AGY_JUDGE_TIER" "$AGY_JUDGE_MODEL" "$AGY_JUDGE_BIN"; do
    printf '%s ' "$(shell_quote "$value")"
  done
  printf '&& '
}

# agy starts its brief itself (-i), so there is no pointer to deliver; what
# spawn must prove is that the brief actually began running. The worker hook's
# PreInvocation is agy's own report of that: it replaces the fm-spawn seed with
# an agy-hook record under this incarnation's gen. Only that source counts - the
# seed is busy from the start, and a rendered footer is not consulted. A launch
# parked on an authentication prompt, a trust dialog, a feedback survey, or a
# refused model id never invokes the model and so never publishes it.
agy_wait_for_started() {
  local record source i=0 max=${FM_AGY_READY_POLLS:-120} interval=${FM_AGY_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    # A valid record reads "<state> <source> <event> <seq>".
    if record=$(fm_busy_record_read "$STATE_REAL" "$ID"); then
      source=${record#* }
      if [ "${source%% *}" = agy-hook ] && [ "${record##* }" -gt "${1:-0}" ]; then return 0; fi
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

# A native launch is only trustworthy once the permission adapter proved its
# wiring fires: the armed line lands on the observer log at the adapter's
# first hook call, which agy's own PreInvocation precedes. agy_wait_for_started
# already bounds the session start, so a missing armed line after that point
# means dead wiring - a malformed merge agy skipped silently, a policy path
# typo - not a slow start. The short poll still gives the append time to
# flush before the spawn refuses to trust the session.
agy_wait_for_armed() {
  local log="$STATE_REAL/agy-permission-log.jsonl" i=0 \
    max=${FM_AGY_ARMED_POLLS:-40} interval=${FM_AGY_POLL_INTERVAL:-0.5}
  # The adapter stamps its armed line with the busy generation the spawn
  # recorded in the policy file, so a line left in the append-only log by an
  # earlier launch - or a previous task that reused this log - can never
  # satisfy the canary for THIS launch. With no generation armed the match
  # would degenerate to gen:"", so the canary refuses outright.
  [ -n "$BUSY_GEN" ] || return 1
  while [ "$i" -lt "$max" ]; do
    [ -f "$log" ] \
      && jq -eR --arg task "$ID" --arg gen "$BUSY_GEN" \
        'fromjson? | select(.task == $task and .event == "armed" and .gen == $gen)' \
        "$log" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

# Close the launched agy endpoint and prove it is gone, through fm-spawn.sh's
# single owner of endpoint closure.
agy_endpoint_close_confirmed() {
  spawn_endpoint_close_confirmed "${FM_AGY_CLOSE_POLLS:-10}" "${FM_AGY_POLL_INTERVAL:-0.5}"
}

# shellcheck disable=SC2153 # STATE is bin/fm-spawn.sh's state directory global.
agy_spawn_fail() { # <detail>
  if agy_endpoint_close_confirmed; then
    printf '%s\n' "$(status_stamp_line "failed: $1")" >>"$STATE/$ID.status"
    echo "error: $1; closed window $T" >&2
    # A relaunch's abort trap retires its replacement wiring; a fresh spawn's
    # rollback removes only the record and generation, so retire its hooks
    # and any native policy wiring here.
    if [ "$RELAUNCH" -ne 1 ]; then
      if ! "$FM_ROOT/bin/fm-agy-permission-policy.sh" retire \
        "$STATE_REAL/$ID.agy-permission.json" </dev/null; then
        # Keep the record and generation as recovery anchors for unresolved
        # policy state, even though this endpoint is confirmed closed.
        # shellcheck disable=SC2034 # Read by fm-spawn.sh's EXIT trap.
        SPAWN_FRESH_COMMIT_PENDING=0
        printf '%s\n' "$(status_stamp_line "failed: $1; permission retirement failed; task record and policy state kept; explicit recovery is required")" >>"$STATE/$ID.status"
        echo "error: agy permission retirement failed for $ID; policy, cache, pending decisions, hooks and task record were kept; explicit recovery is required." >&2
        return 1
      fi
      "$FM_ROOT/bin/fm-agy-hook.sh" retire-worker "$STATE_REAL" "$ID" || true
      rm -f "$STATE_REAL/$ID.agy-permission.json" 2>/dev/null || true
      rm -rf "$STATE_REAL/$ID.agy-permission-cache" 2>/dev/null || true
    fi
    return 0
  fi
  # The agy process may still be running. Keep the task record, busy
  # generation, and hooks so teardown and supervision still own it: skip the
  # fresh-spawn rollback the EXIT trap would otherwise run.
  # shellcheck disable=SC2034 # Output global, read by bin/fm-spawn.sh's EXIT trap.
  SPAWN_FRESH_COMMIT_PENDING=0
  printf '%s\n' "$(status_stamp_line "failed: $1; its endpoint $T could not be confirmed closed, so the task record was kept")" >>"$STATE/$ID.status"
  echo "error: $1, and closing endpoint $T could not be confirmed; the agy worker may still be running." >&2
  echo "error: task record $STATE/$ID.meta, its busy generation, and its hooks were kept; close the endpoint, then run bin/fm-teardown.sh $ID." >&2
}

fm_agy_spawn_ready_gate() {
  [ "$HARNESS" = agy ] && [ "$KIND" != secondmate ] && [ "$RAW_LAUNCH" -eq 0 ] || return 0
  if [ "${AGY_NATIVE_AUTO:-0}" = 1 ]; then
    # shellcheck source=bin/fm-agy-native-lib.sh
    . "$SCRIPT_DIR/fm-agy-native-lib.sh"
    if ! fm_agy_native_activate "$BACKEND" "$T" "$STATE_REAL" "$ID" "$BUSY_GEN" "$TASK_TMP" \
      || ! agy_wait_for_armed; then
      agy_spawn_fail "agy native Auto activation failed: active mode, real harmless result and generation-bound hooks were not all proven; no task brief was sent"
      exit 1
    fi
    local seq prompt
    if ! seq=$(fm_agy_native_seq "$STATE_REAL" "$ID") \
      || ! prompt=$("$SCRIPT_DIR/fm-operational-input.sh" encode launch-brief < "$BRIEF"); then
      agy_spawn_fail "agy native Auto was verified but the task brief could not be prepared; no task brief was sent"
      exit 1
    fi
    if ! fm_agy_native_submit "$BACKEND" "$T" "$ID" "$prompt" || ! agy_wait_for_started "$seq"; then
      agy_spawn_fail "agy native Auto was verified but task brief delivery was not confirmed"
      exit 1
    fi
    return 0
  fi
  if ! agy_wait_for_started; then
    agy_spawn_fail "agy did not report starting its brief through its worker hook in window $T"
    exit 1
  fi
}

# Only current postures are emitted; historical fields remain audit input.
fm_agy_meta_lines() {
  [ "$HARNESS" = agy ] || return 0
  local version=''
  # Raw launch commands do not resolve a binary; keep its version unknown.
  if [ -n "${AGY_BIN:-}" ]; then
    version=$(AGY_CLI_DISABLE_AUTO_UPDATE=1 "$AGY_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  fi
  echo "agy_version=$version"
  echo "agy_permission_mode=$CREW_PERMISSION_MODE"
  if [ "${RAW_LAUNCH:-0}" = 1 ]; then
    echo 'agy_posture=raw'
  elif [ "${AGY_NATIVE_AUTO:-0}" = 1 ]; then
    echo 'agy_posture=native-auto'
  elif [ "$CREW_PERMISSION_MODE" = manual ]; then
    echo 'agy_posture=manual'
  else
    echo 'agy_posture=accept-edits'
  fi
}

# Native admission has its own context and coverage; legacy judge receipts
# cannot authorize this launch. Exact task roots stay in the deterministic
# policy, while ordinary residue goes to the vendor's native reviewer.
fm_agy_native_wire() {
  local wt dir git_root policy task_data grants_sha config
  command -v jq >/dev/null 2>&1 || { echo 'error: agy native policy requires jq' >&2; exit 1; }
  wt=$(cd "$WT" && pwd -P) || exit 1
  dir=$wt
  git_root=$(git -C "$WT" rev-parse --show-toplevel) || exit 1
  while :; do
    [ ! -e "$dir/.agents/hooks.json" ] && [ ! -L "$dir/.agents/hooks.json" ] || {
      echo "error: agy native policy requires owned hook wiring; project hooks exist at $dir/.agents/hooks.json" >&2
      exit 1
    }
    [ "$dir" != "$git_root" ] || break
    dir=$(dirname "$dir")
  done
  AGY_JUDGE_TIER="native-$BACKEND" AGY_JUDGE_MODEL='' AGY_JUDGE_BIN=''
  AGY_ADMISSION_RECEIPT=$("$SCRIPT_DIR/fm-agy-admission.sh" ensure-native "$AGY_BIN" "${MODEL:-}" \
    "$(agy_effort_level "${EFFORT:-}" "${MODEL:-}")" "$AGY_JUDGE_TIER" '' '') || exit 1
  policy="$STATE_REAL/$ID.agy-permission.json"
  task_data=$(cd "$(dirname "$BRIEF")" && pwd -P) || exit 1
  grants_sha=$("$SCRIPT_DIR/fm-agy-permission-policy.sh" grants-digest "$BRIEF") || exit 1
  config=${CONFIG:-${FM_HOME:-}/config}
  jq -n --arg task "$ID" --arg worktree "$wt" --arg status "$STATE_REAL/$ID.status" \
    --arg inbox "$STATE_REAL/$ID.inbox" --arg data "$task_data" --arg tasktmp "$TASK_TMP" \
    --arg brief "$BRIEF" --arg log "$STATE_REAL/agy-permission-log.jsonl" --arg agy "$AGY_BIN" \
    --arg version "$(jq -r .binding.version "$AGY_ADMISSION_RECEIPT")" --arg gen "$BUSY_GEN" \
    --arg grants_sha "$grants_sha" --arg config "$config" --arg credential_home "$HOME" \
    --argjson registry_required "$( [ -e "$config/declared-credentials.json" ] && printf true || printf false )" \
    '{posture:"native-auto", task:$task, worktree:$worktree, status:$status, inbox:$inbox,
      data:$data, tasktmp:$tasktmp, brief:$brief, log:$log, agy:$agy, gen:$gen,
      agy_version:$version, grants_sha:$grants_sha, config:$config,
      credential_user_home:$credential_home, credential_registry_required:$registry_required}' > "$policy" || exit 1
  "$SCRIPT_DIR/fm-agy-permission-policy.sh" register-credentials "$policy" </dev/null || exit 1
  "$SCRIPT_DIR/fm-agy-hook.sh" install-worker "$STATE_REAL" "$ID" "$BUSY_GEN" "$WT" "$policy" || exit 1
}

# The policy owner's retire closes every pending escalation as not-run
# while the policy file still names the status file, then removes the
# pending directory; the policy file itself goes with the shared wiring paths
# and the worker hooks with their directory after (fm_agy_relaunch_retire_hooks).
fm_agy_relaunch_retire_policy() {  # <harness> <state-dir> <id>
  [ "${1-}" = agy ] || return 0
  "$SCRIPT_DIR/fm-agy-permission-policy.sh" retire \
    "$2/$3.agy-permission.json" </dev/null
}

fm_agy_relaunch_retire_hooks() {  # <harness> <state-dir> <id>
  [ "${1-}" = agy ] || return 0
  "$SCRIPT_DIR/fm-agy-hook.sh" retire-worker "$2" "$3"
}

fm_agy_teardown_retire() {  # <state-dir> <id>
  local state=$1 id=$2
  if [ -e "$state/$id.agy-permission.json" ] || [ -d "$state/$id.agy-permission-pending" ]; then
    # The policy owner's retire closes every pending escalation as not-run
    # while the policy file still names the status file.
    "$SCRIPT_DIR/fm-agy-permission-policy.sh" retire "$state/$id.agy-permission.json" </dev/null || return 1
  fi
  # Archive before metadata/status removal; an archival failure keeps them
  # available for recovery rather than silently losing permission evidence.
  if [ -f "$state/$id.meta" ] && grep -q '^harness=agy$' "$state/$id.meta"; then
    bash "$SCRIPT_DIR/fm-agy-audit.sh" "$state" "$id" || return 1
  fi
  if [ -e "$state/$id.agy-hooks" ] || [ -L "$state/$id.agy-hooks" ]; then
    "$SCRIPT_DIR/fm-agy-hook.sh" retire-worker "$state" "$id" || return 1
  fi
}

# Native/legacy policy files, decision markers and exact approval stores
# (bin/fm-agy-permission-policy.sh).
fm_agy_teardown_remove_state() {  # <state-dir> <id>
  rm -f "$1/$2.agy-permission.json"
  rm -rf "$1/$2.agy-permission-pending" "$1/$2.agy-permission-cache"
}
