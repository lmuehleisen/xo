#!/usr/bin/env bash
# fm-agy-lib.sh - the fork's agy worker wiring for bin/fm-spawn.sh and
# bin/fm-teardown.sh: the executable resolution, the permission posture and
# its --agy-bypass gates, the worker hook install, the post-launch readiness
# gate, and the matching retires. Sourced, never executed.
#
# Kept out of the upstream-owned spawn and teardown scripts so an upstream
# merge meets one-line call sites there instead of the whole agy arm.
# Each function below is the code those scripts ran inline before, moved
# unchanged. bin/fm-agy-hook.sh owns the worker hooks,
# bin/fm-agy-permission-policy.sh owns the bypass permission layer, and the
# harness-adapters agy reference owns the operating facts.
#
# agy installs native hooks through fm-agy-hook.sh in an owned state directory;
# PreInvocation opens semantic busy and fullyIdle Stop closes it and signals
# turn-end. The same transport composes primary and secondmate supervision.
# Every agy launch grants physically resolved worktree and hook paths: without
# the worktree grant agy writes into its own scratch, and an unresolved path
# parks on a non-workspace approval prompt.
# An agy ship or scout spawn reports success only once the worker hook's
# PreInvocation record replaces the fm-spawn seed (FM_AGY_READY_POLLS polls,
# default 120, every FM_AGY_POLL_INTERVAL seconds, default 0.5); otherwise it
# closes the endpoint, appends failed:, retires a fresh spawn's hooks, and exits
# 1. When closure cannot be confirmed (the backend still finds the target), the
# task record, busy generation, and hooks are kept for teardown instead, and
# the failure says the worker may still be running.
#   --agy-bypass is the reviewed path onto agy's
#   --dangerously-skip-permissions, available to agy crewmate and scout spawns
#   on the wired launch path. It installs bin/fm-agy-permission-policy.sh
#   beside the worker hooks - an armed heartbeat on PreInvocation and Stop,
#   and a hard-deny/judge decision on PreToolUse after the log-only observer
#   - so the bypass is policed rather than bare. The
#   launch refuses rather than falls back when any gate fails: jq missing, an
#   agy version outside the adapter's live-verified set, a project-supplied
#   .agents/hooks.json in the task worktree or its ancestors up to the git
#   root, an unwritable policy file, or a failed hook install. After the
#   session starts, a canary (FM_AGY_ARMED_POLLS, default 40) refuses and
#   closes the endpoint when the adapter's armed line never reaches the
#   observer log - dead wiring is never trusted under bypass, and the armed
#   line is stamped with this launch's busy generation so a stale record from
#   an earlier launch or a reused task id cannot satisfy it. A relaunch
#   inherits the recorded posture through meta when it resolves onto an agy
#   scout again and retires the old generation's policy wiring first. agy
#   cannot silently approve through a
#   hook, so the layer's approvals are abstentions; what it still buys is
#   hard refusals that hold under bypass, a judge for the residue, and
#   durable escalation records firstmate can resolve.
#   --agy-judge <tier>[:<model>] selects WHICH judge answers that residue,
#   from the tiers bin/fm-judge-tier-lib.sh knows. It requires --agy-bypass,
#   and its default needs no flag at all: agy judges agy, on that tier's own
#   model. Selecting another tier refuses rather than falls back when the tier
#   is unknown or its executable is not installed. The resolved tier is printed
#   before the launch, repeated on the spawned line, and recorded as agy_judge=
#   so a relaunch re-judges on the same tier and a later reader of the decision
#   log can tell which judge adjudicated this task's calls.
#
#   fm_agy_permission_flags <crew-permission-mode>
#       prints the launch permission flags for auto or manual
#   fm_agy_relaunch_inherit
#       a relaunch's inheritance of the recorded bypass posture and judge tier
#   fm_agy_bypass_validate
#       the --agy-bypass and --agy-judge argument gates, resolving the tier
#   fm_agy_permission_dirs
#       prints the physically resolved --add-dir grants for the launch
#   fm_agy_spawn_wire
#       the bypass posture's install-time gates, its policy file, and the
#       worker hook install (spawn)
#   fm_agy_spawn_ready_gate
#       the post-launch started and bypass-armed gates
#   agy_wait_for_started, agy_wait_for_armed, agy_endpoint_close_confirmed,
#   agy_spawn_fail <detail>
#       the gates' helpers
#   fm_agy_meta_lines
#       prints the bypass posture's task-record lines
#   fm_agy_relaunch_retire_policy <harness> <state-dir> <id>
#   fm_agy_relaunch_retire_hooks <harness> <state-dir> <id>
#       the relaunch retire steps bin/fm-spawn.sh's clear_relaunch_harness_wiring
#       runs around its shared wiring-path removal
#   fm_agy_teardown_retire <state-dir> <id>
#   fm_agy_teardown_remove_state <state-dir> <id>
#       teardown's retire of the bypass layer and worker hooks, and its removal
#       of the per-task policy state. Retire archives an agy task with
#       bin/fm-agy-audit.sh after permission resolution and before deletion;
#       an archive failure stops cleanup without deleting the task records.
#
# The spawn-side functions read bin/fm-spawn.sh's globals rather than taking
# them as arguments: AGY_BYPASS, AGY_JUDGE_ARG,
# AGY_JUDGE_SET, AGY_JUDGE_TIER, AGY_JUDGE_MODEL, AGY_JUDGE_BIN, AGY_BIN,
# ARG3, RELAUNCH_META, HARNESS, KIND, RAW_LAUNCH, RELAUNCH,
# CREW_PERMISSION_MODE, WT, STATE, STATE_REAL, ID, BUSY_GEN, TASK_TMP, BRIEF,
# FM_ROOT, SCRIPT_DIR, BACKEND, T, W, ZELLIJ_TAB_ID, and
# SPAWN_FRESH_COMMIT_PENDING, plus shell_quote, status_stamp_line,
# fm_meta_get, fm_busy_record_read, fm_backend_kill, fm_backend_target_exists,
# and bin/fm-judge-tier-lib.sh. fm_agy_relaunch_inherit and
# fm_agy_bypass_validate set AGY_BYPASS, AGY_JUDGE_ARG, AGY_JUDGE_TIER, and
# AGY_JUDGE_MODEL; fm_agy_spawn_wire sets AGY_JUDGE_BIN. The validate, wire,
# and ready-gate functions exit the spawn on a refusal, exactly as the inline
# code did.

