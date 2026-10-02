#!/usr/bin/env bash
# fm-devin-lib.sh - the fork's Devin worker wiring for bin/fm-spawn.sh and
# bin/fm-teardown.sh. Sourced, never executed.
#
# Kept out of the upstream-owned spawn and teardown scripts so an upstream
# merge meets one-line call sites there instead of the whole Devin
# arm. The harness-adapters devin reference owns the operating facts,
# bin/fm-devin-config.sh owns the private config base (upstream's writer),
# bin/fm-devin-permission-policy.sh owns the permission policy, and
# bin/fm-devin-rate-limit-retry.sh owns the rate-limit retry.
#
#   resolve_devin_binary
#       prints the absolute devin executable, or refuses when none is on PATH
#   fm_devin_permission_flags <crew-permission-mode>
#       prints the launch permission flags for auto or manual
#   fm_devin_launch_model <model>
#       prints the model the launch passes: the requested one, or swe-2-max
#   fm_devin_spawn_wire
#       writes the task's private config and permission policy file (spawn)
#   fm_devin_launch_assert <launch> <crew-permission-mode> <config>
#       refuses a launch missing the reviewed mode or the complete private config
#   fm_devin_relaunch_retire_policy <harness> <state-dir> <id>
#   fm_devin_relaunch_retire_legacy <harness> <worktree>
#       the relaunch retire steps bin/fm-spawn.sh's clear_relaunch_harness_wiring
#       runs around its shared wiring-path removal
#   remove_devin_managed_wiring <meta> <worktree>
#       teardown's retire of the two legacy worktree files
#   fm_devin_teardown_remove_state <state-dir> <id>
#       teardown's removal of the per-task permission policy state
#
# fm_devin_spawn_wire runs inside bin/fm-spawn.sh after the busy-state arm and
# reads that script's globals rather than taking them as arguments: RAW_LAUNCH,
# WT, STATE_REAL, ID, BUSY_GEN, TASK_TMP, BRIEF, FM_ROOT, SCRIPT_DIR, FM_HOME,
# DEVIN_BIN, and HOME, plus its shell_quote helper.
# It exits the spawn on a refusal, exactly as the inline arm did.
# remove_devin_managed_wiring reads the harness through bin/fm-teardown.sh's
# meta_value, and the ownership proof reads bin/fm-control-lib.sh's
# fm_control_harness_family.

# devin ships as a standalone CLI executable. It is resolved to an absolute path
# once here so the pane launches the same executable this spawn checked, and a
# missing install refuses BEFORE any endpoint or worktree exists rather than
# leaving a pane at a "command not found" shell.
resolve_devin_binary() {
  local candidate dir
  candidate=$(command -v devin 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  echo "error: devin executable not found on PATH; install the Devin CLI or select a different verified harness" >&2
  return 1
}

# devin (Devin CLI): auto selects --permission-mode smart, which uses a
# fast model to judge safety and auto-approves workspace edits while
# mutating git commands and in-repo scripts prompt. Firstmate pre-allows
# the approved routine command and task-scoped write set in the task's
# private config. manual selects --permission-mode normal, which drops
# smart's automatic approvals; the same pre-allowed set and permission
# policy hooks still apply, so a call they allow or approve runs without a
# prompt, a refused call is blocked, and the rest prompt. Neither setting
# ever reaches dangerous / bypass or sandbox autonomous mode.
fm_devin_permission_flags() {  # <crew-permission-mode>
  case "${1-}" in
  auto) printf '%s' '--permission-mode smart' ;;
  manual) printf '%s' '--permission-mode normal' ;;
  *) return 1 ;;
  esac
}

# The worker default is SWE-2 Max, passed as the account-listed model id
# because Devin encodes effort in the id and omitting --model would leave the
# choice to Devin's own saved default. An explicit model always passes
# through unchanged, and the permission judge keeps its own SWE-2 High.
fm_devin_launch_model() {  # <model>
  case "${1-}" in
  '' | default) printf '%s' swe-2-max ;;
  *) printf '%s' "$1" ;;
  esac
}

