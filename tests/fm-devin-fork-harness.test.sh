#!/usr/bin/env bash
# Fork-only Devin adapter behavior: ancestry anchoring under a real Devin
# parent, session-lock exclusion, reviewed approval-mode mapping and refusals,
# the fork's launch seams (scrub, task TMPDIR, SWE-2 Max default), the reviewed
# private-config decoration (permission policy, rate-limit retry, user settings
# and Claude import), legacy worktree-wiring migration and cleanup, raw launch,
# and dispatch validation. The common adapter contract shared with upstream is
# tests/fm-devin-harness.test.sh; the full composer frame is
# tests/fm-composer-devin.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Drop foreign markers that could mask the signals under test.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS GEMINI_CLI JETSKI_APP_DATA_DIR ATLASSIAN_AGENT_TYPE \
  ROVODEV_CLI FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)

# --- detection & ancestry ---------------------------------------------------


test_devin_ancestry_detection_and_anchoring() {
  local dir="$TMP_ROOT/ancestry" out clean probe blind_fakebin blind_probe
  mkdir -p "$dir"
  command -v cc >/dev/null 2>&1 || {
    printf 'skip - fm-harness.sh: devin ancestry needs cc to build a named process\n'
    return 0
  }
  cat > "$dir/run.c" <<'C'
#include <stdlib.h>
int main(int argc, char **argv) { if (argc < 2) return 1; return system(argv[1]) == 0 ? 0 : 1; }
C
  clean="env -u JETSKI_APP_DATA_DIR -u CLAUDECODE -u CURSOR_AGENT"
  clean="$clean -u CURSOR_INVOKED_AS -u GEMINI_CLI -u PI_CODING_AGENT"
  clean="$clean -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI"
  probe="$clean $HARNESS"

  cc -o "$dir/devin" "$dir/run.c" 2>/dev/null \
    || fail "could not build the devin ancestry probe"
  # Exact devin ancestor alone detects devin via comm match.
  out=$("$dir/devin" "$probe" | tr -d '\n')
  [ "$out" = devin ] || fail "an exact devin ancestor must detect devin, got '$out'"

  # Anchored match: devin-other or mydevin must NOT detect devin. Their probes
  # must see no devin ancestor at all, so the walk is cut only above this test
  # shell's own pid (fm_fake_blind_ancestry_above) - a real devin process above
  # the suite is exactly what they would otherwise detect. The decoy layer
  # below the cut is still examined under its real name, proven by the
  # exact-name probe under the same cut so the anchored asserts cannot pass
  # vacuously.
  blind_fakebin=$(fm_fakebin "$dir/blind-ancestry")
  fm_fake_blind_ancestry_above "$blind_fakebin" "$$"
  blind_probe="$clean PATH='$blind_fakebin:$PATH' $HARNESS"
  out=$("$dir/devin" "$blind_probe" | tr -d '\n')
  [ "$out" = devin ] \
    || fail "an exact devin ancestor must still detect under the ancestry cut, got '$out'"
  cc -o "$dir/devin-other" "$dir/run.c" 2>/dev/null \
    || fail "could not build the devin-other probe"
  out=$("$dir/devin-other" "$blind_probe" | tr -d '\n')
  [ "$out" != devin ] || fail "devin-other must not be detected as devin"

  cc -o "$dir/mydevin" "$dir/run.c" 2>/dev/null \
    || fail "could not build the mydevin probe"
  out=$("$dir/mydevin" "$blind_probe" | tr -d '\n')
  [ "$out" != devin ] || fail "mydevin must not be detected as devin"

  pass "fm-harness.sh: devin ancestry detects devin and is strictly anchored"
}

# --- session lock & process classification ----------------------------------

test_devin_agent_process_classification() {
  local res
  res=$(fm_agent_process_classify_name "devin")
  [ "$res" = agent ] || fail "devin command must classify as agent, got '$res'"

  res=$(fm_agent_process_classify_name "/opt/homebrew/bin/devin")
  [ "$res" = agent ] || fail "/opt/homebrew/bin/devin must classify as agent, got '$res'"

  res=$(fm_agent_process_classify_name "devin-worker")
  [ "$res" != agent ] || fail "devin-worker must not classify as agent"

  # Devin cannot own primary session lock: not in FM_HARNESS_RE or FM_HARNESS_NAMES
  ! printf '%s\n' "devin" | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE must not match devin (cannot own primary session lock)"

  case " ${FM_HARNESS_NAMES[*]} " in
    *" devin "*) fail "FM_HARNESS_NAMES must not contain devin" ;;
    *) ;;
  esac

  # fm_harness_path_name does not recognize devin (excluded from primary session lock)
  ! fm_harness_path_name "/opt/homebrew/bin/devin" >/dev/null \
    || fail "fm_harness_path_name must not match devin (excluded from primary lock candidates)"

  pass "fm-agent-process-lib: devin process classification matches agent (excluded from primary session lock)"
}

# --- control mechanics ------------------------------------------------------

test_devin_control_contract() {
  fm_control_harness_supported devin || fail "devin must be a supported control harness"
  [ "$(fm_control_harness_family devin)" = devin ] || fail "devin family must be devin"
  fm_control_harness_supports_kind devin crew || fail "devin must support crew"
  [ "$(fm_control_interrupt_ack_source devin)" = none ] || fail "devin interrupt ack source must be none"
  pass "fm-control-lib: devin control family, crew kind, and interrupt ack source"
}