# agy has no reviewed-auto mode. Its only blanket option is
# --dangerously-skip-permissions, which auto stays deliberately clear
# of: auto selects --mode accept-edits, verified on agy 1.2.0 to
# auto-approve file edits inside the granted directories while STILL
# prompting for every shell command (a `date` call was denied under
# accept-edits). manual omits --mode entirely, leaving agy's default
# review mode where edits prompt too. Neither path can reach
# --dangerously-skip-permissions, and there is no fallback onto it when
# an approval prompt parks the worker; the pane stall is the visible,
# supervisable outcome. .agents/skills/harness-adapters/references/harness/agy.md
# owns the operating consequences.
# The --agy-bypass opt-in is the single reviewed path onto
# --dangerously-skip-permissions: it launches only with the
# bin/fm-agy-permission-policy.sh hook layer installed beside the
# worker hooks, so the bypass is policed rather than bare. The flag's
# gates are in fm_agy_bypass_validate; without it this branch is
# byte-identical to the accept-edits posture above.
fm_agy_permission_flags() {  # <crew-permission-mode>
  case "${1-}" in
  auto)
    if [ "$AGY_BYPASS" -eq 1 ]; then
      printf '%s' '--dangerously-skip-permissions'
    else
      printf '%s' '--mode accept-edits'
    fi
    ;;
  manual) ;;
  *) return 1 ;;
  esac
}

# The recorded bypass posture binds to agy worker spawns: a relaunch onto a
# different harness, or onto a secondmate, drops it rather than carrying an
# agy worker layer's name forward into a posture it does not police.
# The recorded judge tier rides the same inheritance: a relaunch that dropped
# it would silently re-judge the task on a different tier than the one its
# record names. A record written before the tier was selectable carries no
# field, which resolves to this adapter's own tier in fm_agy_bypass_validate.
fm_agy_relaunch_inherit() {
  [ "$(fm_meta_get "$RELAUNCH_META" agy_bypass)" = on ] && [ "$ARG3" = agy ] && [ "$KIND" != secondmate ] && AGY_BYPASS=1
  if [ "$AGY_BYPASS" -eq 1 ]; then
    AGY_JUDGE_ARG=$(fm_meta_get "$RELAUNCH_META" agy_judge || true)
  fi
}