# The non-destructive Exec set and the git push force spellings pinned back
# out of the allowed Exec(git push) prefix; the harness-adapters devin
# reference owns the list and the Exec matching limits. A branch-changing or
# remote-reading command is pre-allowed only in its safe form, and the
# permission policy's pre-tool-use step refuses what those prefixes could
# still admit.
FM_DEVIN_ALLOW_EXEC=(
  'Exec(git add)' 'Exec(git commit)' 'Exec(git push)'
  'Exec(git checkout -b)' 'Exec(git switch -c)'
  'Exec(git remote -v)' 'Exec(git remote get-url)'
  'Exec(git fetch)' 'Exec(git status)' 'Exec(git log)'
  'Exec(git diff)' 'Exec(ls)' 'Exec(gh pr create)' 'Exec(gh pr view)'
  'Exec(gh pr list)' 'Exec(gh pr checks)'
  'Exec(bin/fm-lint.sh)' 'Exec(./bin/fm-lint.sh)' 'Exec(bash bin/fm-lint.sh)'
  'Exec(bin/fm-test-run.sh)' 'Exec(./bin/fm-test-run.sh)' 'Exec(bash bin/fm-test-run.sh)'
  'Exec(bin/fm-install-shellcheck.sh)' 'Exec(./bin/fm-install-shellcheck.sh)'
  'Exec(bash bin/fm-install-shellcheck.sh)'
  'Exec(bin/fm-install-actionlint.sh)' 'Exec(./bin/fm-install-actionlint.sh)'
  'Exec(bash bin/fm-install-actionlint.sh)'
)
FM_DEVIN_DENY_EXEC=(
  'Exec(git push --force)' 'Exec(git push --force-with-lease)'
  'Exec(git push --force-if-includes)' 'Exec(git push -f)'
)

# The two worktree files older incarnations wrote before the private config.
FM_DEVIN_LEGACY_WIRING=(.devin/config.local.json .devin/rules/firstmate-attribution.md)

# The jq filter that proves a composed config carries every mandatory piece
# of the fork's wiring; $spec is the object fm_devin_spawn_wire composed from.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
FM_DEVIN_CONFIG_COMPLETE='
  def has_cmd($event; $cmd): any(.hooks[$event][]?.hooks[]?; .command == $cmd);
  ($spec.keep_trailers or .attribution == false)
  and (.permissions.allow as $a | all($spec.allow[]; . as $e | $a | index([$e])))
  and (.permissions.deny as $d | all($spec.deny[]; . as $e | $d | index([$e])))
  and has_cmd("PreToolUse"; $spec.pre) and has_cmd("PermissionRequest"; $spec.perm)
  and has_cmd("PostToolUse"; $spec.post)
  and has_cmd("UserPromptSubmit"; $spec.policy_stop) and has_cmd("Stop"; $spec.policy_stop)
  and has_cmd("SessionEnd"; $spec.policy_stop)
  and has_cmd("UserPromptSubmit"; $spec.retry_arm) and has_cmd("Stop"; $spec.retry_stop)
  and has_cmd("SessionEnd"; $spec.retry_end)
'