# --- spawn scaffolding ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        # A spawn types a short line sourcing its staged launch file; log the
        # staged command itself so assertions read what the pane runs.
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || arg=$(cat "$staged") ;;
        esac
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" devin gh-axi gh
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="devin-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise devin dispatch.

## Firstmate spec
Verify the devin harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_devin_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  local harness=${DEVIN_HARNESS_ARG:-devin}
  # HOME isolates the user config the private Devin config is copied from.
  mkdir -p "$home/userhome"
  HOME="$home/userhome" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="${FM_TEST_PATH_OVERRIDE:-$fakebin:$PATH}" \
    "$SPAWN" "$id" "$proj" "$harness" "$@" 2>&1
}

run_devin_teardown() {  # <home> <fakebin> <id> [extra args...]
  local home=$1 fakebin=$2 id=$3
  shift 3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="${FM_TEST_PATH_OVERRIDE:-$fakebin:$PATH}" \
    "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
}

# --- permissions & launch template ------------------------------------------

test_devin_auto_uses_smart_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case auto)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'auto\n' > "$home/config/crew-permissions"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--permission-mode smart'*) ;;
    *) fail "auto must launch devin with --permission-mode smart, got: $launch" ;;
  esac
  case "$launch" in
    *dangerous*|*bypass*|*autonomous*|*--sandbox*|*--yolo*)
      fail "auto must never reach blanket approval bypass or sandbox autonomous mode: $launch" ;;
  esac
  pass "fm-spawn.sh: devin auto selects --permission-mode smart, never bypass"
}

test_devin_manual_uses_normal_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case manual)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'manual\n' > "$home/config/crew-permissions"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--permission-mode normal'*) ;;
    *) fail "manual must launch devin with --permission-mode normal, got: $launch" ;;
  esac
  case "$launch" in
    *dangerous*|*bypass*|*autonomous*|*--yolo*)
      fail "manual must never reach blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: devin manual selects --permission-mode normal"
}

test_devin_absent_setting_defaults_to_smart() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case absent)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--permission-mode smart'*) ;;
    *) fail "absent crew-permissions must default to --permission-mode smart, got: $launch" ;;
  esac
  pass "fm-spawn.sh: absent crew-permissions defaults devin to --permission-mode smart"
}

test_devin_invalid_setting_refuses() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case invalid)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'yolo\n' > "$home/config/crew-permissions"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "an invalid permission setting must refuse the devin launch"
  case "$out" in
    *'invalid config/crew-permissions'*) ;;
    *) fail "refusal must name config/crew-permissions, got: $out" ;;
  esac
  [ ! -s "$home/launch.log" ] || fail "refused launch must not reach pane"
  pass "fm-spawn.sh: invalid crew-permissions refuses devin launch"
}

test_devin_missing_binary_refuses() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case missing-bin)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/devin"
  ln -sf "$(command -v git)" "$fakebin/git"
  out=$(FM_TEST_PATH_OVERRIDE="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "devin spawn must refuse when binary is missing from PATH"
  case "$out" in
    *'devin executable not found on PATH'*) ;;
    *) fail "refusal must name devin not installed/executable, got: $out" ;;
  esac
  pass "fm-spawn.sh: missing devin binary refuses before spawn"
}

test_devin_launch_shape_and_model_handling() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case shape)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")

  # Color and foreign-marker scrub. The common suite owns the private config,
  # trust, model pass-through, effort omission, and typed brief.
  local flag
  for flag in '-u NO_COLOR' '-u ATLASSIAN_AGENT_TYPE' '-u ROVODEV_CLI' '-u CLAUDECODE' '-u CURSOR_AGENT'; do
    case "$launch" in
      *"$flag "*) ;;
      *) fail "launch must clear ${flag#-u }, got: $launch" ;;
    esac
  done
  case "$launch" in
    *"TMPDIR='/tmp/fm-$id'"*) ;;
    *) fail "launch must isolate Devin temporary files under the task temp root, got: $launch" ;;
  esac

  # An omitted or default model launches the SWE-2 Max worker default.
  fields=$(make_spawn_case shape-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --model default >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *"--model 'swe-2-max' --"*) ;;
    *) fail "a default model must launch devin on swe-2-max, got: $launch" ;;
  esac
  fields=$(make_spawn_case shape-omitted)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *"--model 'swe-2-max' --"*) ;;
    *) fail "an omitted model must launch devin on swe-2-max, got: $launch" ;;
  esac

  pass "fm-spawn.sh: devin launch scrub, task TMPDIR, private config, and SWE-2 Max default"
}


# --- hooks generation, validation & execution -------------------------------