# --agy-bypass is the reviewed path onto agy's
# --dangerously-skip-permissions: firstmate's permission layer
# (bin/fm-agy-permission-policy.sh) rides the worker hook file it installs, so
# the bypass is policed rather than bare. It applies to agy crewmate and scout
# spawns on the wired launch path - a raw launch command installs no hooks at
# all - and refuses to combine with config/crew-permissions=manual, which is
# itself an explicit prompt posture. A secondmate is a firstmate instance
# rather than a worker this layer polices, so it stays refused.
# A relaunch inherits the recorded posture through fm_agy_relaunch_inherit, so
# every check below and at install time applies to it unchanged.
# The posture first covered scouts only and now covers ships too. On a
# read-only scout the layer's write guards were belt-and-braces; on a ship
# they are the only write restriction firstmate relies on for a bypassed
# worker. The guards never read the task kind - they resolve
# every write target physically against the policy file's worktree and scratch
# roots - so widening the gate changed who they protect, not what they check,
# and tests/fm-agy-harness.test.sh exercises them on the ship path.
fm_agy_bypass_validate() {
  if [ "$AGY_BYPASS" -eq 1 ]; then
    [ "$HARNESS" = agy ] || {
      echo "error: --agy-bypass applies only to agy spawns" >&2
      exit 1
    }
    [ "$RAW_LAUNCH" -eq 0 ] || {
      echo "error: --agy-bypass cannot ride a raw launch command; the permission layer it requires is never installed there" >&2
      exit 1
    }
    [ "$KIND" != secondmate ] || {
      echo "error: --agy-bypass applies to agy crewmate and scout spawns; a secondmate is a firstmate instance, not a worker this layer polices" >&2
      exit 1
    }
    [ "$CREW_PERMISSION_MODE" = auto ] || {
      echo "error: --agy-bypass conflicts with config/crew-permissions=manual; drop one posture" >&2
      exit 1
    }
    # The judge tier, resolved here so an unknown or unavailable judge refuses
    # the launch instead of turning every residue call into a hold the captain
    # has to answer by hand. The default needs no flag - agy judges agy - and
    # whatever is resolved is recorded and printed, because the judge that
    # adjudicated a call has to stay identifiable when the decision log is read
    # back after the per-task policy file is gone.
    AGY_JUDGE_TIER=${AGY_JUDGE_ARG%%:*}
    case "$AGY_JUDGE_ARG" in *:*) AGY_JUDGE_MODEL=${AGY_JUDGE_ARG#*:} ;; *) AGY_JUDGE_MODEL= ;; esac
    # Absent means this adapter's own tier: agy judges agy, automatically, as
    # the default rather than an opt-in.
    [ -n "$AGY_JUDGE_TIER" ] || AGY_JUDGE_TIER=agy
    fm_judge_tier_known "$AGY_JUDGE_TIER" || {
      echo "error: --agy-judge names an unknown judge tier '$AGY_JUDGE_TIER'; known tiers: $(fm_judge_tiers)" >&2
      exit 1
    }
    [ -n "$AGY_JUDGE_MODEL" ] || AGY_JUDGE_MODEL=$(fm_judge_tier_model "$AGY_JUDGE_TIER")
    # Whether the tier's judge is actually installed here is decided beside the
    # bypass posture's other installed-binary gates in fm_agy_spawn_wire, once
    # the agy binary itself has been resolved.
  fi
  [ "$AGY_JUDGE_SET" -eq 0 ] || [ "$AGY_BYPASS" -eq 1 ] || {
    echo "error: --agy-judge selects the judge for the --agy-bypass permission layer; without that posture no judge is installed" >&2
    exit 1
  }
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
  permission_dirs="--add-dir $(shell_quote "$(cd "$WT" && pwd -P)") --add-dir $(shell_quote "$STATE_REAL") --add-dir $(shell_quote "$(cd "$(dirname "$BRIEF")" && pwd -P)") "
  if [ "$KIND" != secondmate ] && [ "$RAW_LAUNCH" -eq 0 ]; then
    permission_dirs="$permission_dirs--add-dir $(shell_quote "$STATE_REAL/$ID.agy-hooks") "
  fi
  printf '%s' "$permission_dirs"
}