fm_devin_spawn_wire() {
  local managed config user_config snapshot staged spec devin_task_data \
    devin_policy devin_grants_sha policy_cmd policy_file retry_cmd retry_args
  [ "$RAW_LAUNCH" -eq 0 ] || return 0
  # Devin runs as a reviewed worker on a private config: upstream's
  # bin/fm-devin-config.sh copies the user config (~/.config/devin/config.json)
  # to state/<id>.devin-config.json with the busy-state and turn-end hooks
  # appended, and the launch passes it with --config, which replaces only the
  # user layer; project .devin config still merges over it and nothing in the
  # worktree or the user's own config is written. This decorator then layers
  # the fork's review onto that one file:
  # - permissions.allow and permissions.deny gain the Exec set above plus the
  #   task-scoped status, inbox, and temp writes, after the user's own rules.
  # - PreToolUse, PermissionRequest, PostToolUse, UserPromptSubmit, Stop, and
  #   SessionEnd also run bin/fm-devin-permission-policy.sh, firstmate's
  #   permission decision layer (refuse list, read-and-build approvals, SWE-2
  #   High first judge, escalation to the status file); its header owns the
  #   policy. The script and its per-task policy file under state/ live outside
  #   the worktree, and Devin reads hooks once at session start.
  # - UserPromptSubmit, Stop, and SessionEnd also run the rate-limit retry.
  # - read_config_from returns to the user's own choice: the base writer
  #   forces Claude import off, and this fork keeps Devin's default import of
  #   CLAUDE.md, .claude/skills, and Claude hooks unless the user turned it off.
  # attribution stays false, as the base writer set it, unless the home keeps
  # AI trailers (config/keep-ai-trailers). Every hook the
  # decorator adds joins the base writer's own group for that event, so it
  # runs beside the busy-state hook exactly as the local config ran them.
  # The final file is published atomically at mode 600, and any failed step
  # removes it and refuses the launch: a worker never starts on the
  # undecorated base.
  # A legacy worktree config from an older incarnation would layer its own
  # hooks, for a retired task, over this one, so an untracked leftover still
  # refuses the spawn; a tracked one is the project's own layer.
  for managed in "${FM_DEVIN_LEGACY_WIRING[@]}"; do
    ! git -C "$WT" ls-files --error-unmatch "$managed" >/dev/null 2>&1 || continue
    if [ -e "$WT/$managed" ] || [ -L "$WT/$managed" ]; then
      echo "error: cannot spawn devin worker: $WT/$managed already exists as an untracked leftover" >&2
      exit 1
    fi
  done
  command -v jq >/dev/null 2>&1 || {
    echo "error: cannot spawn devin worker: jq is required by the devin permission policy hook; install jq or select a different verified harness" >&2
    exit 1
  }
  config="$STATE_REAL/$ID.devin-config.json"
  user_config="${HOME:-}/.config/devin/config.json"
  # One private snapshot feeds both the base writer and the decorator's
  # Claude-import restore, so both read the same user config.
  snapshot=$(umask 077 && mktemp "$STATE_REAL/.$ID.devin-user-config.XXXXXX") || {
    echo "error: cannot spawn devin worker: could not stage the user config snapshot" >&2
    exit 1
  }
  if [ -e "$user_config" ] || [ -L "$user_config" ]; then
    cat -- "$user_config" >"$snapshot" 2>/dev/null || {
      rm -f -- "$snapshot"
      echo "error: cannot spawn devin worker: could not read $user_config" >&2
      exit 1
    }
  fi
  FM_KEEP_AI_TRAILERS="${KEEP_AI_TRAILERS:-0}" "$SCRIPT_DIR/fm-devin-config.sh" "$STATE_REAL" "$ID" "$BUSY_GEN" "$snapshot" || {
    rm -f -- "$snapshot" "$config"
    echo "error: cannot spawn devin worker: could not write the private config from $user_config" >&2
    exit 1
  }
  devin_task_data=$(cd "$(dirname "$BRIEF")" && pwd -P)
  devin_policy="$STATE_REAL/$ID.devin-permission.json"
  # The digest pins the grants block firstmate wrote, so a block the
  # worker adds or edits in its own brief grants nothing.
  devin_grants_sha=$("$SCRIPT_DIR/fm-devin-permission-policy.sh" grants-digest "$BRIEF" 2>/dev/null || true)
  devin_config=${CONFIG:-${FM_HOME:-}/config}
  case "$devin_config" in /*) ;; *) devin_config="$PWD/$devin_config" ;; esac
  jq -n --arg task "$ID" --arg worktree "$(cd "$WT" && pwd -P)" \
    --arg status "$STATE_REAL/$ID.status" --arg inbox "$STATE_REAL/$ID.inbox" \
    --arg data "$devin_task_data" --arg tasktmp "$TASK_TMP" --arg brief "$BRIEF" \
    --arg log "$STATE_REAL/devin-permission-log.jsonl" --arg devin "${DEVIN_BIN:-}" \
    --arg grants_sha "$devin_grants_sha" --arg config "$devin_config" \
    '{task:$task, worktree:$worktree, status:$status, inbox:$inbox, data:$data, tasktmp:$tasktmp, brief:$brief, log:$log, devin:$devin, judge_model:"swe-2-high", judge_timeout:"60", grants_sha:$grants_sha, config:$config}' \
    >"$devin_policy" || {
    rm -f -- "$snapshot" "$config"
    echo "error: cannot spawn devin worker: could not write $devin_policy" >&2
    exit 1
  }
  policy_cmd="$(shell_quote "$FM_ROOT/bin/fm-devin-permission-policy.sh")"
  policy_file=$(shell_quote "$devin_policy")
  # The rate-limit retry (bin/fm-devin-rate-limit-retry.sh, whose header owns
  # it): UserPromptSubmit arms a per-turn sentinel on Devin's session log,
  # Stop and SessionEnd retire it, because the rate-limit error itself fires
  # no hook.
  retry_cmd="$(shell_quote "$FM_ROOT/bin/fm-devin-rate-limit-retry.sh")"
  retry_args="$(shell_quote "$STATE_REAL") $(shell_quote "$ID") $(shell_quote "$FM_HOME") >/dev/null 2>&1 || true"
  # The task data directory deliberately gets NO blanket Write allow: the
  # brief lives there, and an allow rule would let the worker rewrite its
  # own instructions and grants without the permission hook ever seeing
  # it. Data-directory writes instead reach PermissionRequest, where
  # bin/fm-devin-permission-policy.sh approves them silently and refuses
  # the brief.
  spec=$(jq -n \
    --arg pre "$policy_cmd pre-tool-use $policy_file" \
    --arg perm "$policy_cmd permission-request $policy_file" \
    --arg post "$policy_cmd post-tool-use $policy_file" \
    --arg policy_stop "$policy_cmd stop $policy_file" \
    --arg retry_arm "$retry_cmd arm $retry_args" \
    --arg retry_stop "$retry_cmd stop $retry_args" \
    --arg retry_end "$retry_cmd end $retry_args" \
    --arg w_status "Write($STATE_REAL/$ID.status)" \
    --arg w_inbox "Write($STATE_REAL/$ID.inbox)" \
    --arg w_tmp "Write($TASK_TMP)" \
    --argjson keep_trailers "$( [ "${KEEP_AI_TRAILERS:-0}" = 1 ] && printf true || printf false)" \
    --argjson exec "$(jq -n '$ARGS.positional' --args "${FM_DEVIN_ALLOW_EXEC[@]}")" \
    --argjson deny "$(jq -n '$ARGS.positional' --args "${FM_DEVIN_DENY_EXEC[@]}")" \
    '{pre:$pre, perm:$perm, post:$post, policy_stop:$policy_stop, retry_arm:$retry_arm,
      retry_stop:$retry_stop, retry_end:$retry_end, keep_trailers:$keep_trailers,
      allow:($exec + [$w_status, $w_inbox, $w_tmp]), deny:$deny}') || spec=
  staged=$(umask 077 && mktemp "$STATE_REAL/.$ID.devin-config.XXXXXX") || staged=
  # shellcheck disable=SC2016 # jq variables, not shell expansions.
  if [ -z "$spec" ] || [ -z "$staged" ] ||
    ! jq --argjson spec "$spec" --slurpfile user "$snapshot" '
      def cmd($c; $t): {type: "command", command: $c, timeout: $t};
      def join_group($event; $cmds): .hooks[$event][-1].hooks += $cmds;
      def group($event; $matcher; $cmd):
        .hooks[$event] = ((.hooks[$event] // []) + [{matcher: $matcher, hooks: [$cmd]}]);
      ($user[0] // {}) as $u
      | .permissions = ((.permissions // {})
          | .allow = ((.allow // []) + $spec.allow)
          | .deny = ((.deny // []) + $spec.deny))
      | join_group("UserPromptSubmit"; [cmd($spec.policy_stop; 30), cmd($spec.retry_arm; 30)])
      | join_group("Stop"; [cmd($spec.policy_stop; 30), cmd($spec.retry_stop; 30)])
      | join_group("SessionEnd"; [cmd($spec.policy_stop; 30), cmd($spec.retry_end; 30)])
      | group("PreToolUse"; "^exec$"; cmd($spec.pre; 30))
      | group("PermissionRequest"; ""; cmd($spec.perm; 120))
      | group("PostToolUse"; ""; cmd($spec.post; 30))
      | if ($u | type) == "object" and ($u | has("read_config_from"))
        then .read_config_from = $u.read_config_from
        else del(.read_config_from) end
    ' "$config" >"$staged" 2>/dev/null ||
    ! jq -e --argjson spec "$spec" "$FM_DEVIN_CONFIG_COMPLETE" "$staged" >/dev/null 2>&1 ||
    ! mv -f -- "$staged" "$config"; then
    rm -f -- "$snapshot" "$config" ${staged:+"$staged"}
    echo "error: cannot spawn devin worker: could not compose the reviewed private config at $config" >&2
    exit 1
  fi
  rm -f -- "$snapshot"
  FM_DEVIN_WIRED_SPEC=$spec
}

# The completed launch must carry exactly the selected reviewed mode and the
# private config, and that config must still carry every mandatory piece of
# the wiring fm_devin_spawn_wire composed; anything else refuses rather than
# starting a worker without its review.
fm_devin_launch_assert() {  # <launch> <crew-permission-mode> <config>
  local launch=${1-} flags config=${3-} rest
  flags=$(fm_devin_permission_flags "${2-}") || {
    echo "error: cannot launch devin worker: no reviewed permission mode for '${2-}'" >&2
    return 1
  }
  rest=${launch#*--permission-mode }
  case "$launch" in
  *" $flags --respect-workspace-trust false --config $(shell_quote "$config") "*) ;;
  *)
    echo "error: cannot launch devin worker: the launch lacks $flags with its private config" >&2
    return 1
    ;;
  esac
  case "$rest" in
  *--permission-mode* | *--sandbox*)
    echo "error: cannot launch devin worker: the launch carries a second permission or sandbox flag" >&2
    return 1
    ;;
  esac
  if [ ! -f "$config" ] || [ -z "${FM_DEVIN_WIRED_SPEC:-}" ] ||
    ! jq -e --argjson spec "$FM_DEVIN_WIRED_SPEC" "$FM_DEVIN_CONFIG_COMPLETE" "$config" >/dev/null 2>&1; then
    echo "error: cannot launch devin worker: $config lacks the reviewed permission wiring" >&2
    return 1
  fi
}

# Relaunch retire, before the shared wiring paths go: the policy's retire
# closes every pending escalation while the policy file still names the
# status file, and only then does the policy file itself go.
fm_devin_relaunch_retire_policy() {  # <harness> <state-dir> <id>
  [ "${1-}" = devin ] || return 0
  "$SCRIPT_DIR/fm-devin-rate-limit-retry.sh" retire "$2" "$3" - </dev/null || return 1
  "$SCRIPT_DIR/fm-devin-permission-policy.sh" retire "$2/$3.devin-permission.json" </dev/null || return 1
  rm -f -- "$2/$3.devin-permission.json"
}

# Whether the legacy devin file at <worktree>/<relpath> is provably
# firstmate-owned wiring, safe to retire. A path git tracks is the project's
# own and never qualifies - removing it would strand a dirty worktree missing
# a tracked file if the worktree return then fails, and an older spawn's
# launch refusal means a devin incarnation's own copies were never tracked to
# begin with. An untracked path qualifies when the task's recorded harness
# resolves to devin, or when the path still sits in the git info/exclude list
# older spawns wrote for exactly the two legacy files: the shape a pooled
# worktree keeps after an older teardown left the files behind under a later
# non-devin task.
fm_devin_legacy_wiring_owned() {  # <recorded-harness> <worktree> <relpath>
  local harness=${1-} wt=${2-} rel=${3-} excl
  [ -n "$wt" ] && [ -n "$rel" ] || return 1
  ! git -C "$wt" ls-files --error-unmatch "$rel" >/dev/null 2>&1 || return 1
  [ "$(fm_control_harness_family "$harness" 2>/dev/null || true)" = devin ] && return 0
  excl=$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null) \
    && [ -n "$excl" ] || return 1
  grep -qxF "$rel" "$excl" 2>/dev/null
}

# Retire the two legacy worktree files only where they are provably
# firstmate's, then the directories they emptied, only while empty: rmdir's
# own check protects any project content sharing the path.
fm_devin_retire_legacy_wiring() {  # <recorded-harness> <worktree>
  local harness=${1-} wt=${2-} rel
  [ -n "$wt" ] || return 0
  for rel in "${FM_DEVIN_LEGACY_WIRING[@]}"; do
    if fm_devin_legacy_wiring_owned "$harness" "$wt" "$rel"; then
      rm -f -- "$wt/$rel" || return 1
    fi
  done
  rmdir "$wt/.devin/rules" "$wt/.devin" 2>/dev/null || true
}

# Relaunch retire of an older devin incarnation's worktree wiring, after the
# shared wiring paths (the private config) go.
fm_devin_relaunch_retire_legacy() {  # <harness> <worktree>
  [ "${1-}" = devin ] || return 0
  fm_devin_retire_legacy_wiring devin "${2-}"
}

# Teardown's retire of the legacy worktree files, for the task's recorded
# harness; fm_devin_legacy_wiring_owned owns the ownership proof.
remove_devin_managed_wiring() {  # <meta> <worktree>
  fm_devin_retire_legacy_wiring "$(meta_value "$1" harness)" "$2" || true
}

# The per-task policy file, plus the permission-policy escalation markers and
# verdict cache (bin/fm-devin-permission-policy.sh), and the rate-limit retry
# state, whose removal also ends a running sentinel
# (bin/fm-devin-rate-limit-retry.sh). A retry state that cannot be retired
# stops teardown before the task record goes, as the agy retire does, so its
# open blocker is never orphaned and a re-run retries it.
fm_devin_teardown_remove_state() {  # <state-dir> <id>
  rm -f "$1/$2.devin-permission.json"
  rm -rf "$1/$2.devin-permission-pending" "$1/$2.devin-permission-cache"
  # Only a task that left retry state behind, current or mid-retire, has
  # anything to retire.
  [ -e "$1/$2.devin-retry" ] || compgen -G "$1/$2.devin-retry.retiring.*" >/dev/null || return 0
  "$SCRIPT_DIR/fm-devin-rate-limit-retry.sh" retire "$1" "$2" - </dev/null && return 0
  echo "error: $2's Devin rate-limit retry state under $1 could not be retired (see $1/devin-rate-limit-log.jsonl); fix it and re-run teardown" >&2
  return 1
}