test_devin_hooks_generation_validation_and_execution() {
  local fields case_dir home proj wt fakebin id hook_file exclude_file
  local out cmd_submit cmd_stop cmd_end
  fields=$(make_spawn_case hooks-exec)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  hook_file="$home/state/$id.devin-config.json"
  [ -f "$hook_file" ] || fail "hooks file was not created at $hook_file"
  case "$(ls -l "$hook_file")" in
    -rw-------*) ;;
    *) fail "the private config must be mode 600: $(ls -l "$hook_file")" ;;
  esac
  [ ! -e "$wt/.devin" ] || fail "spawn must write nothing under the worktree's .devin"

  # Validate JSON syntax
  jq . "$hook_file" >/dev/null 2>&1 || fail "hooks file is not valid JSON: $(cat "$hook_file")"

  # Attribution pinned to false
  [ "$(jq -r '.attribution' "$hook_file")" = "false" ] || fail "attribution must be false"

  # Pre-allowed permissions: the non-destructive Exec set, checked through
  # the generated config.
  local entry
  for entry in \
    "Exec(git add)" "Exec(git commit)" "Exec(git push)" \
    "Exec(git checkout -b)" "Exec(git switch -c)" "Exec(git remote -v)" "Exec(git remote get-url)" \
    "Exec(git fetch)" "Exec(git status)" "Exec(git log)" "Exec(git diff)" \
    "Exec(ls)" \
    "Exec(gh pr create)" "Exec(gh pr view)" "Exec(gh pr list)" "Exec(gh pr checks)" \
    "Exec(bin/fm-lint.sh)" "Exec(./bin/fm-lint.sh)" "Exec(bash bin/fm-lint.sh)" \
    "Exec(bin/fm-test-run.sh)" "Exec(./bin/fm-test-run.sh)" "Exec(bash bin/fm-test-run.sh)" \
    "Exec(bin/fm-install-shellcheck.sh)" "Exec(./bin/fm-install-shellcheck.sh)" "Exec(bash bin/fm-install-shellcheck.sh)" \
    "Exec(bin/fm-install-actionlint.sh)" "Exec(./bin/fm-install-actionlint.sh)" "Exec(bash bin/fm-install-actionlint.sh)" \
    "Write($home/state/$id.status)" \
    "Write($home/state/$id.inbox)" "Write(/tmp/fm-$id)"; do
    jq -e --arg e "$entry" '.permissions.allow | index($e)' "$hook_file" >/dev/null \
      || fail "permissions.allow must contain $entry"
  done
  # The task data directory holds the brief, so it gets NO blanket Write allow:
  # a write there must reach PermissionRequest, where the policy hook refuses
  # the brief and approves everything else.
  jq -e --arg e "Write($home/data/$id)" '.permissions.allow | index($e) | not' "$hook_file" >/dev/null \
    || fail "permissions.allow must NOT blanket-allow writes to the task data directory"

  # Force-push spellings are denied back out of the allowed Exec(git push)
  # prefix; rm, gh repo, and blanket bypass stay unallowed.
  for entry in \
    "Exec(git push --force)" "Exec(git push --force-with-lease)" \
    "Exec(git push --force-if-includes)" "Exec(git push -f)"; do
    jq -e --arg e "$entry" '.permissions.deny | index($e)' "$hook_file" >/dev/null \
      || fail "permissions.deny must contain $entry"
  done
  ! jq -e '.permissions.allow | map(select(test("Exec\\(rm[ )]|gh repo|git push.*force|Exec\\(git\\)|Exec\\(gh\\)|Exec\\(bash\\)|\\*"))) | length > 0' "$hook_file" >/dev/null \
    || fail "permissions.allow must not contain rm, gh repo, force-push, or blanket entries"
  # Branch-changing and remote commands are pre-allowed only in their safe
  # forms: a bare prefix would also admit the forms that discard work or
  # repoint a remote.
  for entry in "Exec(git checkout)" "Exec(git remote)" "Exec(git switch)"; do
    jq -e --arg e "$entry" '.permissions.allow | index($e) | not' "$hook_file" >/dev/null \
      || fail "permissions.allow must not contain the bare $entry prefix"
  done

  # Devin's own Claude import default stays: an absent user choice stays absent.
  ! jq -e 'has("read_config_from")' "$hook_file" >/dev/null \
    || fail "an absent user read_config_from must stay absent: $(jq -c .read_config_from "$hook_file")"

  # Hooks events: UserPromptSubmit, Stop, SessionEnd present; SessionStart absent
  jq -e '.hooks.UserPromptSubmit and .hooks.Stop and .hooks.SessionEnd' "$hook_file" >/dev/null \
    || fail "hooks missing expected lifecycle events in .hooks"
  ! jq -e '.hooks.SessionStart' "$hook_file" >/dev/null \
    || fail "SessionStart hook must be absent to prevent false busy on resume"

  # Permission policy hooks: the script and policy file live outside the
  # worktree, the refusal guard matches exec, and the decision hook matches
  # every tool. The policy file names this task's paths and the SWE-2 judge.
  local policy="$home/state/$id.devin-permission.json" cmd_pre cmd_perm cmd_post cmd_policy_stop payload
  [ -f "$policy" ] || fail "spawn must write the permission policy file at $policy"
  [ "$(jq -r '.task + "|" + .judge_model + "|" + .log' "$policy")" = "$id|swe-2-high|$home/state/devin-permission-log.jsonl" ] \
    || fail "policy file must name the task, the swe-2-high judge, and the home log: $(cat "$policy")"
  [ "$(jq -r .worktree "$policy")" = "$(cd "$wt" && pwd -P)" ] || fail "policy worktree must be the task worktree"
  [ "$(jq -r .status "$policy")" = "$home/state/$id.status" ] || fail "policy status must be the task status file"
  [ -x "$(jq -r .devin "$policy")" ] || fail "policy judge executable must be the resolved devin binary"
  # The digest pin must be present even for a brief that declares no grants,
  # because an absent digest is what makes a block the worker adds inert.
  jq -e 'has("grants_sha")' "$policy" >/dev/null \
    || fail "policy file must record the brief's grants digest: $(cat "$policy")"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$hook_file")" = '^exec$' ] || fail "PreToolUse guard must match exec"
  [ "$(jq -r '.hooks.PermissionRequest[0].matcher' "$hook_file")" = '' ] || fail "PermissionRequest must match every tool"
  cmd_pre=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hook_file")
  cmd_perm=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$hook_file")
  cmd_post=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$hook_file")
  cmd_policy_stop=$(jq -r '.hooks.Stop[0].hooks[1].command' "$hook_file")
  [ "$cmd_policy_stop" = "$(jq -r '.hooks.SessionEnd[0].hooks[1].command' "$hook_file")" ] \
    && [ "$cmd_policy_stop" = "$(jq -r '.hooks.UserPromptSubmit[0].hooks[1].command' "$hook_file")" ] \
    || fail "Stop, SessionEnd, and UserPromptSubmit must all close pending escalations"
  case "$cmd_perm" in
    *"$wt"*) fail "the permission hook command must not live inside the worktree: $cmd_perm" ;;
  esac
  payload='{"tool_name":"exec","tool_input":{"command":"sudo true"},"tool_use_id":"e1"}'
  out=$(printf '%s' "$payload" | sh -c "$cmd_pre") && fail "generated PreToolUse hook must refuse sudo"
  case "$out" in *'"decision":"block"'*) ;; *) fail "generated PreToolUse refusal must print block, got: $out" ;; esac
  payload='{"tool_name":"exec","tool_input":{"command":"git merge-base HEAD origin/main"},"tool_use_id":"e2"}'
  out=$(printf '%s' "$payload" | sh -c "$cmd_perm") || fail "generated PermissionRequest hook failed"
  case "$out" in *'"decision":"approve"'*) ;; *) fail "generated PermissionRequest must approve git merge-base, got: $out" ;; esac
  # The fake devin gives the judge no verdict, so residue escalates to the
  # status file and the PostToolUse hook closes it.
  payload='{"tool_name":"exec","tool_input":{"command":"make deploy"},"tool_use_id":"e3"}'
  out=$(printf '%s' "$payload" | sh -c "$cmd_perm") || fail "generated PermissionRequest hook failed on residue"
  [ -z "$out" ] || fail "residue must fall through to the prompt, got: $out"
  grep -q '^needs-decision \[key=devin-permission-e3\]: .*make deploy' "$home/state/$id.status" \
    || fail "residue must escalate to the task status file: $(cat "$home/state/$id.status" 2>/dev/null)"
  printf '%s' "$payload" | sh -c "$cmd_post" || fail "generated PostToolUse hook failed"
  grep -q '^resolved \[key=devin-permission-e3\]: ' "$home/state/$id.status" \
    || fail "PostToolUse must close the escalation"
  sh -c "$cmd_policy_stop" </dev/null || fail "generated policy Stop hook failed"

  # Rate-limit retry hooks: UserPromptSubmit arms a sentinel on the session
  # log of the devin process running the hook, and Stop retires it. The
  # trailing `:` keeps bash from exec-ing the hook in place of that process.
  local cmd_retry_arm cmd_retry_stop fake_devin_script retry_logs="$case_dir/devin-logs"
  cmd_retry_arm=$(jq -r '.hooks.UserPromptSubmit[0].hooks[2].command' "$hook_file")
  cmd_retry_stop=$(jq -r '.hooks.Stop[0].hooks[2].command' "$hook_file")
  case "$(jq -r '.hooks.SessionEnd[0].hooks[2].command' "$hook_file")" in
    *fm-devin-rate-limit-retry.sh*' end '*) ;;
    *) fail "SessionEnd must retire the rate-limit retry sentinel" ;;
  esac
  mkdir -p "$retry_logs"
  ln -s "$(command -v bash)" "$case_dir/devin"
  # shellcheck disable=SC2016 # The fake devin is bash; its -c script expands its own arguments.
  fake_devin_script=': >"$1/devin_test_$$.log"; sh -c "$2"; :'
  printf '{"session_id":"s1"}' | FM_DEVIN_RETRY_LOG_DIR="$retry_logs" FM_DEVIN_RETRY_POLL=1 \
    "$case_dir/devin" -c "$fake_devin_script" _ "$retry_logs" "$cmd_retry_arm" \
    || fail "generated rate-limit arm hook failed"
  [ -s "$home/state/$id.devin-retry/turn" ] || fail "the arm hook must open a retry turn for the task"
  ! grep -q '"event":"unarmed"' "$home/state/devin-rate-limit-log.jsonl" 2>/dev/null \
    || fail "the arm hook must find the session log of the process running it"
  printf '{}' | sh -c "$cmd_retry_stop" || fail "generated rate-limit stop hook failed"
  case "$(cat "$home/state/$id.devin-retry/turn")" in
    ended.*) ;;
    *) fail "the Stop hook must retire the retry turn" ;;
  esac

  # Nothing in the worktree needs a git exclude entry any more.
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  ! grep -q '^\.devin/' "$exclude_file" 2>/dev/null \
    || fail "spawn must not add .devin exclude entries: $(cat "$exclude_file")"

  # Verify busy generation was armed
  [ -f "$home/state/$id.busy-gen" ] || fail "busy generation was not armed: missing $id.busy-gen"
  [ -f "$home/state/$id.busy-state" ] || fail "busy state missing: $id.busy-state"

  # Initial classification after spawn seed is 'busy fm-spawn'
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "busy fm-spawn" ] || fail "initial state after spawn must be 'busy fm-spawn', got '$out'"

  # Extract hook commands
  cmd_submit=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$hook_file")
  cmd_stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$hook_file")
  cmd_end=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$hook_file")

  # Execute UserPromptSubmit hook
  sh -c "$cmd_submit" || fail "UserPromptSubmit hook command failed: $cmd_submit"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "busy devin-hook" ] || fail "after UserPromptSubmit state must be 'busy devin-hook', got '$out'"

  # Execute Stop hook: touches turn-ended and transitions to idle
  rm -f "$home/state/$id.turn-ended"
  sh -c "$cmd_stop" || fail "Stop hook command failed: $cmd_stop"
  [ -f "$home/state/$id.turn-ended" ] || fail "Stop hook did not touch turn-ended file"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "idle devin-hook" ] || fail "after Stop state must be 'idle devin-hook', got '$out'"

  # Execute SessionEnd hook: closes turn (idle)
  sh -c "$cmd_end" || fail "SessionEnd hook command failed: $cmd_end"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "idle devin-hook" ] || fail "after SessionEnd state must be 'idle devin-hook', got '$out'"

  # A Stop from a retired incarnation, run after the task is re-armed, must
  # neither settle the replacement nor wake the watcher for it.
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id" >/dev/null
  rm -f "$home/state/$id.turn-ended"
  sh -c "$cmd_stop" || fail "a stale Stop hook command must still exit cleanly"
  [ ! -e "$home/state/$id.turn-ended" ] || fail "a stale Stop must not touch the turn-ended notification"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale Stop must not settle the replacement, got '$out'"

  pass "fm-spawn.sh: devin hooks generated, verified, and executed with correct busy transitions"
}