fm_agy_spawn_wire() {
  local agy_policy agy_version agy_verified agy_wt_real agy_check_dir \
    agy_git_root agy_task_data agy_grants_sha
  [ "$RAW_LAUNCH" -eq 0 ] || return 0
  agy_policy=
  if [ "$AGY_BYPASS" -eq 1 ]; then
    # The bypass posture's gates, each refusing rather than falling
    # back to an unguarded launch:
    # - jq, without which the adapter cannot read a payload;
    # - an agy version inside the live-verified set the adapter prints
    #   (docs/verification/runtime-backends.md owns the evidence);
    # - no project-supplied .agents/hooks.json in the task worktree or
    #   its ancestors up to the git root, so the adapter's own hooks are
    #   the only hook definitions in force;
    # - the selected judge tier's executable, because a tier whose judge
    #   is not installed would hold every residue call for firstmate
    #   instead of judging it;
    # - and the policy file itself, which install-worker then verifies
    #   exists before merging the adapter into the hooks.
    command -v jq >/dev/null 2>&1 || {
      echo "error: cannot spawn agy bypass worker: jq is required by the permission policy hook; install jq or drop --agy-bypass" >&2
      exit 1
    }
    agy_version=$("$AGY_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    agy_verified=$("$SCRIPT_DIR/fm-agy-permission-policy.sh" verified-versions 2>/dev/null || true)
    case " $agy_verified " in
      *" ${agy_version:-none} "*) ;;
      *)
        echo "error: cannot spawn agy bypass worker: agy ${agy_version:-unreadable} is outside the live-verified set ($agy_verified); the hook contract this layer depends on is unproven there; manual review is a separate explicit choice: config/crew-permissions=manual without --agy-bypass (not judge coverage)" >&2
        exit 1
        ;;
    esac
    if [ "$AGY_JUDGE_TIER" = agy ]; then
      # The judge tier and the worker share one binary, already gated above.
      AGY_JUDGE_BIN=$AGY_BIN
    else
      AGY_JUDGE_BIN=$(command -v "$(fm_judge_tier_command "$AGY_JUDGE_TIER")" 2>/dev/null || true)
    fi
    [ -n "$AGY_JUDGE_BIN" ] && [ -x "$AGY_JUDGE_BIN" ] || {
      echo "error: cannot spawn agy bypass worker: the $AGY_JUDGE_TIER judge tier needs the '$(fm_judge_tier_command "$AGY_JUDGE_TIER")' executable, which is not installed; install it or select a tier that is" >&2
      exit 1
    }
    # Say the judge out loud before the launch: which judge adjudicated a
    # task's calls is part of reading its decisions back later.
    echo "agy bypass judge tier: $AGY_JUDGE_TIER model=$AGY_JUDGE_MODEL executable=$AGY_JUDGE_BIN" >&2
    agy_wt_real=$(cd "$WT" && pwd -P) || exit 1
    agy_check_dir=$agy_wt_real
    agy_git_root=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$agy_wt_real")
    while :; do
      [ ! -e "$agy_check_dir/.agents/hooks.json" ] && [ ! -L "$agy_check_dir/.agents/hooks.json" ] || {
        echo "error: cannot spawn agy bypass worker: $agy_check_dir/.agents/hooks.json exists; the bypass posture needs firstmate's worker hooks to be the only hooks in force; choose manual review explicitly with config/crew-permissions=manual and omit --agy-bypass; manual workers are not judge coverage" >&2
        exit 1
      }
      [ "$agy_check_dir" != "$agy_git_root" ] || break
      agy_check_dir=$(dirname "$agy_check_dir")
    done
    agy_policy="$STATE_REAL/$ID.agy-permission.json"
    agy_task_data=$(cd "$(dirname "$BRIEF")" && pwd -P) || exit 1
    # The digest pins the grants block firstmate wrote, so a block the
    # worker adds or edits in its own brief grants nothing.
    agy_grants_sha=$("$SCRIPT_DIR/fm-agy-permission-policy.sh" grants-digest "$BRIEF" 2>/dev/null || true)
    # gen binds this launch's armed line to its own busy generation: the
    # canary matches it so an armed record left by a previous launch or
    # a reused task id can never pass for this one's live wiring.
    agy_config=${CONFIG:-${FM_HOME:-}/config}
    case "$agy_config" in /*) ;; *) agy_config="$PWD/$agy_config" ;; esac
    jq -n --arg task "$ID" --arg worktree "$agy_wt_real" \
      --arg status "$STATE_REAL/$ID.status" --arg inbox "$STATE_REAL/$ID.inbox" \
      --arg data "$agy_task_data" --arg tasktmp "$TASK_TMP" --arg brief "$BRIEF" \
      --arg log "$STATE_REAL/agy-permission-log.jsonl" --arg agy "$AGY_BIN" \
      --arg version "$agy_version" --arg gen "$BUSY_GEN" --arg grants_sha "$agy_grants_sha" \
      --arg judge_tier "$AGY_JUDGE_TIER" --arg judge_bin "$AGY_JUDGE_BIN" \
      --arg judge_model "$AGY_JUDGE_MODEL" --arg config "$agy_config" \
      '{task:$task, worktree:$worktree, status:$status, inbox:$inbox, data:$data, tasktmp:$tasktmp, brief:$brief, log:$log, agy:$agy, gen:$gen, agy_version:$version, judge_tier:$judge_tier, judge_bin:$judge_bin, judge_model:$judge_model, judge_timeout:"60", grants_sha:$grants_sha, config:$config}' \
      > "$agy_policy" || {
      echo "error: cannot spawn agy bypass worker: could not write $agy_policy" >&2
      exit 1
    }
    "$FM_ROOT/bin/fm-agy-hook.sh" install-worker "$STATE_REAL" "$ID" "$BUSY_GEN" "$WT" "$agy_policy" || {
      echo "error: could not install agy worker hooks for $ID" >&2
      exit 1
    }
  else
    "$FM_ROOT/bin/fm-agy-hook.sh" install-worker "$STATE_REAL" "$ID" "$BUSY_GEN" "$WT" || {
      echo "error: could not install agy worker hooks for $ID" >&2
      exit 1
    }
  fi
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
      [ "${source%% *}" != agy-hook ] || return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

# A bypass launch is only trustworthy once the permission adapter proved its
# wiring fires: the armed line lands on the observer log at the adapter's
# first hook call, which agy's own PreInvocation precedes. agy_wait_for_started
# already bounds the session start, so a missing armed line after that point
# means dead wiring - a malformed merge agy skipped silently, a policy path
# typo - not a slow start. The short poll still gives the append time to
# flush before the spawn refuses to trust the bypassed session.
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
    # and any bypass policy wiring here.
    if [ "$RELAUNCH" -ne 1 ]; then
      "$FM_ROOT/bin/fm-agy-hook.sh" retire-worker "$STATE_REAL" "$ID" || true
      "$FM_ROOT/bin/fm-agy-permission-policy.sh" retire \
        "$STATE_REAL/$ID.agy-permission.json" </dev/null 2>/dev/null || true
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
  if ! agy_wait_for_started; then
    agy_spawn_fail "agy did not report starting its brief through its worker hook in window $T"
    exit 1
  fi
  if [ "$AGY_BYPASS" -eq 1 ] && ! agy_wait_for_armed; then
    # A bypassed session whose permission hook never logged its armed line
    # has dead wiring - never trust it; the refusal closes the endpoint.
    agy_spawn_fail "agy bypass canary failed in window $T: the permission hook's armed line never reached the observer log, so this bypassed session's denies cannot be trusted"
    exit 1
  fi
}

# Recorded only when the opt-in bypass posture is armed, so an absent
# field is the accept-edits/manual default every other agy task carries.
# The judge tier rides the recorded posture so a relaunch re-judges on the
# same tier, and so the task's own record answers which judge decided its
# held and approved calls.
fm_agy_meta_lines() {
  [ "$HARNESS" = agy ] || return 0
  local version=''
  # Raw launch commands do not resolve a binary; keep its version unknown.
  if [ -n "${AGY_BIN:-}" ]; then
    version=$("$AGY_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  fi
  echo "agy_version=$version"
  echo "agy_permission_mode=$CREW_PERMISSION_MODE"
  [ "$AGY_BYPASS" -eq 0 ] || echo "agy_bypass=on"
  [ "$AGY_BYPASS" -eq 0 ] || echo "agy_judge=$AGY_JUDGE_TIER:$AGY_JUDGE_MODEL"
}

# The bypass adapter's retire closes every pending escalation as not-run
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
    # The bypass adapter's retire closes every pending escalation as not-run
    # while the policy file still names the status file.
    "$SCRIPT_DIR/fm-agy-permission-policy.sh" retire "$state/$id.agy-permission.json" </dev/null || return 1
  fi
  # Archive before metadata/status removal; an archival failure keeps them
  # available for recovery rather than silently losing judge coverage proof.
  if [ -f "$state/$id.meta" ] && grep -q '^harness=agy$' "$state/$id.meta"; then
    bash "$SCRIPT_DIR/fm-agy-audit.sh" "$state" "$id" || return 1
  fi
  if [ -e "$state/$id.agy-hooks" ] || [ -L "$state/$id.agy-hooks" ]; then
    "$SCRIPT_DIR/fm-agy-hook.sh" retire-worker "$state" "$id" || return 1
  fi
}

# The bypass layer's policy file, escalation markers, and verdict cache
# (bin/fm-agy-permission-policy.sh).
fm_agy_teardown_remove_state() {  # <state-dir> <id>
  rm -f "$1/$2.agy-permission.json"
  rm -rf "$1/$2.agy-permission-pending" "$1/$2.agy-permission-cache"
}