# --- private config: user settings, Claude import, refusal -------------------

test_devin_private_config_preserves_user_config() {
  local fields case_dir home proj wt fakebin id config user out before
  fields=$(make_spawn_case userconfig)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  user="$home/userhome/.config/devin/config.json"
  mkdir -p "$(dirname "$user")"
  printf '%s\n' '{"agent":{"model":"swe-2-high"},"attribution":true,"read_config_from":{"claude":true,"cursor":false},"permissions":{"allow":["Exec(make)"],"deny":["Exec(npm publish)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true user-stop"}]}],"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"true user-pre"}]}]}}' >"$user"
  before=$(cat "$user")
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null \
    || fail "spawn with a user config should succeed"
  config="$home/state/$id.devin-config.json"
  [ "$(cat "$user")" = "$before" ] || fail "spawn must never edit the user's own config"
  jq -e '.agent.model == "swe-2-high" and .attribution == false' "$config" >/dev/null \
    || fail "unrelated user settings must survive while attribution is forced off: $(jq -c . "$config")"
  jq -e '.read_config_from == {"claude":true,"cursor":false}' "$config" >/dev/null \
    || fail "the user's own import choices must survive: $(jq -c .read_config_from "$config")"
  jq -e '.permissions.allow[0] == "Exec(make)" and (.permissions.allow | index(["Exec(git push)"]))
    and .permissions.deny[0] == "Exec(npm publish)" and (.permissions.deny | index(["Exec(git push -f)"]))' "$config" >/dev/null \
    || fail "user permission rules must survive ahead of the reviewed set: $(jq -c .permissions "$config")"
  jq -e '.hooks.Stop[0].hooks[0].command == "true user-stop"
    and (.hooks.Stop[-1].hooks | map(.command) | (.[0] | test("fm-busy-event")) and (.[1] | test("fm-devin-permission-policy")) and (.[2] | test("fm-devin-rate-limit-retry")))
    and .hooks.PreToolUse[0].hooks[0].command == "true user-pre"
    and (.hooks.PreToolUse[-1].hooks[0].command | test("fm-devin-permission-policy.sh.* pre-tool-use"))' "$config" >/dev/null \
    || fail "user hooks must run first and the reviewed hooks must join the lifecycle group: $(jq -c .hooks "$config")"

  # A user who turned Claude import off keeps it off.
  fields=$(make_spawn_case userconfig-noclaude)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  user="$home/userhome/.config/devin/config.json"
  mkdir -p "$(dirname "$user")"
  printf '%s\n' '{"read_config_from":{"claude":false}}' >"$user"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null \
    || fail "spawn with Claude import off should succeed"
  jq -e '.read_config_from == {"claude":false}' "$home/state/$id.devin-config.json" >/dev/null \
    || fail "an explicit Claude import off must survive"

  # A malformed user config refuses the launch and leaves no config behind.
  fields=$(make_spawn_case userconfig-malformed)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  user="$home/userhome/.config/devin/config.json"
  mkdir -p "$(dirname "$user")"
  printf 'broken' >"$user"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) \
    && fail "a malformed user config must refuse the devin launch"
  case "$out" in
    *'could not write the private config'*) ;;
    *) fail "refusal must name the private config, got: $out" ;;
  esac
  [ ! -e "$home/state/$id.devin-config.json" ] || fail "a refused compose must leave no config behind"
  [ -z "$(find "$home/state" -maxdepth 1 -name ".$id.devin-*config.*" -print)" ] \
    || fail "a refused compose must leave no staged files: $(ls -A "$home/state")"
  [ ! -s "$home/launch.log" ] || fail "a refused compose must not reach the pane"
  case "$(cat "$user")" in broken) ;; *) fail "a refused compose must not touch the user config" ;; esac

  # A user config the base writer accepts but the decorator cannot extend
  # (a non-object permissions value) also refuses rather than launching on
  # the undecorated base.
  fields=$(make_spawn_case userconfig-undecoratable)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  user="$home/userhome/.config/devin/config.json"
  mkdir -p "$(dirname "$user")"
  printf '%s\n' '{"permissions":"all"}' >"$user"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) \
    && fail "an undecoratable user config must refuse the devin launch"
  case "$out" in
    *'could not compose the reviewed private config'*) ;;
    *) fail "refusal must name the reviewed config, got: $out" ;;
  esac
  [ ! -e "$home/state/$id.devin-config.json" ] || fail "an undecorated base config must not survive a refused compose"
  [ ! -s "$home/launch.log" ] || fail "an undecorated base config must not reach the pane"

  pass "fm-spawn.sh: devin private config keeps user settings and import choice, and refuses a bad compose"
}

# --- collision refusal ------------------------------------------------------

test_devin_collision_refusal() {
  local fields case_dir home proj wt fakebin id out exclude_file
  fields=$(make_spawn_case collision-untracked)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"

  # Case 1: .devin/config.local.json already exists untracked (excluded so pool refresh is clean)
  mkdir -p "$wt/.devin"
  echo '{"existing":true}' > "$wt/.devin/config.local.json"
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  echo '.devin/config.local.json' >> "$exclude_file"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "spawn must refuse when .devin/config.local.json already exists"
  case "$out" in
    *'.devin/config.local.json already exists as an untracked leftover'*) ;;
    *) fail "refusal must report .devin/config.local.json as an untracked leftover, got: $out" ;;
  esac
  case "$out" in
    *'tracked by git'*) fail "an untracked leftover must not be reported as tracked: $out" ;;
  esac

  # Case 2: .devin/config.local.json is tracked on the project's default branch.
  # Spawn refreshes the leased worktree to origin's tip, so the file must be on
  # origin/main rather than only on the pre-created worktree branch. It is the
  # project's own config layer, so the spawn proceeds and leaves it untouched.
  fields=$(make_spawn_case collision-tracked)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  mkdir -p "$proj/.devin"
  echo '{"tracked":true}' > "$proj/.devin/config.local.json"
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' add .devin/config.local.json
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "Track devin config"
  git -C "$proj" push origin main >/dev/null 2>&1
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) \
    || fail "spawn must proceed beside a project-tracked .devin/config.local.json: $out"
  [ "$(cat "$wt/.devin/config.local.json")" = '{"tracked":true}' ] \
    || fail "spawn must leave a project-tracked .devin/config.local.json untouched"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "spawn must leave the worktree clean: $(git -C "$wt" status --porcelain)"
  [ -f "$home/state/$id.devin-config.json" ] || fail "spawn must still write the private config"

  # Case 3: .devin/rules/firstmate-attribution.md already exists (excluded so the
  # pooled worktree refreshes clean, same as case 1). This is the exact shape a
  # pool slot holds after a previous devin worker's teardown missed the file.
  fields=$(make_spawn_case collision-rule)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  mkdir -p "$wt/.devin/rules"
  echo 'existing rule' > "$wt/.devin/rules/firstmate-attribution.md"
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  echo '.devin/rules/firstmate-attribution.md' >> "$exclude_file"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "spawn must refuse when .devin/rules/firstmate-attribution.md already exists"
  case "$out" in
    *'firstmate-attribution.md already exists as an untracked leftover'*) ;;
    *) fail "refusal must report the attribution rule as an untracked leftover, got: $out" ;;
  esac
  # The refusal is a refusal, not a cleanup: the leftover must still be there.
  [ -f "$wt/.devin/rules/firstmate-attribution.md" ] \
    || fail "spawn must not silently delete the untracked leftover it refuses on"
  [ "$(cat "$wt/.devin/rules/firstmate-attribution.md")" = 'existing rule' ] \
    || fail "the refused leftover's content must be untouched"

  # Case 4: .devin/rules/firstmate-attribution.md tracked on the project's
  # default branch - a genuinely project-owned file the spawn leaves alone.
  fields=$(make_spawn_case collision-rule-tracked)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  mkdir -p "$proj/.devin/rules"
  echo 'project rule' > "$proj/.devin/rules/firstmate-attribution.md"
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' add .devin/rules/firstmate-attribution.md
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "Track devin attribution rule"
  git -C "$proj" push origin main >/dev/null 2>&1
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) \
    || fail "spawn must proceed beside a project-tracked attribution rule: $out"
  [ "$(cat "$wt/.devin/rules/firstmate-attribution.md")" = 'project rule' ] \
    || fail "spawn must leave a project-tracked attribution rule untouched"

  pass "fm-spawn.sh: devin spawn refuses untracked legacy .devin leftovers and leaves tracked project files alone"
}

# --- teardown & relaunch wiring ---------------------------------------------

test_devin_teardown_and_relaunch() {
  local fields case_dir home proj wt fakebin id dirty
  fields=$(make_spawn_case teardown-relaunch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  [ -f "$home/state/$id.devin-config.json" ] || fail "expected the private config to exist"
  [ ! -e "$wt/.devin" ] || fail "spawn must write nothing under the worktree's .devin"

  # fm_control_harness_wiring_paths covers the private config so relaunch
  # clears it.
  local p
  for p in $(fm_control_harness_wiring_paths devin "$wt" "$home/state" "$id"); do
    [ -n "$p" ] && rm -f -- "$p"
  done
  [ ! -f "$home/state/$id.devin-config.json" ] || fail "fm_control_harness_wiring_paths must cover the private config"

  # Teardown safety: ensure teardown uncommitted changes check does NOT ignore untracked .devin/ content
  # Create an actual untracked file in .devin/
  mkdir -p "$wt/.devin/skills/foo"
  touch "$wt/.devin/skills/foo/SKILL.md"
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
  [ -n "$dirty" ] || fail "teardown dirty check must NOT ignore untracked .devin/ files (hard rule 3)"
  case "$dirty" in
    *'.devin/'*) ;;
    *) fail "dirty must detect untracked .devin/ content, got: $dirty" ;;
  esac

  pass "fm-teardown / fm-control: relaunch wiring cleared and teardown protects unlanded .devin content"
}

plant_legacy_devin_wiring() {  # <worktree>
  mkdir -p "$1/.devin/rules"
  printf '{"attribution":false}\n' > "$1/.devin/config.local.json"
  printf 'no attribution\n' > "$1/.devin/rules/firstmate-attribution.md"
}

test_devin_teardown_removes_managed_wiring_and_empty_dirs() {
  local fields case_dir home proj wt fakebin id
  fields=$(make_spawn_case teardown-wiring)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  [ -f "$home/state/$id.devin-config.json" ] || fail "expected the private config to exist"
  [ -f "$home/state/$id.devin-permission.json" ] || fail "expected the permission policy file to exist"
  # The two worktree files an older devin incarnation of this task wrote.
  plant_legacy_devin_wiring "$wt"

  # --force keeps the worktree (the fake treehouse return is a no-op), so the
  # pooled slot's leftover state is directly inspectable afterwards.
  run_devin_teardown "$home" "$fakebin" "$id" --force >/dev/null \
    || fail "teardown of the devin task should succeed"
  [ ! -e "$home/state/$id.devin-config.json" ] || fail "teardown must remove the private config"
  [ ! -e "$home/state/$id.devin-permission.json" ] || fail "teardown must remove the permission policy file"
  [ ! -e "$wt/.devin/config.local.json" ] || fail "teardown must remove .devin/config.local.json"
  [ ! -e "$wt/.devin/rules/firstmate-attribution.md" ] || fail "teardown must remove .devin/rules/firstmate-attribution.md"
  [ ! -d "$wt/.devin/rules" ] || fail "teardown must remove the emptied .devin/rules directory"
  [ ! -d "$wt/.devin" ] || fail "teardown must remove the emptied .devin directory"

  # Only-when-empty: a project's own file under .devin/rules keeps both
  # directories in place while firstmate's managed files still go.
  fields=$(make_spawn_case teardown-foreign)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  plant_legacy_devin_wiring "$wt"
  printf 'project rule\n' > "$wt/.devin/rules/project-rule.md"
  run_devin_teardown "$home" "$fakebin" "$id" --force >/dev/null \
    || fail "teardown of the devin task should succeed"
  [ ! -e "$wt/.devin/config.local.json" ] || fail "teardown must remove .devin/config.local.json"
  [ ! -e "$wt/.devin/rules/firstmate-attribution.md" ] || fail "teardown must remove .devin/rules/firstmate-attribution.md"
  [ -f "$wt/.devin/rules/project-rule.md" ] || fail "teardown must not remove project-owned .devin content"
  [ -d "$wt/.devin/rules" ] && [ -d "$wt/.devin" ] \
    || fail "teardown must leave .devin dirs that still hold project content"

  pass "fm-teardown: devin teardown removes the private config, legacy files, and only-empty .devin directories"
}

test_teardown_keeps_project_tracked_devin_files_for_a_nondevin_task() {
  local fields case_dir home proj wt fakebin id
  fields=$(make_spawn_case teardown-tracked)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # A non-devin task whose project legitimately tracks the managed paths: both
  # are the project's own, committed on the task branch like any content.
  mkdir -p "$wt/.devin/rules"
  printf '{"local":true}\n' > "$wt/.devin/config.local.json"
  printf 'project rule\n' > "$wt/.devin/rules/firstmate-attribution.md"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    add .devin/config.local.json .devin/rules/firstmate-attribution.md
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "Track devin config and attribution rule"
  # The task record belongs to a non-devin harness, so nothing under .devin/
  # is firstmate's to retire.
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=claude" \
    "kind=ship" \
    "tasktmp=/tmp/fm-$id"
  run_devin_teardown "$home" "$fakebin" "$id" --force >/dev/null \
    || fail "teardown of the non-devin task should succeed"
  [ -f "$wt/.devin/config.local.json" ] \
    || fail "teardown must never remove a git-tracked .devin/config.local.json"
  [ -f "$wt/.devin/rules/firstmate-attribution.md" ] \
    || fail "teardown must never remove a git-tracked .devin/rules/firstmate-attribution.md"
  [ -d "$wt/.devin/rules" ] && [ -d "$wt/.devin" ] \
    || fail "teardown must leave .devin dirs that still hold tracked project content"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "retained tracked files must leave the worktree clean: $(git -C "$wt" status --porcelain)"

  pass "fm-teardown: a non-devin task's git-tracked .devin files survive teardown"
}

test_teardown_removes_a_nondevin_tasks_devin_leftover_when_exclude_proves_it() {
  local fields case_dir home proj wt fakebin id exclude_file
  fields=$(make_spawn_case teardown-poolleftover)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # The pooled-slot shape: a previous devin incarnation's files survived under
  # a later non-devin task - untracked, and still listed in the info/exclude
  # entry fm-spawn wrote for them. Provably firstmate's, so teardown retires
  # them even though this task never ran devin.
  mkdir -p "$wt/.devin/rules"
  printf '{"attribution":false}\n' > "$wt/.devin/config.local.json"
  printf 'no attribution\n' > "$wt/.devin/rules/firstmate-attribution.md"
  exclude_file=$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' '.devin/config.local.json' '.devin/rules/firstmate-attribution.md' >> "$exclude_file"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=claude" \
    "kind=ship" \
    "tasktmp=/tmp/fm-$id"
  run_devin_teardown "$home" "$fakebin" "$id" --force >/dev/null \
    || fail "teardown of the non-devin task should succeed"
  [ ! -e "$wt/.devin/config.local.json" ] \
    || fail "teardown must remove the untracked excluded .devin/config.local.json leftover"
  [ ! -e "$wt/.devin/rules/firstmate-attribution.md" ] \
    || fail "teardown must remove the untracked excluded attribution-rule leftover"
  [ ! -d "$wt/.devin/rules" ] || fail "teardown must remove the emptied .devin/rules directory"
  [ ! -d "$wt/.devin" ] || fail "teardown must remove the emptied .devin directory"

  pass "fm-teardown: a non-devin task's excluded .devin leftover is retired"
}

# --- raw launch -------------------------------------------------------------

test_devin_raw_launch() {
  local fields case_dir home proj wt fakebin id
  fields=$(make_spawn_case raw)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  DEVIN_HARNESS_ARG="devin --raw-escape" run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  [ ! -e "$home/state/$id.devin-config.json" ] || fail "raw launch must not generate the private config"
  [ ! -e "$wt/.devin" ] || fail "raw launch must not write under the worktree's .devin"
  [ ! -f "$home/state/$id.devin-permission.json" ] || fail "raw launch must not generate the permission policy file"
  [ ! -f "$home/state/$id.busy-gen" ] || fail "raw launch must not arm busy generation"
  pass "fm-spawn.sh: raw launch skips devin hook wiring and busy generation"
}

# --- bootstrap dispatch validation ------------------------------------------

# A fixture home for driving bin/fm-bootstrap.sh's crew-dispatch validation
# through its public interface. config/backend pins tmux so the tool check
# needs only the session CLI and treehouse beside the common tools; the manual
# backlog backend keeps that gate inert, and detect-only mode skips the
# mutating sweeps. Each stub answers only what bootstrap probes; jq is the real
# binary because the validator parses the config with it.
make_bootstrap_dispatch_fixture() {  # <dir>; writes <dir>/home + <dir>/fakebin
  local dir=$1 fakebin real_jq
  mkdir -p "$dir/home/config"
  printf '%s\n' tmux > "$dir/home/config/backend"
  printf '%s\n' manual > "$dir/home/config/backlog-backend"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.2.6'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.51
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

run_bootstrap() {  # <dir>
  local dir=$1
  env -u FM_BACKEND -u FM_TASK_ID \
    -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_BOOTSTRAP_NETWORK -u FM_BOOTSTRAP_VERBOSE_FACTS \
    -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET_PATH \
    -u CMUX_TAB_ID -u CMUX_PANEL_ID -u CMUX_REMOTE_TMUX_MIRROR \
    PATH="$dir/fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

assert_bootstrap_dispatch() {  # <json> <label>; expects silent valid output
  local json=$1 label=$2 dir="$TMP_ROOT/bootstrap-dispatch" out
  printf '%s\n' "$json" > "$dir/home/config/crew-dispatch.json"
  out=$(run_bootstrap "$dir")
  [ -z "$out" ] || fail "$label, got: $out"
}

assert_bootstrap_dispatch_rejects() {  # <json> <pattern> <label>
  local json=$1 pattern=$2 label=$3 dir="$TMP_ROOT/bootstrap-dispatch" out
  printf '%s\n' "$json" > "$dir/home/config/crew-dispatch.json"
  out=$(run_bootstrap "$dir")
  case "$out" in
    *"$pattern"*) ;;
    *) fail "$label, got: $out" ;;
  esac
}

# Exercises bin/fm-bootstrap.sh end to end against the fixture home: Devin and
# Gemini sit in the verified-harness baseline so a crew profile using either
# must not be flagged, while a bogus harness and an effort Devin does not
# support must each surface as a CREW_DISPATCH diagnostic.
test_devin_bootstrap_dispatch_validation() {
  make_bootstrap_dispatch_fixture "$TMP_ROOT/bootstrap-dispatch"

  assert_bootstrap_dispatch \
    '{"default":{"harness":"devin","model":"claude-sonnet-4"}}' \
    "bootstrap must accept devin harness"

  assert_bootstrap_dispatch \
    '{"default":{"harness":"gemini","model":"gemini-2.5-flash"}}' \
    "bootstrap must accept gemini harness"

  assert_bootstrap_dispatch_rejects \
    '{"default":{"harness":"bogus_harness","model":"some-model"}}' \
    'unverified harness: bogus_harness' \
    "bootstrap must reject bogus_harness"

  assert_bootstrap_dispatch_rejects \
    '{"default":{"harness":"devin","effort":"high"}}' \
    'invalid effort: devin:high' \
    "bootstrap must reject effort for devin"

  pass "fm-bootstrap.sh: dispatch validation accepts devin and gemini, rejects unverified harnesses and unsupported effort"
}

# --- run all tests ----------------------------------------------------------

test_devin_ancestry_detection_and_anchoring
test_devin_agent_process_classification
test_devin_control_contract
test_devin_auto_uses_smart_and_never_bypass
test_devin_manual_uses_normal_and_never_bypass
test_devin_absent_setting_defaults_to_smart
test_devin_invalid_setting_refuses
test_devin_missing_binary_refuses
test_devin_launch_shape_and_model_handling
test_devin_hooks_generation_validation_and_execution
test_devin_private_config_preserves_user_config
test_devin_collision_refusal
test_devin_teardown_and_relaunch
test_devin_teardown_removes_managed_wiring_and_empty_dirs
test_teardown_keeps_project_tracked_devin_files_for_a_nondevin_task
test_teardown_removes_a_nondevin_tasks_devin_leftover_when_exclude_proves_it
test_devin_raw_launch
test_devin_bootstrap_dispatch_validation
